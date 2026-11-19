//! Terminal backend: Kitty Graphics Protocol for output, Kitty keyboard and
//! SGR mouse protocols for input. No third-party code: everything here is Zig,
//! escape sequences and POSIX syscalls.
//!
//! The cart still draws into its 320x180 RGBA framebuffer. Each frame is
//! zlib-compressed, base64-encoded, and sent as a chunked `a=T` placement
//! scaled to fill the terminal grid. There is no terminal audio or gamepad
//! API, so this backend leaves console.synth null and reads no pads.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const backend = @import("../backend.zig");
const gfx = @import("../gfx.zig");

const W = gfx.W;
const H = gfx.H;
const tick_ns: i96 = std.time.ns_per_s / 60;
/// Base64 bytes per APC chunk. Must be a multiple of four.
const chunk_len = 4096;
const fallback_cell_w = 10;
const fallback_cell_h = 20;

// Scratch lives in static storage: the main loop's stack stays small and the
// deflate compressor (~220 KiB) is reused across frames.
const zbuf_len = W * H * 4 + 4096;
var zbuf: [zbuf_len]u8 = undefined;
var b64buf: [(zbuf_len * 4 + 2) / 3 + 4]u8 = undefined;
var history: [std.compress.flate.max_window_len]u8 = undefined;
var compressor: std.compress.flate.Compress = undefined;
var detect_buf: [4096]u8 = undefined;

const Layout = struct {
    cols: u16,
    rows: u16,
    cell_w: f32,
    cell_h: f32,
    place_cols: u16,
    place_rows: u16,
    off_col: u16,
    off_row: u16,

    fn compute(cols_raw: u16, rows_raw: u16, cw: f32, ch: f32) Layout {
        const cols: u16 = @max(cols_raw, 1);
        const rows: u16 = @max(rows_raw, 1);
        const avail_w: f32 = @as(f32, @floatFromInt(cols)) * cw;
        const avail_h: f32 = @as(f32, @floatFromInt(rows)) * ch;
        const s = @min(avail_w / @as(f32, W), avail_h / @as(f32, H));
        const pc = clampCells(@as(f32, W) * s / cw, cols);
        const pr = clampCells(@as(f32, H) * s / ch, rows);
        return .{
            .cols = cols,
            .rows = rows,
            .cell_w = cw,
            .cell_h = ch,
            .place_cols = pc,
            .place_rows = pr,
            .off_col = (cols - pc) / 2 + 1,
            .off_row = (rows - pr) / 2 + 1,
        };
    }

    fn clampCells(v: f32, max: u16) u16 {
        const n: u32 = @intFromFloat(@max(@floor(v + 0.00001), 1));
        return @intCast(@min(n, max));
    }

    /// SGR mouse reports 1-based cells. The image is letterboxed inside the
    /// grid, so map through the placement rectangle into framebuffer pixels.
    fn mouseAxis(l: Layout, comptime x_axis: bool, cell: i32) i32 {
        const origin: i32 = if (x_axis) l.off_col else l.off_row;
        const count: f32 = if (x_axis) @floatFromInt(l.place_cols) else @floatFromInt(l.place_rows);
        const size: f32 = if (x_axis) @floatFromInt(W) else @floatFromInt(H);
        const px = @as(f32, @floatFromInt(cell - origin)) * size / count;
        return std.math.clamp(@as(i32, @intFromFloat(@round(px))), 0, @as(i32, @intFromFloat(size)) - 1);
    }
};

const Out = struct {
    buf: [16384]u8 = undefined,
    end: usize = 0,

    fn writeAll(o: *Out, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            if (o.end == o.buf.len) o.flush();
            const n = @min(o.buf.len - o.end, s.len - i);
            @memcpy(o.buf[o.end..][0..n], s[i..][0..n]);
            o.end += n;
            i += n;
        }
    }

    fn print(o: *Out, comptime fmt: []const u8, args: anytype) void {
        var tmp: [192]u8 = undefined;
        o.writeAll(std.fmt.bufPrint(&tmp, fmt, args) catch return);
    }

    fn flush(o: *Out) void {
        var i: usize = 0;
        while (i < o.end) {
            const n = sysWrite(1, o.buf[i..o.end]);
            if (n == 0) break;
            i += n;
        }
        o.end = 0;
    }
};

