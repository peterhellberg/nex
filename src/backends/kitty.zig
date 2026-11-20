//! Terminal backend: Kitty Graphics Protocol output, Kitty keyboard and SGR
//! mouse input. Pure Zig plus POSIX syscalls; no terminal library.
//!
//! The cart's 320x180 RGBA framebuffer is nearest-neighbour upscaled in Zig to
//! the exact pixel size of its cell rectangle and stripped down to RGB (the
//! framebuffer is always opaque). When running locally, frames are written to a
//! POSIX shared-memory object and a single short `t=s` placement is sent;
//! otherwise the RGB data is zlib-compressed and sent as chunked `t=d`
//! placements. Unchanged frames are skipped; a new full-screen image is placed
//! before the previous one is deleted, so there is no flicker. There is no
//! terminal audio or gamepad API, so console.synth stays null.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const backend = @import("../backend.zig");
const gfx = @import("../gfx.zig");

const W = gfx.W;
const H = gfx.H;
const tick_ns: i96 = std.time.ns_per_s / 60;
const chunk_len = 4096; // base64 bytes per APC chunk, multiple of four
/// Cap the nearest-neighbour upscale at 2x the 320x180 framebuffer (640x360).
const max_scale: f32 = 2;
const cell_fallback: Cell = .{ .w = 10, .h = 20 };
const apc = "\x1b_G";
const apc_end = "\x1b\\";
const query = apc ++ "i=31,s=1,v=1,a=q,t=d,f=24;AAAA" ++ apc_end ++ "\x1b[c\x1b[16t";
/// Query id for the shared-memory support probe. High to avoid colliding with
/// the image ids used for actual placements.
const shm_probe_id: u32 = 0xfffffffe;
const enter_alt = "\x1b[?1049h";
const leave_alt = "\x1b[?1049l";
const unsupported_msg = "nex: terminal does not support the kitty graphics protocol well enough\r\n";
const enter_seq = "\x1b[?25l\x1b[0m\x1b[2J\x1b[H\x1b[>3u\x1b[?1002h\x1b[?1006h";
const leave_seq = "\x1b[<u\x1b[?1002l\x1b[?1006l\x1b[?25h" ++ leave_alt;
// Reused across frames; frame-sized scratch is allocated per terminal size.
var history: [std.compress.flate.max_window_len]u8 = undefined;
var compressor: std.compress.flate.Compress = undefined;
var detect_buf: [4096]u8 = undefined;
var prev_fb: [W * H]u32 = @splat(0xffffffff);

const Cell = struct { w: u16, h: u16 };
const Rect = struct {
    x: u32, y: u32, w: u32, h: u32,

    fn area(r: Rect) u64 {
        return @as(u64, r.w) * r.h;
    }

    fn merge(a: Rect, b: Rect) Rect {
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        return .{
            .x = x, .y = y,
            .w = @max(a.x + a.w, b.x + b.w) - x,
            .h = @max(a.y + a.h, b.y + b.h) - y,
        };
    }
};
const FrameData = struct { data: []const u8, compressed: bool };

const Layout = struct {
    cols: u16,
    rows: u16,
    cell: Cell,
    place_cols: u16,
    place_rows: u16,
    out_w: u32,
    out_h: u32,
    off_col: u16,
    off_row: u16,

    fn compute(cols: u16, rows: u16, cw: u16, ch: u16) Layout {
        const c: u16 = @max(cols, 1);
        const r: u16 = @max(rows, 1);
        const s = @min(max_scale, @as(f32, @floatFromInt(c * cw)) / W, @as(f32, @floatFromInt(r * ch)) / H);
        const pc = cells(@as(f32, W) * s / cw, c);
        const pr = cells(@as(f32, H) * s / ch, r);
        return .{
            .cols = c, .rows = r, .cell = .{ .w = cw, .h = ch },
            .place_cols = pc, .place_rows = pr,
            .out_w = @as(u32, pc) * cw, .out_h = @as(u32, pr) * ch,
            .off_col = (c - pc) / 2 + 1, .off_row = (r - pr) / 2 + 1,
        };
    }

    fn cells(v: f32, max: u16) u16 {
        return @intCast(@min(@as(u32, @intFromFloat(@max(@floor(v + 0.00001), 1))), max));
    }

    /// SGR mouse reports 1-based cells; map through the placement rectangle.
    fn mouseAxis(l: Layout, comptime x_axis: bool, cell_pos: i32) i32 {
        const count: f32 = @floatFromInt(if (x_axis) l.place_cols else l.place_rows);
        const size: u32 = if (x_axis) W else H;
        const origin: i32 = if (x_axis) l.off_col else l.off_row;
        const px = @as(f32, @floatFromInt(cell_pos - origin)) * @as(f32, @floatFromInt(size)) / count;
        return std.math.clamp(@as(i32, @intFromFloat(@round(px))), 0, @as(i32, @intCast(size)) - 1);
    }
};

