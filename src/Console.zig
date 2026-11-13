//! Everything a cart can observe or change through its imports. Platform
//! layers (window, headless) own one Console and hand it to the cart.

const Console = @This();

const std = @import("std");
const gfx_mod = @import("gfx.zig");
const Input = @import("input.zig").Input;
const Synth = @import("synth.zig").Synth;

pub const default_title = "nex";

gfx: gfx_mod.Gfx = .{},
input: Input = .{},
/// Null when there is no audio device, in headless runs, and while a reload
/// candidate boots: tone() is then a no-op.
synth: ?*Synth = null,
/// Set by the first audible tone(); the platform opens its stream lazily so
/// silent carts never touch the audio device.
tone_used: bool = false,

title_buf: [128:0]u8 = initTitle(),
/// Set by title(); the platform clears it after applying the title.
title_dirty: bool = false,

fn initTitle() [128:0]u8 {
    var b: [128:0]u8 = @splat(0);
    @memcpy(b[0..default_title.len], default_title);
    return b;
}

pub fn reset(c: *Console) void {
    c.gfx.reset();
    c.input = .{};
    if (c.synth) |s| s.clear();
}

pub fn setTitle(c: *Console, s: []const u8) void {
    const n = @min(s.len, c.title_buf.len);
    @memcpy(c.title_buf[0..n], s[0..n]);
    if (n < c.title_buf.len) c.title_buf[n] = 0;
    c.title_dirty = true;
}

pub fn title(c: *const Console) [:0]const u8 {
    return std.mem.sliceTo(&c.title_buf, 0);
}

/// Cart-visible host state, saved so a rejected reload can be undone.
pub const Snapshot = struct {
    palette: [16]u32,
    fb: [gfx_mod.W * gfx_mod.H]u32,
    title_buf: [128:0]u8,
    prev: u8,
    pressed: u8,
};

pub fn snapshot(c: *const Console, s: *Snapshot) void {
    s.palette = c.gfx.palette;
    s.fb = c.gfx.fb;
    s.title_buf = c.title_buf;
    s.prev = c.input.prev;
    s.pressed = c.input.pressed;
}

pub fn restore(c: *Console, s: *const Snapshot) void {
    c.gfx.palette = s.palette;
    c.gfx.fb = s.fb;
    c.title_buf = s.title_buf;
    c.title_dirty = true;
    c.input.prev = s.prev;
    c.input.pressed = s.pressed;
}