fn sysWrite(fd: posix.fd_t, bytes: []const u8) usize {
    while (true) {
        const rc = posix.system.write(fd, bytes.ptr, bytes.len);
        const err = posix.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return 0;
        return @intCast(rc);
    }
}

fn sysRead(fd: posix.fd_t, bytes: []u8) usize {
    while (true) {
        const rc = posix.system.read(fd, bytes.ptr, bytes.len);
        const err = posix.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return 0;
        return @intCast(rc);
    }
}

fn inputReady(timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

fn terminalSize() ?posix.winsize {
    if (builtin.os.tag != .linux) return null;
    var ws: posix.winsize = undefined;
    const rc = std.os.linux.ioctl(0, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return ws;
}

fn parseCellSize(buf: []const u8) ?struct { w: u16, h: u16 } {
    const needle = "\x1b[16;";
    const at = std.mem.indexOf(u8, buf, needle) orelse return null;
    var i = at + needle.len;
    const sep = std.mem.indexOfScalarPos(u8, buf, i, ';') orelse return null;
    const h = std.fmt.parseInt(u16, buf[i..sep], 10) catch return null;
    i = sep + 1;
    const end = std.mem.indexOfScalarPos(u8, buf, i, 't') orelse return null;
    const w = std.fmt.parseInt(u16, buf[i..end], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

// ---- input parsing ----------------------------------------------------------

const Parser = struct {
    const State = enum { ground, esc, csi, apc, apc_esc, osc, osc_esc };

    state: State = .ground,
    seq: [48]u8 = undefined,
    seq_len: usize = 0,
    held: u8 = 0,
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
                if (ch == 0x1b) {
                    p.state = .esc;
                } else if (ch >= 0x20 and ch < 0x7f) {
                    p.key(ch, 0, 1);
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
            'u' => {
                var it = std.mem.splitScalar(u8, params, ';');
                const code = fieldInt(it.next() orelse "", 0);
                const mods_field = it.next() orelse "1";
                p.key(code, modBits(mods_field), eventOf(mods_field, it.next()));
            },
            'A', 'B', 'C', 'D' => {
                const code: u32 = switch (final) {
                    'A' => 57348,
                    'B' => 57349,
                    'C' => 57350,
                    'D' => 57351,
                    else => unreachable,
                };
                var it = std.mem.splitScalar(u8, params, ';');
                _ = it.next(); // the leading 1
                const mods_field = it.next() orelse "1";
                p.key(code, modBits(mods_field), eventOf(mods_field, it.next()));
            },
            'M', 'm' => {
                if (params.len == 0 or params[0] != '<') return;
                var it = std.mem.splitScalar(u8, params[1..], ';');
                const b = fieldInt(it.next() orelse "", 0);
                const x = fieldInt(it.next() orelse "", 1);
                const y = fieldInt(it.next() orelse "", 1);
                p.mouseEvent(b, x, y, final == 'M');
            },
            else => {}, // DA1, CSI 16t, window reports: not input
        }
    }

    fn key(p: *Parser, code: u32, mods: u32, event: u32) void {
        const released = event == 3;
        if (code == 27) {
            if (!released) p.quit = true;
            return;
        }
        if (code == 'r' and (mods & 4) != 0) {
            if (!released) p.reload = true; // Super is not reportable: Ctrl+R
            return;
        }
        const button: u4 = switch (code) {
            57351 => 0, // left
            57350 => 1, // right
            57348 => 2, // up
            57349 => 3, // down
            'z' => 4,
            'x' => 5,
            else => return,
        };
        p.setButton(button, event);
    }

    fn setButton(p: *Parser, button: u4, event: u32) void {
        const bit: u8 = @as(u8, 1) << @intCast(button);
        if (event == 3) {
            p.held &= ~bit;
        } else {
            p.held |= bit;
            if (event == 1) p.pressed |= bit;
        }
    }

    fn mouseEvent(p: *Parser, b: u32, x: u32, y: u32, down: bool) void {
        p.mouse_x = p.layout.mouseAxis(true, @intCast(x));
        p.mouse_y = p.layout.mouseAxis(false, @intCast(y));
        if ((b & 32) != 0) return; // motion: coords only
        const which = b & 3;
        if (which == 3) {
            p.mouse = 0;
        } else if (down) {
            p.mouse |= @as(u8, 1) << @intCast(which);
        } else {
            p.mouse &= ~(@as(u8, 1) << @intCast(which));
        }
    }
};

fn fieldInt(s: []const u8, default: u32) u32 {
    const end = std.mem.indexOfScalar(u8, s, ':') orelse s.len;
    return std.fmt.parseInt(u32, s[0..end], 10) catch default;
}

fn subInt(s: []const u8, index: usize, default: u32) u32 {
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == index) return std.fmt.parseInt(u32, part, 10) catch default;
    }
    return default;
}

/// `CSI code;mods:event u` carries the event type as a subfield of modifiers.
/// Some terminals put it in a third semicolon field instead.
fn eventOf(mods_field: []const u8, extra: ?[]const u8) u32 {
    const e = subInt(mods_field, 1, 0);
    if (e != 0) return e;
    if (extra) |s| return fieldInt(s, 1);
    return 1;
}

fn modBits(s: []const u8) u32 {
    return fieldInt(s, 1) -| 1;
}

// ---- backend ----------------------------------------------------------------

pub const Backend = struct {
    cfg: backend.Config,
    out: Out = .{},
    parser: Parser,
    saved_termios: posix.termios,
    layout: Layout,
    next_ns: i96,

    pub fn init(cfg: backend.Config) !Backend {
        if (builtin.os.tag != .linux) @compileError("kitty backend requires Linux");

        const saved = try posix.tcgetattr(0);
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
        errdefer posix.tcsetattr(0, .NOW, saved) catch {};

        var self = Backend{
            .cfg = cfg,
            .parser = undefined,
            .saved_termios = saved,
            .layout = Layout.compute(80, 24, fallback_cell_w, fallback_cell_h),
            .next_ns = std.Io.Timestamp.now(cfg.io, .awake).toNanoseconds() + tick_ns,
        };

        // Query action + DA1 + cell size. The query reply is the support test;
        // DA1 and CSI 16t bound the read so we don't wait forever on a terminal
        // that ignores the graphics protocol entirely.
        self.out.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c\x1b[16t");
        self.out.flush();
        var len: usize = 0;
        for (0..30) |_| {
            if (!inputReady(10)) continue;
            if (len < detect_buf.len) len += sysRead(0, detect_buf[len..]);
            if (std.mem.indexOf(u8, detect_buf[0..len], "\x1b[c") != null and
                parseCellSize(detect_buf[0..len]) != null) break;
        }
        if (std.mem.indexOf(u8, detect_buf[0..len], "\x1b_Gi=31;OK\x1b\\") == null) {
            std.debug.print("nex: terminal does not support the kitty graphics protocol\n", .{});
            return error.GraphicsUnsupported;
        }
        if (parseCellSize(detect_buf[0..len])) |cell| {
            self.layout.cell_w = @floatFromInt(cell.w);
            self.layout.cell_h = @floatFromInt(cell.h);
        }

        if (terminalSize()) |ws| self.layout = Layout.compute(ws.col, ws.row, self.layout.cell_w, self.layout.cell_h);
        self.parser = Parser.init(self.layout);

        self.out.writeAll("\x1b[?1049h\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
        self.out.writeAll("\x1b>3u"); // Kitty keyboard: disambiguate + press/release
        self.out.writeAll("\x1b[?1002h\x1b[?1006h"); // SGR mouse drag events
        self.out.flush();
        return self;
    }

    pub fn deinit(b: *Backend) void {
        b.out.writeAll("\x1b<2u"); // pop keyboard flags
        b.out.writeAll("\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l");
        b.out.flush();
        posix.tcsetattr(0, .NOW, b.saved_termios) catch {};
    }

    pub fn beginFrame(b: *Backend) !backend.Frame {
        if (terminalSize()) |ws| {
            const fresh = Layout.compute(ws.col, ws.row, b.layout.cell_w, b.layout.cell_h);
            if (fresh.cols != b.layout.cols or fresh.rows != b.layout.rows) {
                b.layout = fresh;
                b.parser.layout = fresh;
                b.out.writeAll("\x1b[2J");
            }
        }
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

    pub fn present(b: *Backend) u32 {
        const data = compressFrame(b.cfg.console.gfx.bytes());
        const encoded = std.base64.standard.Encoder.encode(&b64buf, data);

        b.out.writeAll("\x1b[H");
        var pos: usize = 0;
        var index: usize = 0;
        while (pos < encoded.len) : (index += 1) {
            const end = @min(pos + chunk_len, encoded.len);
            const more = end < encoded.len;
            if (index == 0) {
                b.out.print("\x1b_Ga=T,f=32,s={d},v={d},o=z,q=2,C=1,c={d},r={d},m={d};", .{
                    W, H, b.layout.place_cols, b.layout.place_rows, @intFromBool(more),
                });
            } else {
                b.out.print("\x1b_Gq=2,m={d};", .{@intFromBool(more)});
            }
            b.out.writeAll(encoded[pos..end]);
            b.out.writeAll("\x1b\\");
            b.out.flush();
            pos = end;
        }
        return b.pace();
    }

    /// Same absolute-deadline pacing as the desktop backend, so cart ticks
    /// stay at 60 Hz even when a terminal drops a presentation frame.
    fn pace(b: *Backend) u32 {
        const t0 = nowNs(b.cfg.io);
        const remain = b.next_ns - t0;
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

    /// No terminal audio API: leaving synth null keeps tone() a no-op.
    pub fn tone(b: *Backend) void {
        _ = b;
    }
};

fn compressFrame(src: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(&zbuf);
    const c = std.compress.flate.Compress.init(&w, &history, .zlib, .{
        .good = 4,
        .nice = 16,
        .lazy = 0,
        .chain = 8,
    }) catch return src;
    compressor = c;
    compressor.writer.writeAll(src) catch return src;
    compressor.finish() catch return src;
    return zbuf[0..w.end];
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

test "kitty keyboard events map to cart buttons and commands" {
    const testing = std.testing;
    var p = Parser.init(Layout.compute(80, 24, 10, 20));
    p.feed("\x1b[1;1:1D"); // left press
    try testing.expectEqual(@as(u8, 1), p.held);
    try testing.expectEqual(@as(u8, 1), p.pressed);
    p.feed("\x1b[122;1:1u"); // Z press
    try testing.expectEqual(@as(u8, 0x11), p.held);
    p.feed("\x1b[122;1:3u"); // Z release
    try testing.expectEqual(@as(u8, 1), p.held);
    p.feed("\x1b[114;5:1u"); // Ctrl+R
    try testing.expect(p.reload);
    p.feed("\x1b[27;1:1u"); // Escape
    try testing.expect(p.quit);
}

test "SGR mouse maps cells into the framebuffer" {
    const testing = std.testing;
    const l = Layout.compute(80, 24, 10, 20);
    try testing.expectEqual(@as(u16, 80), l.place_cols);
    try testing.expectEqual(@as(u16, 22), l.place_rows);
    var p = Parser.init(l);
    p.feed("\x1b[<0;2;2M");
    try testing.expectEqual(@as(u8, 1), p.mouse);
    try testing.expectEqual(@as(i32, 4), p.mouse_x);
    try testing.expectEqual(@as(i32, 0), p.mouse_y);
    p.feed("\x1b[<0;2;2m");
    try testing.expectEqual(@as(u8, 0), p.mouse);
}