const Buffers = struct {
    /// Upscaled RGB triplets (3 bytes per pixel), ready to transmit.
    rgb: []u8 = &.{},
    zbuf: []u8 = &.{},
    b64: []u8 = &.{},
    sx: []u16 = &.{},
    sy: []u16 = &.{},

    fn deinit(b: *Buffers, gpa: std.mem.Allocator) void {
        inline for (.{ "rgb", "zbuf", "b64", "sx", "sy" }) |name| gpa.free(@field(b, name));
        b.* = .{};
    }

    fn alloc(b: *Buffers, gpa: std.mem.Allocator, l: Layout) !void {
        const pixels = @as(usize, l.out_w) * l.out_h;
        const rgb_len = pixels * 3;
        const next = Buffers{
            .rgb = try gpa.alloc(u8, rgb_len),
            .zbuf = try gpa.alloc(u8, rgb_len + 4096),
            .b64 = try gpa.alloc(u8, ((rgb_len + 4096) * 4 + 2) / 3 + 4),
            .sx = try gpa.alloc(u16, l.out_w),
            .sy = try gpa.alloc(u16, l.out_h),
        };
        errdefer next.deinit(gpa);
        for (next.sx, 0..) |*slot, x| slot.* = @intCast(@min(x * W / l.out_w, W - 1));
        for (next.sy, 0..) |*slot, y| slot.* = @intCast(@min(y * H / l.out_h, H - 1));
        b.deinit(gpa);
        b.* = next;
    }
};

const Out = struct {
    buf: [16384]u8 = undefined,
    end: usize = 0,

    fn writeAll(o: *Out, s: []const u8) void {
        for (s) |ch| {
            if (o.end == o.buf.len) o.flush();
            o.buf[o.end] = ch;
            o.end += 1;
        }
    }

    fn print(o: *Out, comptime fmt: []const u8, args: anytype) void {
        var tmp: [192]u8 = undefined;
        o.writeAll(std.fmt.bufPrint(&tmp, fmt, args) catch return);
    }

    fn flush(o: *Out) void {
        var i: usize = 0;
        while (i < o.end) {
            const n = sysIo(1, o.buf[i..o.end], true);
            if (n == 0) break;
            i += n;
        }
        o.end = 0;
    }
};

fn sysIo(fd: posix.fd_t, bytes: []u8, writing: bool) usize {
    while (true) {
        const rc = if (writing)
            posix.system.write(fd, bytes.ptr, bytes.len)
        else
            posix.system.read(fd, bytes.ptr, bytes.len);
        const err = posix.errno(rc);
        if (err == .INTR) continue;
        return if (err == .SUCCESS) @intCast(rc) else 0;
    }
}

fn sysRead(fd: posix.fd_t, bytes: []u8) usize {
    return sysIo(fd, bytes, false);
}

