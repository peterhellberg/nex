//! Software framebuffer and drawing primitives.
//!
//! Every primitive is a port of the C host (cmd/vex/main.c), which in turn
//! matches the Go and JS hosts pixel-for-pixel. Palette lookups happen at draw
//! time, so `pal()` only affects pixels drawn after it, as in the other hosts.
//! Arithmetic that can see cart-controlled values uses wrapping operators to
//! mirror the C host (compiled with -fwrapv) instead of trapping.

const std = @import("std");
const font = @import("font.zig");

pub const W = 320;
pub const H = 180;

/// Coordinates beyond this are rejected so a malformed cart cannot pin the
/// rasterizers (~16x overscan tolerance).
pub const coord_max = W * 16;
const tri_max_rows = 2 * coord_max + 1;

/// Pack 0xRRGGBB into the RGBA8 byte order raylib uploads (R in the low byte).
pub fn rgba(rgb: u32) u32 {
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;
    return r | g << 8 | b << 16 | 0xFF << 24;
}

/// SWEETIE-16.
pub const default_palette = blk: {
    const hex = [16]u32{
        0x1a1c2c, 0x5d275d, 0xb13e53, 0xef7d57, 0xffcd75, 0xa7f070, 0x38b764, 0x257179,
        0x29366f, 0x3b5dc9, 0x41a6f6, 0x73eff7, 0xf4f4f4, 0x94b0c2, 0x566c86, 0x333c57,
    };
    var p: [16]u32 = undefined;
    for (hex, 0..) |h, i| p[i] = rgba(h);
    break :blk p;
};

inline fn coordOk(v: i32) bool {
    return v >= -coord_max and v <= coord_max;
}

inline fn coordsOk(x: i32, y: i32) bool {
    return coordOk(x) and coordOk(y);
}

