//! Scripted input for headless runs (`-i`/`--input`).
//!
//! A tape is a sparse list of frame-indexed input states. Frames are 1-based:
//! `@N` sets an absolute frame, `+N` advances N frames from the previous event.
//! The button field is a comma-separated list of held buttons (`-` releases
//! all): L, R, U, D, Z, X, LMB, RMB, MMB. An optional trailing `X,Y` sets the
//! pointer. Fields omitted by an event keep their previous value. `#` starts a
//! comment. Passing `-` as the path reads the tape from stdin.

const std = @import("std");

pub const max_events = 1024;

pub const Event = struct {
    frame: u64,
    btns: u8,
    mbtns: u8,
    mx: i32,
    my: i32,
};

pub const Tape = struct {
    events: [max_events]Event = undefined,
    count: usize = 0,

    /// Apply the last event whose frame has been reached (1-based), leaving
    /// the neutral defaults in place before the first event.
    pub fn apply(t: *const Tape, frame: u64, input: *@import("input.zig").Input) void {
        var last: ?usize = null;
        for (t.events[0..t.count], 0..) |e, i| {
            if (e.frame > frame) break;
            last = i;
        }
        if (last) |li| {
            const e = t.events[li];
            input.held = e.btns;
            input.mouse = e.mbtns;
            input.mouse_x = e.mx;
            input.mouse_y = e.my;
        }
    }
};

const ParseError = error{
    InvalidTape,
    TooManyEvents,
    OutOfMemory,
};

const SimButton = struct { name: []const u8, index: u3, mouse: bool };
const sim_buttons = [_]SimButton{
    .{ .name = "L", .index = 0, .mouse = false },
    .{ .name = "R", .index = 1, .mouse = false },
    .{ .name = "U", .index = 2, .mouse = false },
    .{ .name = "D", .index = 3, .mouse = false },
    .{ .name = "Z", .index = 4, .mouse = false },
    .{ .name = "X", .index = 5, .mouse = false },
    .{ .name = "LMB", .index = 0, .mouse = true },
    .{ .name = "RMB", .index = 1, .mouse = true },
    .{ .name = "MMB", .index = 2, .mouse = true },
};