fn inputReady(timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

fn terminalSize() ?posix.winsize {
    // TIOCGWINSZ is the one ioctl we need; its value differs per OS.
    const request: c_int = switch (builtin.os.tag) {
        .linux => 0x5413,
        .macos, .ios, .tvos => 0x40087468,
        else => return null,
    };
    var ws: posix.winsize = undefined;
    return if (std.c.ioctl(0, request, &ws) == 0) ws else null;
}

/// XTWINOPS answers CSI 16t with CSI 6;<height>;<width>t (Ghostty, VTE).
fn parseCellSize(buf: []const u8) ?Cell {
    const at = std.mem.indexOf(u8, buf, "\x1b[6;") orelse return null;
    const rest = buf[at + 4 ..];
    const sep = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const end = std.mem.indexOfScalar(u8, rest, 't') orelse return null;
    const h = std.fmt.parseInt(u16, rest[0..sep], 10) catch return null;
    const w = std.fmt.parseInt(u16, rest[sep + 1 .. end], 10) catch return null;
    return if (w == 0 or h == 0) null else .{ .w = w, .h = h };
}

fn setRawMode(saved: posix.termios) !void {
    var raw = saved;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ISIG = false;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(0, .NOW, raw);
}

// ---- input parsing ----------------------------------------------------------

const Parser = struct {
    const State = enum { ground, esc, csi, apc, apc_esc, osc, osc_esc };
    const Key = struct { code: u32, mods: u32, event: u32 };

    state: State = .ground,
    seq: [48]u8 = undefined,
    seq_len: usize = 0,
    held: u8 = 0,
    /// Text keys have no release event in Kitty encoding; hold them one frame.
    text_held: u8 = 0,
    pressed: u8 = 0,
    mouse: u8 = 0,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    quit: bool = false,
    reload: bool = false,
    layout: Layout,

    fn init(layout: Layout) Parser {
        return .{ .layout = layout };
    }

    fn feed(p: *Parser, bytes: []const u8) void {
        for (bytes) |ch| p.one(ch);
    }

    fn one(p: *Parser, ch: u8) void {
        switch (p.state) {
            .ground => {
                if (ch == 0x1b) p.state = .esc else if (ch == 0x03) {
                    p.quit = true; // Ctrl+C, legacy encoding
                } else if (ch >= 0x20 and ch < 0x7f) {
                    p.keyEvent(.{ .code = ch, .mods = 0, .event = 1 });
                    if (ch == 'z') p.text_held |= 1 << 4;
                    if (ch == 'x') p.text_held |= 1 << 5;
                }
            },
            .esc => {
                p.state = switch (ch) {
                    '[' => .csi,
                    'O' => .csi, // SS3 arrows in legacy mode
                    '_' => .apc,
                    ']' => .osc,
                    else => .ground,
                };
                p.seq_len = 0;
            },
            .csi => {
                if (ch >= 0x40 and ch <= 0x7e) {
                    p.dispatch(ch);
                    p.state = .ground;
                    p.seq_len = 0;
                } else if (p.seq_len < p.seq.len) {
                    p.seq[p.seq_len] = ch;
                    p.seq_len += 1;
                }
            },
            .apc => p.state = if (ch == 0x1b) .apc_esc else .apc,
            .apc_esc => p.state = if (ch == '\\') .ground else .apc,
            .osc => p.state = if (ch == 0x07) .ground else if (ch == 0x1b) .osc_esc else .osc,
            .osc_esc => p.state = if (ch == '\\') .ground else .osc,
        }
    }

    fn dispatch(p: *Parser, final: u8) void {
        const params = p.seq[0..p.seq_len];
        switch (final) {
            'u' => p.keyEvent(parseKey(params, null)),
            'A', 'B', 'C', 'D' => p.keyEvent(parseKey(params, final)),
            'M', 'm' => {
                if (params.len == 0 or params[0] != '<') return;
                var it = std.mem.splitScalar(u8, params[1..], ';');
                const b = num(it.next() orelse "", 0);
                const x = num(it.next() orelse "", 1);
                const y = num(it.next() orelse "", 1);
                p.mouseEvent(b, x, y, final == 'M');
            },
            else => {}, // DA1, CSI 16t, window reports: not input
        }
    }

    fn keyEvent(p: *Parser, k: Key) void {
        const released = k.event == 3;
        if (k.code == 27) {
            if (!released) p.quit = true;
            return;
        }
        if ((k.mods & 4) != 0 and !released) {
            if (k.code == 'c') p.quit = true;
            if (k.code == 'r') p.reload = true;
            if (k.code == 'c' or k.code == 'r') return;
        }
        const button: u4 = switch (k.code) {
            57351 => 0, // left
            57350 => 1, // right
            57348 => 2, // up
            57349 => 3, // down
            'z' => 4,
            'x' => 5,
            else => return,
        };
        const bit: u8 = @as(u8, 1) << @intCast(button);
        p.text_held &= ~bit;
        if (released) {
            p.held &= ~bit;
        } else {
            p.held |= bit;
            if (k.event == 1) p.pressed |= bit;
        }
    }

    fn mouseEvent(p: *Parser, b: u32, x: u32, y: u32, down: bool) void {
        p.mouse_x = p.layout.mouseAxis(true, @intCast(x));
        p.mouse_y = p.layout.mouseAxis(false, @intCast(y));
        if ((b & 32) != 0) return; // motion: coords only
        // SGR 1006 reports 0=left, 1=middle, 2=right; the VEX cart convention
        // is 0=left, 1=right, 2=middle. Swap middle/right to match the other
        // hosts. Code 3 means "no button" (release all).
        const sgr = b & 3;
        const which: u3 = switch (sgr) {
            0 => 0,
            1 => 2,
            2 => 1,
            3 => 3,
            else => unreachable,
        };
        const bit: u8 = @as(u8, 1) << which;
        if (which == 3) {
            p.mouse = 0;
        } else if (down) {
            p.mouse |= bit;
        } else {
            p.mouse &= ~bit;
        }
    }
};

/// `CSI code;mods:event u` and `CSI 1;mods:event A` share the same fields.
fn parseKey(params: []const u8, arrow: ?u8) Parser.Key {
    const codes = [_]u32{ 57348, 57349, 57350, 57351 }; // up down right left
    const finals = "ABCD";
    const code = if (arrow) |a|
        codes[@intCast(std.mem.indexOfScalar(u8, finals, a) orelse 0)]
    else
        num(params, 0);
    var it = std.mem.splitScalar(u8, params, ';');
    _ = it.next(); // the key code (or the leading 1 for arrows)
    const mods = it.next() orelse "1";
    return .{ .code = code, .mods = subNum(mods, 0, 1) -| 1, .event = eventOf(mods, it.next()) };
}

fn num(s: []const u8, default: u32) u32 {
    const end = std.mem.indexOfAny(u8, s, ":;") orelse s.len;
    return std.fmt.parseInt(u32, s[0..end], 10) catch default;
}

fn subNum(s: []const u8, index: usize, default: u32) u32 {
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == index) return std.fmt.parseInt(u32, part, 10) catch default;
    }
    return default;
}