pub const Gfx = struct {
    fb: [W * H]u32 = undefined,
    palette: [16]u32 = default_palette,
    tri_l: [tri_max_rows]i32 = undefined,
    tri_r: [tri_max_rows]i32 = undefined,

    pub fn reset(g: *Gfx) void {
        g.palette = default_palette;
        @memset(&g.fb, g.palette[0]);
    }

    /// Fill with the current palette entry 0.
    pub fn prime(g: *Gfx) void {
        @memset(&g.fb, g.palette[0]);
    }

    pub fn bytes(g: *const Gfx) []const u8 {
        return std.mem.sliceAsBytes(&g.fb);
    }

    inline fn color(g: *const Gfx, index: i32) u32 {
        return g.palette[@as(u32, @bitCast(index)) & 15];
    }

    inline fn put(g: *Gfx, x: i32, y: i32, c: u32) void {
        if (x >= 0 and x < W and y >= 0 and y < H)
            g.fb[@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))] = c;
    }

    /// Inclusive horizontal span on row y, clipped.
    fn hline(g: *Gfx, y: i32, a: i32, b: i32, c: u32) void {
        if (y < 0 or y >= H) return;
        var x0 = @min(a, b);
        var x1 = @max(a, b);
        if (x1 < 0 or x0 >= W) return;
        x0 = @max(x0, 0);
        x1 = @min(x1, W - 1);
        const row = @as(usize, @intCast(y)) * W;
        @memset(g.fb[row + @as(usize, @intCast(x0)) ..][0..@intCast(x1 - x0 + 1)], c);
    }

    fn fillRect(g: *Gfx, x: i32, y: i32, w_in: i32, h_in: i32, c: u32) void {
        if (w_in <= 0 or h_in <= 0) return;
        if (!coordsOk(x, y)) return;
        const w = @min(w_in, W);
        const h = @min(h_in, H);
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, W);
        const y1 = @min(y + h, H);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            const row = @as(usize, @intCast(yy)) * W;
            if (x0 < x1) @memset(g.fb[row + @as(usize, @intCast(x0)) .. row + @as(usize, @intCast(x1))], c);
        }
    }

    fn bresenham(g: *Gfx, x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: u32) void {
        var x0 = x0_in;
        var y0 = y0_in;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;
        while (true) {
            g.put(x0, y0, c);
            if (x0 == x1 and y0 == y1) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                x0 += sx;
            }
            if (e2 < dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    fn circle(g: *Gfx, x: i32, y: i32, r_in: i32, c: u32, fill: bool) void {
        const r = std.math.clamp(r_in, 0, coord_max);
        if (!coordsOk(x, y)) return;
        var rx = r;
        var ry: i32 = 0;
        var err: i32 = 0;
        while (rx >= ry) {
            if (fill) {
                g.hline(y + ry, x - rx, x + rx, c);
                g.hline(y + rx, x - ry, x + ry, c);
                g.hline(y - ry, x - rx, x + rx, c);
                g.hline(y - rx, x - ry, x + ry, c);
            } else {
                g.put(x + rx, y + ry, c);
                g.put(x + ry, y + rx, c);
                g.put(x - ry, y + rx, c);
                g.put(x - rx, y + ry, c);
                g.put(x - rx, y - ry, c);
                g.put(x - ry, y - rx, c);
                g.put(x + ry, y - rx, c);
                g.put(x + rx, y - ry, c);
            }
            ry += 1;
            if (err <= 0) {
                err += 2 * ry + 1;
            } else {
                rx -= 1;
                err += 2 * (ry - rx) + 1;
            }
        }
    }

    // f64 math to match the Go/JS hosts bit-for-bit at half-pixel boundaries.
    // Zig never contracts a*b+c into an FMA unless asked, so this matches the
    // C host's -ffp-contract=off.
    fn triEdge(g: *Gfx, ax: i32, ay: i32, bx: i32, by: i32, ymin: i32) void {
        if (ay == by) return; // horizontal: endpoints covered by the other edges
        const slope = @as(f64, @floatFromInt(bx - ax)) / @as(f64, @floatFromInt(by - ay));
        var y = @min(ay, by);
        const ye = @max(ay, by);
        while (y <= ye) : (y += 1) {
            const xf = @as(f64, @floatFromInt(ax)) + @as(f64, @floatFromInt(y - ay)) * slope;
            const xi: i32 = @intFromFloat(xf); // truncates toward zero, NOT floor
            const i: usize = @intCast(y - ymin);
            g.tri_l[i] = @min(g.tri_l[i], xi);
            g.tri_r[i] = @max(g.tri_r[i], xi);
        }
    }

    // ---- cart API (color arguments are palette indices) -------------------

    pub fn cls(g: *Gfx, color_index: i32) void {
        @memset(&g.fb, g.color(color_index));
    }

    pub fn pset(g: *Gfx, x: i32, y: i32, color_index: i32) void {
        g.put(x, y, g.color(color_index));
    }

    pub fn rect(g: *Gfx, x: i32, y: i32, w: i32, h: i32, color_index: i32) void {
        g.fillRect(x, y, w, h, g.color(color_index));
    }

    /// Four edges decomposed exactly like the other hosts, so corners and
    /// degenerate sizes land on the same pixels.
    pub fn rectb(g: *Gfx, x: i32, y: i32, w: i32, h: i32, color_index: i32) void {
        const c = g.color(color_index);
        g.fillRect(x, y, w, 1, c);
        g.fillRect(x, y +% h -% 1, w, 1, c);
        g.fillRect(x, y +% 1, 1, h -% 2, c);
        if (w > 1) g.fillRect(x +% w -% 1, y +% 1, 1, h -% 2, c);
    }

    pub fn circ(g: *Gfx, x: i32, y: i32, r: i32, color_index: i32) void {
        g.circle(x, y, r, g.color(color_index), true);
    }

    pub fn circb(g: *Gfx, x: i32, y: i32, r: i32, color_index: i32) void {
        g.circle(x, y, r, g.color(color_index), false);
    }

    pub fn line(g: *Gfx, x0: i32, y0: i32, x1: i32, y1: i32, color_index: i32) void {
        if (!coordsOk(x0, y0) or !coordsOk(x1, y1)) return;
        g.bresenham(x0, y0, x1, y1, g.color(color_index));
    }

    pub fn tri(g: *Gfx, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color_index: i32) void {
        if (!coordsOk(x1, y1) or !coordsOk(x2, y2) or !coordsOk(x3, y3)) return;
        const ymin = @min(y1, y2, y3);
        const ymax = @max(y1, y2, y3);
        const n: usize = @intCast(ymax - ymin + 1); // <= tri_max_rows by coordsOk
        const inf: i32 = 1 << 30;
        @memset(g.tri_l[0..n], inf);
        @memset(g.tri_r[0..n], -inf);
        g.triEdge(x1, y1, x2, y2, ymin);
        g.triEdge(x2, y2, x3, y3, ymin);
        g.triEdge(x3, y3, x1, y1, ymin);
        const c = g.color(color_index);
        for (0..n) |i| {
            if (g.tri_l[i] <= g.tri_r[i])
                g.hline(ymin + @as(i32, @intCast(i)), g.tri_l[i], g.tri_r[i], c);
        }
    }

    pub fn trib(g: *Gfx, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color_index: i32) void {
        if (!coordsOk(x1, y1) or !coordsOk(x2, y2) or !coordsOk(x3, y3)) return;
        const c = g.color(color_index);
        g.bresenham(x1, y1, x2, y2, c);
        g.bresenham(x2, y2, x3, y3, c);
        g.bresenham(x3, y3, x1, y1, c);
    }

    /// Byte length of the w*h source bitmap a blit reads, or null when the
    /// call draws nothing (cart memory must then not be touched). The whole
    /// bitmap must be in cart memory even if only part of it is on screen.
    pub fn blitSize(x: i32, y: i32, w: i32, h: i32) ?usize {
        if (w <= 0 or h <= 0 or !coordsOk(x, y)) return null;
        return @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    }

    /// `data` holds w*h palette indices, row stride w. Only the rows and
    /// columns that land on screen are visited, so huge bitmaps cost nothing
    /// beyond their visible part.
    pub fn blit(g: *Gfx, data: []const u8, x: i32, y: i32, w: i32, h: i32, key: i32, map: ?*const [16]u8) void {
        // x, y are coordsOk-bounded and w, h positive, so i64 can't overflow.
        const x0: i64 = x;
        const y0: i64 = y;
        const col_start: usize = @intCast(@max(0, -x0));
        const col_end: usize = @intCast(@max(0, @min(@as(i64, w), W - x0)));
        const row_start: usize = @intCast(@max(0, -y0));
        const row_end: usize = @intCast(@max(0, @min(@as(i64, h), H - y0)));
        if (col_start >= col_end) return;
        const stride: usize = @intCast(w);
        for (row_start..row_end) |row| {
            const yy: usize = @intCast(y0 + @as(i64, @intCast(row)));
            const dst = g.fb[yy * W ..][0..W];
            const src = data[row * stride ..][0..stride];
            for (col_start..col_end) |col| {
                const px = src[col];
                if (@as(i32, px) == key) continue;
                const idx = if (map) |m| m[px & 15] & 15 else px & 15;
                dst[@intCast(x0 + @as(i64, @intCast(col)))] = g.palette[idx];
            }
        }
    }

    /// Unsupported characters advance a full cell, matching the other hosts.
    pub fn text(g: *Gfx, s: []const u8, x_in: i32, y: i32, color_index: i32) void {
        const c = g.color(color_index);
        var x = x_in;
        for (s) |ch| {
            defer x +%= font.width;
            if (ch < font.first or ch >= font.first + font.glyphs.len) continue;
            const idx = ch - font.first;
            for (0..font.height) |ry| {
                const bits = font.row(idx, @intCast(ry));
                if (bits == 0) continue;
                for (0..font.width) |col| {
                    if (bits & (@as(u8, 0x80) >> @intCast(col)) != 0)
                        g.put(x +% @as(i32, @intCast(col)), y +% @as(i32, @intCast(ry)), c);
                }
            }
        }
    }

    pub fn pal(g: *Gfx, index: i32, rgb: i32) void {
        g.palette[@as(u32, @bitCast(index)) & 15] = rgba(@bitCast(rgb));
    }

    pub fn palreset(g: *Gfx) void {
        g.palette = default_palette;
    }
};

// ---- tests ------------------------------------------------------------------

fn testGfx() !*Gfx {
    const g = try std.testing.allocator.create(Gfx);
    g.* = .{};
    g.reset();
    return g;
}

fn at(g: *const Gfx, x: usize, y: usize) u32 {
    return g.fb[y * W + x];
}

test "rect clips and ignores degenerate sizes" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    g.rect(-5, -5, 10, 10, 12);
    try std.testing.expectEqual(default_palette[12], at(g, 0, 0));
    try std.testing.expectEqual(default_palette[12], at(g, 4, 4));
    try std.testing.expectEqual(default_palette[0], at(g, 5, 5));
    g.rect(100, 100, 0, 10, 12);
    try std.testing.expectEqual(default_palette[0], at(g, 100, 100));
}

