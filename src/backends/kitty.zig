//! Terminal backend: Kitty Graphics Protocol for output, Kitty keyboard and
//! SGR mouse protocols for input. No third-party code: everything here is Zig,
//! escape sequences and POSIX syscalls.
//!
//! The cart still draws into its 320x180 RGBA framebuffer. Each changed frame
//! is nearest-neighbour upscaled in Zig to the exact pixel size of the cell
//! rectangle it occupies, then zlib-compressed and sent as a chunked `a=T`
//! placement. Sending it at native pixel size avoids the terminal's fuzzy
//! bilinear scaling. There is no terminal audio or gamepad API, so this
//! backend leaves console.synth null and reads no pads.

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

// The deflate compressor (~220 KiB) is reused across frames; frame-sized
// scratch is allocated per terminal size.
var history: [std.compress.flate.max_window_len]u8 = undefined;
var compressor: std.compress.flate.Compress = undefined;
var detect_buf: [4096]u8 = undefined;
var prev_fb: [W * H]u32 = @splat(0xffffffff);

/// A full refresh every so often bounds the number of live placements (older
/// ids are then deleted in one range). Dirty rects use fresh ids so they never
/// remove an unrelated part of the screen.
const refresh_frames = 120;

const Layout = struct {
    cols: u16,
    rows: u16,
    cell_w: u16,
    cell_h: u16,
    /// Cell rectangle the picture occupies, centered in the terminal.
    place_cols: u16,
    place_rows: u16,
    /// Native pixel size of that rectangle; the image is upscaled to this.
    out_w: u32,
    out_h: u32,
    off_col: u16,
    off_row: u16,

    fn compute(cols_raw: u16, rows_raw: u16, cw: u16, ch: u16) Layout {
        const cols: u16 = @max(cols_raw, 1);
        const rows: u16 = @max(rows_raw, 1);
        const s = @min(
            @as(f32, @floatFromInt(cols * cw)) / @as(f32, W),
            @as(f32, @floatFromInt(rows * ch)) / @as(f32, H),
        );
        const pc = clampCells(@as(f32, W) * s / @as(f32, cw), cols);
        const pr = clampCells(@as(f32, H) * s / @as(f32, ch), rows);
        return .{
            .cols = cols,
            .rows = rows,
            .cell_w = cw,
            .cell_h = ch,
            .place_cols = pc,
            .place_rows = pr,
            .out_w = @as(u32, pc) * cw,
            .out_h = @as(u32, pr) * ch,
            .off_col = (cols - pc) / 2 + 1,
            .off_row = (rows - pr) / 2 + 1,
        };
    }

    fn clampCells(v: f32, max: u16) u16 {
        const n: u32 = @intFromFloat(@max(@floor(v + 0.00001), 1));
        return @intCast(@min(n, max));
    }

    /// SGR mouse reports 1-based cells. Map through the placement rectangle
    /// into the original framebuffer coordinates.
    fn mouseAxis(l: Layout, comptime x_axis: bool, cell: i32) i32 {
        const count: u32 = if (x_axis) l.place_cols else l.place_rows;
        const size: u32 = if (x_axis) W else H;
        const px = @as(f32, @floatFromInt(cell - (if (x_axis) l.off_col else l.off_row))) *
            @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(count));
        return std.math.clamp(@as(i32, @intFromFloat(@round(px))), 0, @as(i32, @intCast(size)) - 1);
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
    // XTWINOPS answers CSI 16t with CSI 6;<height>;<width>t (Ghostty, VTE).
    const needle = "\x1b[6;";
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
                if (ch == 0x1b) {
                    p.state = .esc;
                } else if (ch == 0x03) {
                    p.quit = true; // Ctrl+C, legacy encoding
                } else if (ch >= 0x20 and ch < 0x7f) {
                    p.key(ch, 0, 1);
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
        if (code == 'c' and (mods & 4) != 0) {
            if (!released) p.quit = true; // Ctrl+C, Kitty encoding
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
        p.text_held &= ~bit;
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
    next_id: u32 = 1,
    frames_sent: u32 = 0,
    scaled: []u32 = &.{},
    zbuf: []u8 = &.{},
    b64buf: []u8 = &.{},

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
        for (0..100) |_| {
            if (!inputReady(10)) continue;
            if (len < detect_buf.len) len += sysRead(0, detect_buf[len..]);
            if (std.mem.indexOf(u8, detect_buf[0..len], "\x1b[c") != null and
                parseCellSize(detect_buf[0..len]) != null) break;
        }
        if (std.mem.indexOf(u8, detect_buf[0..len], "\x1b_Gi=31;OK\x1b\\") == null) {
            std.debug.print("nex: terminal does not support the kitty graphics protocol\n", .{});
            return error.GraphicsUnsupported;
        }
        var cw: u16 = fallback_cell_w;
        var ch: u16 = fallback_cell_h;
        if (parseCellSize(detect_buf[0..len])) |cell| {
            cw = cell.w;
            ch = cell.h;
        }

        if (terminalSize()) |ws| self.layout = Layout.compute(ws.col, ws.row, cw, ch);
        try self.allocBuffers();
        self.parser = Parser.init(self.layout);

        self.out.writeAll("\x1b[?1049h\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
        self.out.writeAll("\x1b[>3u"); // Kitty keyboard: disambiguate + press/release
        self.out.writeAll("\x1b[?1002h\x1b[?1006h"); // SGR mouse drag events
        self.out.flush();
        return self;
    }

    fn allocBuffers(b: *Backend) !void {
        const pixels = @as(usize, b.layout.out_w) * b.layout.out_h;
        const zlen = pixels * 4 + 4096;
        const scaled = try b.cfg.gpa.alloc(u32, pixels);
        errdefer b.cfg.gpa.free(scaled);
        const zbuf = try b.cfg.gpa.alloc(u8, zlen);
        errdefer b.cfg.gpa.free(zbuf);
        const b64buf = try b.cfg.gpa.alloc(u8, (zlen * 4 + 2) / 3 + 4);
        b.cfg.gpa.free(b.scaled);
        b.cfg.gpa.free(b.zbuf);
        b.cfg.gpa.free(b.b64buf);
        b.scaled = scaled;
        b.zbuf = zbuf;
        b.b64buf = b64buf;
    }

    pub fn deinit(b: *Backend) void {
        b.cfg.gpa.free(b.scaled);
        b.cfg.gpa.free(b.zbuf);
        b.cfg.gpa.free(b.b64buf);
        b.out.writeAll("\x1b[<u"); // pop keyboard flags
        b.out.writeAll("\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l");
        b.out.flush();
        posix.tcsetattr(0, .NOW, b.saved_termios) catch {};
    }

    pub fn beginFrame(b: *Backend) !backend.Frame {
        // A lone ESC (legacy terminals) has no terminator. With no byte after
        // it by the next frame, it is the Escape key, not a sequence prefix.
        if (b.parser.state == .esc) {
            b.parser.quit = true;
            b.parser.state = .ground;
        }
        b.parser.held &= ~b.parser.text_held;
        b.parser.text_held = 0;
        if (terminalSize()) |ws| {
            const fresh = Layout.compute(ws.col, ws.row, b.layout.cell_w, b.layout.cell_h);
            if (fresh.out_w != b.layout.out_w or fresh.out_h != b.layout.out_h) {
                b.layout = fresh;
                b.parser.layout = fresh;
                try b.allocBuffers();
                @memset(&prev_fb, 0xffffffff); // force a full redraw on resize
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
        const fb = b.cfg.console.gfx.bytes();
        if (dirtyRect(fb)) |rect| {
            const area = @as(u32, rect.w) * rect.h;
            const full = b.frames_sent == 0 or b.frames_sent % refresh_frames == 0 or
                area * 4 > @as(u32, W) * H;
            b.sendFrame(fb, if (full) .{ .x = 0, .y = 0, .w = W, .h = H } else rect, full);
            b.frames_sent += 1;
        }
        return b.pace();
    }

    /// Smallest bounding box of changed pixels in framebuffer coordinates.
    /// prev_fb uses 0xffffffff as "never drawn", so the first frame is full.
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

    fn sendFrame(b: *Backend, fb_bytes: []const u8, dirty: Rect, full: bool) void {
        const l = b.layout;
        // Map the dirty rect to output pixels, then snap to cell boundaries so
        // the partial image lands exactly on the terminal's cell grid.
        const px0 = (@as(u32, dirty.x) * l.out_w / W / l.cell_w) * l.cell_w;
        const py0 = (@as(u32, dirty.y) * l.out_h / H / l.cell_h) * l.cell_h;
        const px1 = ((@as(u32, dirty.x + dirty.w) * l.out_w + W - 1) / W + l.cell_w - 1) / l.cell_w * l.cell_w;
        const py1 = ((@as(u32, dirty.y + dirty.h) * l.out_h + H - 1) / H + l.cell_h - 1) / l.cell_h * l.cell_h;
        const rw: u32 = @min(px1 - px0, l.out_w - px0);
        const rh: u32 = @min(py1 - py0, l.out_h - py0);

        const src = nearestScale(b, fb_bytes, dirty, px0, py0, rw, rh);
        const frame = compressFrame(b, src);
        const encoded = std.base64.standard.Encoder.encode(b.b64buf, frame.data);

        const col: u16 = l.off_col + @as(u16, @intCast(px0 / l.cell_w));
        const row: u16 = l.off_row + @as(u16, @intCast(py0 / l.cell_h));
        b.out.print("\x1b[{d};{d}H", .{ row, col });
        const id = b.next_id;
        b.next_id += 1;
        if (full and id > 1) {
            // Drop all earlier placements; the fresh full frame replaces them.
            b.out.print("\x1b_Ga=d,d=R,x=1,y={d},q=1\x1b\\", .{id - 1});
        }
        var pos: usize = 0;
        var index: usize = 0;
        while (pos < encoded.len) : (index += 1) {
            const end = @min(pos + chunk_len, encoded.len);
            const more = end < encoded.len;
            if (index == 0) {
                // No c/r: the image is already the exact pixel size of the
                // cell rectangle, so the terminal displays it 1:1 (no blur).
                b.out.print("\x1b_Ga=T,i={d},f=32,s={d},v={d},q=1,C=1,m={d}{s};", .{
                    id, rw, rh, @intFromBool(more), if (frame.compressed) ",o=z" else "",
                });
            } else {
                b.out.print("\x1b_Gq=1,m={d};", .{@intFromBool(more)});
            }
            b.out.writeAll(encoded[pos..end]);
            b.out.writeAll("\x1b\\");
            b.out.flush();
            pos = end;
        }
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

const FrameData = struct { data: []const u8, compressed: bool };

const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Pixel-perfect nearest-neighbour upscale of just the dirty rectangle. The
/// terminal would otherwise interpolate a scaled placement and blur pixels.
fn nearestScale(b: *const Backend, fb_bytes: []const u8, dirty: Rect, px0: u32, py0: u32, rw: u32, rh: u32) []const u8 {
    const l = b.layout;
    if (l.out_w == W and l.out_h == H) {
        // 1:1: copy the source rows directly into the scratch buffer.
        const src: []const u32 = @ptrCast(@alignCast(fb_bytes));
        for (0..rh) |y| {
            const sy = dirty.y + py0 + y;
            const so = sy * W + dirty.x + px0;
            @memcpy(b.scaled[y * rw ..][0..rw], src[so..][0..rw]);
        }
    } else {
        const src: []const u32 = @ptrCast(@alignCast(fb_bytes));
        for (0..rh) |y| {
            const sy: usize = @intCast(@min((py0 + y) * H / l.out_h, H - 1));
            const row = b.scaled[y * rw ..][0..rw];
            for (0..rw) |x| {
                const sx: usize = @intCast(@min((px0 + x) * W / l.out_w, W - 1));
                row[x] = src[sy * W + sx];
            }
        }
    }
    return std.mem.sliceAsBytes(b.scaled[0 .. rw * rh]);
}

fn compressFrame(b: *const Backend, src: []const u8) FrameData {
    // shortcut: full-frame zlib is enough (~60 fps measured; static frames
    // are skipped entirely); revisit dirty rows if a noisy cart is too slow.
    var w: std.Io.Writer = .fixed(b.zbuf);
    const c = std.compress.flate.Compress.init(&w, &history, .zlib, .{
        .good = 4,
        .nice = 8,
        .lazy = 0,
        .chain = 4,
    }) catch return .{ .data = src, .compressed = false };
    compressor = c;
    compressor.writer.writeAll(src) catch return .{ .data = src, .compressed = false };
    compressor.finish() catch return .{ .data = src, .compressed = false };
    const out = b.zbuf[0..w.end];
    // Incompressible frames are cheaper to send raw than as zlib+base64.
    if (out.len >= src.len) return .{ .data = src, .compressed = false };
    return .{ .data = out, .compressed = true };
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
    p.quit = false;
    p.feed("\x1b[99;5:1u"); // Ctrl+C
    try testing.expect(p.quit);
    p.quit = false;
    p.feed("\x03"); // legacy Ctrl+C
    try testing.expect(p.quit);
}

test "dirty rect is the bounding box of changed pixels" {
    const testing = std.testing;
    @memset(&prev_fb, 0);
    var fb: [W * H]u32 = @splat(0);
    fb[10 * W + 20] = 1;
    fb[12 * W + 30] = 2;
    const r = Backend.dirtyRect(std.mem.sliceAsBytes(&fb)).?;
    try testing.expectEqual(@as(u32, 20), r.x);
    try testing.expectEqual(@as(u32, 10), r.y);
    try testing.expectEqual(@as(u32, 11), r.w);
    try testing.expectEqual(@as(u32, 3), r.h);
    try testing.expect(Backend.dirtyRect(std.mem.sliceAsBytes(&fb)) == null);
}

test "cell size reply uses CSI 6;h;wt" {
    const testing = std.testing;
    const cell = parseCellSize("\x1b[?62c\x1b[6;21;11t");
    try testing.expectEqual(@as(u16, 11), cell.?.w);
    try testing.expectEqual(@as(u16, 21), cell.?.h);
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