fn eventOf(mods: []const u8, extra: ?[]const u8) u32 {
    const e = subNum(mods, 1, 0);
    return if (e != 0) e else if (extra) |s| num(s, 1) else 1;
}

// ---- shared memory ----------------------------------------------------------

/// POSIX shared-memory helper for the Kitty `t=s` transmission medium. The
/// terminal reads the object and unlinks it; we also unlink the previous frame's
/// object defensively in case a terminal forgets.
const Shm = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    active: bool = false,

    fn cname(s: *const Shm) [*:0]const u8 {
        return @ptrCast(&s.name);
    }

    /// Unlink the object from the previous frame, if any.
    fn cleanup(s: *Shm) void {
        if (!s.active) return;
        _ = std.c.shm_unlink(s.cname());
        s.active = false;
        s.name_len = 0;
    }

    /// Create a fresh object and copy `data` into it. Returns false on any
    /// failure; the caller then falls back to direct transmission.
    fn create(s: *Shm, seq: u32, data: []const u8) bool {
        s.cleanup();
        const name = std.fmt.bufPrint(&s.name, "/kex-{d}-{d}", .{ std.c.getpid(), seq }) catch return false;
        if (name.len >= s.name.len) return false;
        s.name[name.len] = 0; // null-terminate for shm_open/shm_unlink
        s.name_len = name.len;

        const flags: c_int = @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
        const fd = std.c.shm_open(s.cname(), flags, @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            s.active = false;
            return false;
        }
        defer _ = std.c.close(fd);

        if (std.c.ftruncate(fd, @intCast(data.len)) != 0) {
            s.active = false;
            return false;
        }
        const map = posix.mmap(null, data.len, .{ .READ = true, .WRITE = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch {
            s.active = false;
            return false;
        };
        defer posix.munmap(map);
        @memcpy(map, data);

        s.active = true;
        return true;
    }

    /// base64-encode the object name into `out`, returning the encoded slice.
    fn encodedName(s: *const Shm, out: []u8) []const u8 {
        return std.base64.standard.Encoder.encode(out, s.name[0..s.name_len]);
    }
};

// ---- backend ----------------------------------------------------------------

pub const Backend = struct {
    cfg: backend.Config,
    out: Out = .{},
    parser: Parser,
    saved_termios: posix.termios,
    layout: Layout,
    buffers: Buffers = .{},
    next_ns: i96,
    next_id: u32 = 1,
    /// Full-screen fallback image. Partial updates always sit on top of it;
    /// it is replaced only by a new full frame, never by a small rectangle.
    base_id: u32 = 0,
    /// Last partial placement. The next one covers it, so it can be deleted.
    partial_id: u32 = 0,
    /// Union of all dirty rects since the last full frame: only ever grows.
    dirty: ?Rect = null,
    /// Bound live images so the terminal never evicts the base frame.
    partial_count: u32 = 0,
    /// True when the terminal accepted a t=s probe and we are not on SSH.
    use_shm: bool = false,
    shm: Shm = .{},
    shm_seq: u32 = 0,
    /// Scratch for base64-encoding the (short) shared-memory object name.
    shm_name_b64: [48]u8 = undefined,

    pub fn init(cfg: backend.Config) !Backend {
        const now = nowNs(cfg.io);
        const saved = try posix.tcgetattr(0);
        try setRawMode(saved);
        errdefer posix.tcsetattr(0, .NOW, saved) catch {};

        var self = Backend{
            .cfg = cfg,
            .parser = undefined,
            .saved_termios = saved,
            .layout = Layout.compute(80, 24, cell_fallback.w, cell_fallback.h),
            .next_ns = now + tick_ns,
        };
        const cell = try self.detect();
        if (terminalSize()) |ws| self.layout = Layout.compute(ws.col, ws.row, cell.w, cell.h);
        self.use_shm = self.probeShm();
        if (cfg.environ.getPosix("KEX_TRACE") != null) {
            std.debug.print("kex: graphics transport: {s}, cell: {d}x{d}\n", .{
                if (self.use_shm) "shared memory (t=s)" else "direct (t=d)",
                cell.w, cell.h,
            });
        }
        try self.buffers.alloc(cfg.gpa, self.layout);
        self.parser = Parser.init(self.layout);

        self.out.writeAll(enter_seq);
        self.out.flush();
        return self;
    }

    /// Terminals that can't support KGP render the query's APC payload as
    /// literal text. Skip the query entirely for the ones we can identify so
    /// they never see that garbage, even transiently.
    fn knownUnsupported(environ: std.process.Environ) bool {
        const prog = environ.getPosix("TERM_PROGRAM") orelse return false;
        return std.mem.eql(u8, prog, "Apple_Terminal") or
            std.mem.eql(u8, prog, "iTerm.app");
    }

    /// Query action + DA1 + cell size. The query reply is the support test;
    /// DA1 and CSI 16t bound the read on terminals without graphics support.
    /// The query runs in the alternate screen: terminals whose support can't be
    /// determined ahead of time render any literal payload there, which is
    /// discarded when we restore the main screen on failure.
    fn detect(b: *Backend) !Cell {
        if (knownUnsupported(b.cfg.environ)) {
            std.debug.print(unsupported_msg, .{});
            return error.GraphicsUnsupported;
        }
        b.out.writeAll(enter_alt);
        b.out.writeAll(query);
        b.out.flush();
        var len: usize = 0;
        for (0..100) |_| {
            if (!inputReady(10)) continue;
            if (len < detect_buf.len) len += sysRead(0, detect_buf[len..]);
            const buf = detect_buf[0..len];
            if (std.mem.indexOf(u8, buf, "\x1b[c") != null and parseCellSize(buf) != null) break;
        }
        const buf = detect_buf[0..len];
        if (std.mem.indexOf(u8, buf, apc ++ "i=31;OK" ++ apc_end) == null) {
            b.out.writeAll(leave_alt);
            b.out.flush();
            std.debug.print(unsupported_msg, .{});
            return error.GraphicsUnsupported;
        }
        const cell = parseCellSize(buf) orelse cell_fallback;
        // Keep the alternate screen for the session; the rest of enter_seq is
        // written by init().
        return cell;
    }

    /// Probe whether the terminal can read shared memory. We create a tiny
    /// object and ask the terminal to query-load it; an "OK" reply means t=s
    /// works. Over SSH the object would be on the wrong machine, so skip it.
    fn probeShm(b: *Backend) bool {
        if (b.cfg.environ.getPosix("SSH_TTY") != null or
            b.cfg.environ.getPosix("SSH_CONNECTION") != null or
            b.cfg.environ.getPosix("SSH_CLIENT") != null) return false;

        var probe = Shm{};
        const pixel = [3]u8{ 0, 0, 0 };
        if (!probe.create(0, &pixel)) return false;
        defer probe.cleanup();

        const name_b64 = probe.encodedName(&b.shm_name_b64);
        b.out.writeAll(apc ++ "a=q,t=s,f=24,s=1,v=1,i=");
        b.out.print("{d};", .{shm_probe_id});
        b.out.writeAll(name_b64);
        b.out.writeAll(apc_end);
        b.out.flush();

        var expected_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "i={d};OK", .{shm_probe_id}) catch return false;
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        for (0..50) |_| {
            if (!inputReady(10)) continue;
            if (len < buf.len) len += sysRead(0, buf[len..]);
            if (std.mem.indexOf(u8, buf[0..len], expected) != null) return true;
        }
        return false;
    }

    pub fn deinit(b: *Backend) void {
        b.shm.cleanup();
        b.buffers.deinit(b.cfg.gpa);
        b.out.writeAll(leave_seq);
        b.out.flush();
        posix.tcsetattr(0, .NOW, b.saved_termios) catch {};
    }

    pub fn beginFrame(b: *Backend) !backend.Frame {
        // A lone ESC (legacy terminals) has no terminator: with no byte after
        // it by the next frame, it is the Escape key, not a sequence prefix.
        if (b.parser.state == .esc) {
            b.parser.quit = true;
            b.parser.state = .ground;
        }
        b.parser.held &= ~b.parser.text_held;
        b.parser.text_held = 0;
        try b.updateLayout();
        var bytes: [4096]u8 = undefined;
        while (inputReady(0)) {
            const n = sysRead(0, &bytes);
            if (n == 0) break;
            b.parser.feed(bytes[0..n]);
        }
        const frame: backend.Frame = .{ .quit = b.parser.quit, .reload = b.parser.reload };
        b.parser.reload = false;

        const input = &b.cfg.console.input;
        input.held = b.parser.held;
        input.pressed |= b.parser.pressed;
        b.parser.pressed = 0;
        input.mouse = b.parser.mouse;
        input.mouse_x = b.parser.mouse_x;
        input.mouse_y = b.parser.mouse_y;
        return frame;
    }

    fn updateLayout(b: *Backend) !void {
        const ws = terminalSize() orelse return;
        const fresh = Layout.compute(ws.col, ws.row, b.layout.cell.w, b.layout.cell.h);
        if (fresh.out_w == b.layout.out_w and fresh.out_h == b.layout.out_h) return;
        b.layout = fresh;
        b.parser.layout = fresh;
        try b.buffers.alloc(b.cfg.gpa, fresh);
        @memset(&prev_fb, 0xffffffff); // force a full redraw on resize
        // Old placements are at the previous grid's coordinates; without
        // deleting them, stale pixels linger at the edges after a resize.
        b.out.writeAll("\x1b[2J");
        b.out.writeAll(apc ++ "a=d,d=A,q=1" ++ apc_end);
        b.out.flush();
        b.base_id = 0;
        b.partial_id = 0;
        b.partial_count = 0;
        b.dirty = null;
    }

    pub fn present(b: *Backend) u32 {
        const fb = b.cfg.console.gfx.bytes();
        if (dirtyRect(fb)) |changed| {
            const grown = if (b.dirty) |old| old.merge(changed) else changed;
            const full = b.base_id == 0 or b.partial_count >= 4 or
                grown.area() * 10 > @as(u64, W) * H * 9;
            const rect: Rect = if (full) .{ .x = 0, .y = 0, .w = W, .h = H } else grown;
            b.send(fb, rect, full);
            b.dirty = if (full) null else grown;
        }
        return b.pace();
    }

    /// Smallest bounding box of changed pixels. 0xffffffff means "never drawn".
    fn dirtyRect(fb_bytes: []const u8) ?Rect {
        const fb: []const u32 = @ptrCast(@alignCast(fb_bytes));
        var x0: usize = W;
        var y0: usize = H;
        var x1: usize = 0;
        var y1: usize = 0;
        for (fb, prev_fb, 0..) |p, old, i| {
            if (p == old) continue;
            const y = i / W;
            const x = i % W;
            x0 = @min(x0, x);
            y0 = @min(y0, y);
            x1 = @max(x1, x);
            y1 = @max(y1, y);
        }
        if (x0 > x1) return null;
        @memcpy(&prev_fb, fb);
        return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0 + 1), .h = @intCast(y1 - y0 + 1) };
    }

    fn send(b: *Backend, fb: []const u8, rect: Rect, full: bool) void {
        const l = b.layout;
        const box = Box.compute(l, rect);
        const rgb = upscale(b, fb, box);

        const col = l.off_col + @as(u16, @intCast(box.px0 / l.cell.w));
        const row = l.off_row + @as(u16, @intCast(box.py0 / l.cell.h));
        b.out.print("\x1b[{d};{d}H", .{ row, col });

        const id = b.next_id;
        var placed = false;
        if (b.use_shm) {
            placed = b.sendShm(rgb, id, box);
            if (!placed) b.use_shm = false; // permanent fallback after a failure
        }
        if (!placed) b.sendDirect(rgb, id, box);

        // Delete only images fully covered by the new placement: the last
        // partial (union only grows), and the old base on a full refresh.
        if (!full and b.partial_id != 0) {
            b.out.print(apc ++ "a=d,d=I,i={d},q=1" ++ apc_end, .{b.partial_id});
        }
        if (full and b.base_id != 0) {
            b.out.print(apc ++ "a=d,d=I,i={d},q=1" ++ apc_end, .{b.base_id});
        }
        b.out.flush();
        if (full) {
            b.base_id = id;
            b.partial_id = 0;
            b.partial_count = 0;
        } else {
            b.partial_id = id;
            b.partial_count += 1;
        }
        b.next_id += 1;
    }

    /// Transmit the frame through a shared-memory object. A single short escape
    /// sequence replaces the base64 payload and chunking of direct mode.
    fn sendShm(b: *Backend, rgb: []const u8, id: u32, box: Box) bool {
        b.shm_seq += 1;
        if (!b.shm.create(b.shm_seq, rgb)) return false;
        const name_b64 = b.shm.encodedName(&b.shm_name_b64);
        b.out.writeAll(apc ++ "a=T,t=s,f=24,s=");
        b.out.print("{d},v={d},i={d},q=1,C=1;", .{ box.rw, box.rh, id });
        b.out.writeAll(name_b64);
        b.out.writeAll(apc_end);
        b.out.flush();
        return true;
    }

    /// zlib-compress and base64-encode the RGB frame, sending it as chunked
    /// direct-mode APC placements.
    fn sendDirect(b: *Backend, rgb: []const u8, id: u32, box: Box) void {
        const frame = compress(b, rgb);
        const encoded = std.base64.standard.Encoder.encode(b.buffers.b64, frame.data);
        var pos: usize = 0;
        var index: usize = 0;
        while (pos < encoded.len) : (index += 1) {
            const end = @min(pos + chunk_len, encoded.len);
            const more = end < encoded.len;
            if (index == 0) {
                // No c/r: the image is already the exact pixel size of the
                // cell rectangle, so the terminal displays it 1:1 (no blur).
                b.out.print(apc ++ "a=T,i={d},f=24,s={d},v={d},q=1,C=1,m={d}{s};", .{
                    id, box.rw, box.rh, @intFromBool(more), if (frame.compressed) ",o=z" else "",
                });
            } else {
                b.out.print(apc ++ "q=1,m={d};", .{@intFromBool(more)});
            }
            b.out.writeAll(encoded[pos..end]);
            b.out.writeAll(apc_end);
            b.out.flush();
            pos = end;
        }
    }

    /// Absolute-deadline pacing: 60 cart ticks even if a frame is dropped.
    fn pace(b: *Backend) u32 {
        const remain = b.next_ns - nowNs(b.cfg.io);
        if (remain > 0) std.Io.sleep(b.cfg.io, .{ .nanoseconds = remain }, .awake) catch {};
        b.next_ns += tick_ns;
        const behind = nowNs(b.cfg.io) - b.next_ns;
        if (behind < 0) return 1;
        if (behind > 4 * tick_ns) {
            b.next_ns = nowNs(b.cfg.io) + tick_ns;
            return 1;
        }
        const extra: u32 = @intCast(@divFloor(behind, tick_ns) + 1);
        b.next_ns += @as(i96, extra) * tick_ns;
        return 1 + extra;
    }

    pub fn tone(b: *Backend) void {
        _ = b; // no terminal audio API
    }
};

