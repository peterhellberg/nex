//! Minimal Zig cart: move a ball with the arrows, Z beeps, mouse paints.
const vex = @import("vex");

var x: i32 = vex.WIDTH / 2;
var y: i32 = vex.HEIGHT / 2;
var t: u32 = 0;

export fn boot() void {
    vex.title("nex - hello.zig");
}

export fn update() void {
    t +%= 1;
    if (vex.down(vex.LEFT)) x -= 2;
    if (vex.down(vex.RIGHT)) x += 2;
    if (vex.down(vex.UP)) y -= 2;
    if (vex.down(vex.DOWN)) y += 2;
    if (vex.pressed(vex.Z)) vex.play(.{ .freq = 72, .extra = vex.TONE_NOTE_MODE, .sustain = 6, .release = 8 });
    if (vex.pressed(vex.X)) vex.play(.{ .channel = 1, .freq = 220, .wave = vex.TONE_NOISE, .release = 10 });

    vex.cls(0);
    const pulse: i32 = @intCast((t / 8) % 4);
    vex.tri(20, 170, 60, 120, 100, 170, 7);
    vex.rectb(2, 2, vex.WIDTH - 4, vex.HEIGHT - 4, 15);
    vex.circ(x, y, 10 + pulse, 4);
    vex.circb(x, y, 14 + pulse, 3);
    vex.text("HELLO FROM NEX", 8, 8, 12);
    vex.text("arrows move, Z/X sound", 8, 20, 13);
    if (vex.mdown(vex.MOUSE_LEFT)) vex.circ(vex.mx(), vex.my(), 3, 11);
}
