//! Cart-visible input state. The platform layer fills it once per rendered
//! frame; the cart API only reads it, so this file has no raylib dependency
//! and headless runs simply leave everything released.

pub const buttons = 6;

pub const Input = struct {
    /// Bit i set while cart button i is held.
    held: u8 = 0,
    /// `held` as it was after the previous cart tick (for btnp edges).
    prev: u8 = 0,
    /// Presses latched since the last tick. A 144 Hz frame often runs zero
    /// ticks, so presses seen by the platform are latched until consumed.
    pressed: u8 = 0,
    // Headless runs have no backend to set the pointer; use the screen centre
    // (vex.WIDTH/2, vex.HEIGHT/2) to match the C host's default.
    mouse_x: i32 = 160,
    mouse_y: i32 = 90,
    /// Bit i set while mouse button i (0 left, 1 right, 2 middle) is held.
    mouse: u8 = 0,

    inline fn bit(mask: u8, i: i32, limit: i32) bool {
        return i >= 0 and i < limit and (mask >> @intCast(i)) & 1 != 0;
    }

    pub fn btn(s: *const Input, b: i32) bool {
        return bit(s.held, b, buttons);
    }

    pub fn btnp(s: *const Input, b: i32) bool {
        return bit(s.pressed, b, buttons) or (bit(s.held, b, buttons) and !bit(s.prev, b, buttons));
    }

    pub fn mbtn(s: *const Input, b: i32) bool {
        return bit(s.mouse, b, 3);
    }

    /// Call after every cart tick.
    pub fn endTick(s: *Input) void {
        s.prev = s.held;
        s.pressed = 0;
    }
};

test "btnp fires once per press" {
    const std = @import("std");
    var in: Input = .{};
    in.held = 1 << 4;
    try std.testing.expect(in.btnp(4));
    in.endTick();
    try std.testing.expect(!in.btnp(4));
    try std.testing.expect(in.btn(4));
    try std.testing.expect(!in.btn(-1) and !in.btn(6) and !in.btnp(99));
}