/// Dirty rectangle snapped to the terminal's cell grid. The live placement
/// always grows, so a new one covers the old before it is deleted.
const Box = struct {
    px0: u32, py0: u32, rw: u32, rh: u32,

    fn compute(l: Layout, r: Rect) Box {
        const cw = l.cell.w;
        const ch = l.cell.h;
        const px0 = (@as(u32, r.x) * l.out_w / W / cw) * cw;
        const py0 = (@as(u32, r.y) * l.out_h / H / ch) * ch;
        const px1 = ((@as(u32, r.x + r.w) * l.out_w + W - 1) / W + cw - 1) / cw * cw;
        const py1 = ((@as(u32, r.y + r.h) * l.out_h + H - 1) / H + ch - 1) / ch * ch;
        return .{
            .px0 = px0, .py0 = py0,
            .rw = @min(px1 - px0, l.out_w - px0),
            .rh = @min(py1 - py0, l.out_h - py0),
        };
    }
};

/// Pixel-perfect nearest-neighbour upscale of just the dirty rectangle,
/// writing RGB triplets (the framebuffer's alpha byte is always 0xff).
fn upscale(b: *Backend, fb_bytes: []const u8, box: Box) []const u8 {
    const bufs = &b.buffers;
    const src: []const u32 = @ptrCast(@alignCast(fb_bytes));
    const out = bufs.rgb;
    if (b.layout.out_w == W and b.layout.out_h == H) {
        for (0..box.rh) |y| {
            const so = (box.py0 + y) * W + box.px0;
            for (0..box.rw) |x| {
                const p = src[so + x];
                const o = (y * box.rw + x) * 3;
                out[o] = @truncate(p);
                out[o + 1] = @truncate(p >> 8);
                out[o + 2] = @truncate(p >> 16);
            }
        }
    } else {
        for (0..box.rh) |y| {
            const sy: usize = bufs.sy[box.py0 + y];
            for (0..box.rw) |x| {
                const p = src[sy * W + bufs.sx[box.px0 + x]];
                const o = (y * box.rw + x) * 3;
                out[o] = @truncate(p);
                out[o + 1] = @truncate(p >> 8);
                out[o + 2] = @truncate(p >> 16);
            }
        }
    }
    return out[0 .. box.rw * box.rh * 3];
}