test "circ radius 0 is one pixel" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    g.circ(10, 10, 0, 3);
    try std.testing.expectEqual(default_palette[3], at(g, 10, 10));
    try std.testing.expectEqual(default_palette[0], at(g, 11, 10));
}

test "hostile coordinates do not crash" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    const big = std.math.maxInt(i32);
    const small = std.math.minInt(i32);
    g.rect(big, small, big, big, 1);
    g.rectb(0, 0, big, big, 1);
    g.rectb(small, small, small, small, 1);
    g.line(small, 0, big, 0, 1);
    g.tri(small, small, big, big, 0, 0, 1);
    g.circ(0, 0, big, 1);
    g.text("hello", big, big, 1);
    try std.testing.expect(Gfx.blitSize(0, 0, big, big) != null);
}

test "wide blit keeps its row stride" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    // 400x2 bitmap: row 0 all 1s, row 1 all 2s. Clamping the stride to 320
    // would read row 1 starting inside row 0.
    var data: [800]u8 = undefined;
    @memset(data[0..400], 1);
    @memset(data[400..800], 2);
    g.blit(&data, -40, 0, 400, 2, -1, null);
    try std.testing.expectEqual(default_palette[1], at(g, 0, 0));
    try std.testing.expectEqual(default_palette[1], at(g, W - 1, 0));
    try std.testing.expectEqual(default_palette[2], at(g, 0, 1));
    try std.testing.expectEqual(default_palette[2], at(g, W - 1, 1));
}