fn parseButtons(list: []const u8, btns: *u8, mbtns: *u8) bool {
    btns.* = 0;
    mbtns.* = 0;
    if (std.mem.eql(u8, list, "-")) return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |name| {
        var found = false;
        for (sim_buttons) |sb| {
            if (!std.mem.eql(u8, name, sb.name)) continue;
            const mask = if (sb.mouse) mbtns else btns;
            mask.* |= @as(u8, 1) << sb.index;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn nextToken(rest: *[]const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, rest.*, " \t\r\n");
    if (s.len == 0) {
        rest.* = s;
        return null;
    }
    const end = std.mem.indexOfAny(u8, s, " \t\r\n") orelse s.len;
    rest.* = s[end..];
    return s[0..end];
}

fn parseU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// Parse a tape from its text. Returns a diagnostic string on failure (the
/// caller prints it with the `path:line` prefix).
fn parse(text: []const u8, tape: *Tape) ParseError!?[]const u8 {
    var btns: u8 = 0;
    var mbtns: u8 = 0;
    var mx: i32 = 160; // vex.WIDTH / 2
    var my: i32 = 90; // vex.HEIGHT / 2
    var cursor: u64 = 0;
    tape.count = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw_line| {
        lineno += 1;
        const line = if (std.mem.indexOfScalar(u8, raw_line, '#')) |h| raw_line[0..h] else raw_line;
        var rest = line;
        const marker = nextToken(&rest) orelse continue;
        if (marker.len < 2 or (marker[0] != '@' and marker[0] != '+'))
            return "invalid input tape line";
        const abs = marker[0] == '@';
        const value = parseU64(marker[1..]) orelse return "invalid input tape line";
        const frame: u64 = if (abs) value else cursor + value;
        if (frame < cursor) return "invalid input tape line";
        cursor = frame;

        const btok = nextToken(&rest) orelse return "invalid input tape line";
        if (!parseButtons(btok, &btns, &mbtns)) return "invalid input tape line";

        if (nextToken(&rest)) |mtok| {
            var coords = std.mem.splitScalar(u8, mtok, ',');
            const xs = std.mem.trim(u8, coords.next() orelse return "invalid input tape line", " ");
            const ys = std.mem.trim(u8, coords.next() orelse return "invalid input tape line", " ");
            if (coords.next() != null) return "invalid input tape line";
            const x = std.fmt.parseInt(i32, xs, 10) catch return "invalid input tape line";
            const y = std.fmt.parseInt(i32, ys, 10) catch return "invalid input tape line";
            mx = std.math.clamp(x, 0, 319); // vex.WIDTH - 1
            my = std.math.clamp(y, 0, 179); // vex.HEIGHT - 1
        }

        if (tape.count == max_events) return error.TooManyEvents;
        tape.events[tape.count] = .{ .frame = frame, .btns = btns, .mbtns = mbtns, .mx = mx, .my = my };
        tape.count += 1;
    }
    return null;
}

/// Load a tape from a path, or from stdin when path is "-". On error, writes a
/// diagnostic to stderr and returns null. `label` is used in the diagnostic.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, tape: *Tape) ?void {
    const piped = std.mem.eql(u8, path, "-");
    const label = if (piped) "<stdin>" else path;
    var stdin_buf: [max_events * 64]u8 = undefined;
    var file_data: ?[]u8 = null;
    defer if (file_data) |d| gpa.free(d);

    const data: []const u8 = if (piped) blk: {
        var reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const n = reader.interface.readSliceShort(&stdin_buf) catch {
            std.debug.print("nex: cannot read {s}\n", .{label});
            return null;
        };
        break :blk stdin_buf[0..n];
    } else blk: {
        file_data = readFile(gpa, io, path) orelse return null;
        break :blk file_data.?;
    };

    const diag = parse(data, tape) catch |err| switch (err) {
        error.TooManyEvents => {
            std.debug.print("nex: {s}: too many events (max {d})\n", .{ label, max_events });
            return null;
        },
        error.OutOfMemory => {
            std.debug.print("nex: out of memory reading {s}\n", .{label});
            return null;
        },
        else => unreachable,
    };
    if (diag) |msg| {
        std.debug.print("nex: {s}: {s}\n", .{ label, msg });
        return null;
    }
    return {};
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
        std.debug.print("nex: cannot open {s}\n", .{path});
        return null;
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(text: []const u8) !Tape {
    var tape: Tape = .{};
    const diag = try parse(text, &tape);
    try testing.expect(diag == null);
    return tape;
}

test "tape frames and held state" {
    const tape = try parseForTest(
        \\@1 Z
        \\+1 -
        \\+2 L,RMB 10,20
        \\@10 X
        \\
    );
    try testing.expectEqual(@as(usize, 4), tape.count);
    try testing.expectEqual(@as(u64, 1), tape.events[0].frame);
    try testing.expectEqual(@as(u8, 1 << 4), tape.events[0].btns);
    try testing.expectEqual(@as(u64, 2), tape.events[1].frame);
    try testing.expectEqual(@as(u8, 0), tape.events[1].btns);
    try testing.expectEqual(@as(u64, 4), tape.events[2].frame);
    try testing.expectEqual(@as(u8, 1 << 0), tape.events[2].btns); // L only
    try testing.expectEqual(@as(u8, 1 << 1), tape.events[2].mbtns);
    try testing.expectEqual(@as(i32, 10), tape.events[2].mx);
    try testing.expectEqual(@as(i32, 20), tape.events[2].my);
    try testing.expectEqual(@as(u64, 10), tape.events[3].frame);
}

test "tape apply picks the last reached event" {
    const tape = try parseForTest(
        \\@1 Z
        \\+1 -
        \\+1 L
        \\
    );
    var input: @import("input.zig").Input = .{};
    tape.apply(1, &input);
    try testing.expectEqual(@as(u8, 1 << 4), input.held);
    tape.apply(2, &input);
    try testing.expectEqual(@as(u8, 0), input.held);
    tape.apply(5, &input);
    try testing.expectEqual(@as(u8, 1 << 0), input.held);
    tape.apply(0, &input); // before first event: neutral defaults remain
    try testing.expectEqual(@as(u8, 160), input.mouse_x);
    try testing.expectEqual(@as(u8, 90), input.mouse_y);
}

test "tape rejects malformed lines and out-of-order frames" {
    var tape: Tape = .{};
    try testing.expect((try parse("BOGUS\n", &tape)) != null);
    tape = .{};
    try testing.expect((try parse("@5 -\n@3 -\n", &tape)) != null);
    tape = .{};
    try testing.expect((try parse("@1 NOPE\n", &tape)) != null);
    tape = .{};
    try testing.expect((try parse("@1 - 10\n", &tape)) != null);
}