fn compress(b: *Backend, src: []const u8) FrameData {
    const raw: FrameData = .{ .data = src, .compressed = false };
    var w: std.Io.Writer = .fixed(b.buffers.zbuf);
    compressor = std.compress.flate.Compress.init(&w, &history, .zlib, .{
        .good = 3, .nice = 4, .lazy = 0, .chain = 1,
    }) catch return raw;
    compressor.writer.writeAll(src) catch return raw;
    compressor.finish() catch return raw;
    const out = b.buffers.zbuf[0..w.end];
    return if (out.len < src.len) .{ .data = out, .compressed = true } else raw;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

// ---- tests ------------------------------------------------------------------

test "keyboard events map to cart buttons and commands" {
    const t = std.testing;
    var p = Parser.init(Layout.compute(80, 24, 10, 20));
    p.feed("\x1b[1;1:1D");
    try t.expectEqual(@as(u8, 1), p.held);
    try t.expectEqual(@as(u8, 1), p.pressed);
    p.feed("\x1b[122;1:1u");
    try t.expectEqual(@as(u8, 0x11), p.held);
    p.feed("\x1b[122;1:3u");
    try t.expectEqual(@as(u8, 1), p.held);
    for ([_][]const u8{ "\x1b[114;5:1u", "\x1b[27;1:1u", "\x1b[99;5:1u", "\x03" }) |seq| p.feed(seq);
    try t.expect(p.reload);
    try t.expect(p.quit);
}

test "dirty rect is the bounding box of changed pixels" {
    const t = std.testing;
    @memset(&prev_fb, 0);
    var fb: [W * H]u32 = @splat(0);
    fb[10 * W + 20] = 1;
    fb[12 * W + 30] = 2;
    const r = Backend.dirtyRect(std.mem.sliceAsBytes(&fb)).?;
    try t.expectEqual(@as(u32, 20), r.x);
    try t.expectEqual(@as(u32, 10), r.y);
    try t.expectEqual(@as(u32, 11), r.w);
    try t.expectEqual(@as(u32, 3), r.h);
    try t.expect(Backend.dirtyRect(std.mem.sliceAsBytes(&fb)) == null);
}

test "cell size reply uses CSI 6;h;wt" {
    const cell = parseCellSize("\x1b[?62c\x1b[6;21;11t").?;
    try std.testing.expectEqual(@as(u16, 11), cell.w);
    try std.testing.expectEqual(@as(u16, 21), cell.h);
}

test "SGR mouse maps cells into the framebuffer" {
    const t = std.testing;
    const l = Layout.compute(80, 24, 10, 20);
    try t.expectEqual(@as(u16, 64), l.place_cols); // capped at 2x native
    try t.expectEqual(@as(u16, 18), l.place_rows);
    try t.expectEqual(@as(u32, 640), l.out_w);
    try t.expectEqual(@as(u32, 360), l.out_h);
    var p = Parser.init(l);
    p.feed("\x1b[<0;10;5M");
    try t.expectEqual(@as(u8, 1), p.mouse);
    try t.expectEqual(@as(i32, 5), p.mouse_x);
    try t.expectEqual(@as(i32, 10), p.mouse_y);
    p.feed("\x1b[<0;10;5m");
    try t.expectEqual(@as(u8, 0), p.mouse);

    // SGR 1006: 1=middle, 2=right. The cart convention is 1=right, 2=middle,
    // so they must be swapped to match the other hosts.
    p.feed("\x1b[<1;10;5M");
    try t.expectEqual(@as(u8, 1 << 2), p.mouse); // middle -> cart bit 2
    p.feed("\x1b[<1;10;5m");
    try t.expectEqual(@as(u8, 0), p.mouse);
    p.feed("\x1b[<2;10;5M");
    try t.expectEqual(@as(u8, 1 << 1), p.mouse); // right -> cart bit 1
    p.feed("\x1b[<2;10;5m");
    try t.expectEqual(@as(u8, 0), p.mouse);
}