test "blit clips on every side and honours key and map" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    const data = [_]u8{ 3, 5, 3, 5 }; // 2x2
    var map: [16]u8 = @splat(0);
    map[3] = 7;
    g.blit(&data, -1, -1, 2, 2, 5, &map); // only (1,1) -> (0,0) is visible; it's key 5
    try std.testing.expectEqual(default_palette[0], at(g, 0, 0));
    g.blit(&data, W - 1, H - 1, 2, 2, 5, &map); // only (0,0) visible: 3 -> map 7
    try std.testing.expectEqual(default_palette[7], at(g, W - 1, H - 1));
}

test "tilde has a glyph" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    g.text("~", 0, 0, 12);
    var lit: usize = 0;
    for (0..8) |y| for (0..8) |x| {
        if (at(g, x, y) == default_palette[12]) lit += 1;
    };
    try std.testing.expect(lit > 0);
}

test "text draws glyph pixels" {
    const g = try testGfx();
    defer std.testing.allocator.destroy(g);
    g.text("!", 0, 0, 12); // '!' row 0 = 0x18: columns 3 and 4
    try std.testing.expectEqual(default_palette[12], at(g, 3, 0));
    try std.testing.expectEqual(default_palette[12], at(g, 4, 0));
    try std.testing.expectEqual(default_palette[0], at(g, 2, 0));
}
