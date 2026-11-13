//! Four-voice tone synthesizer behind the `tone()` import, ported from the C
//! host. Time is measured in cart frames (1/60 s): carts pass packed ADSR
//! durations and the synth schedules the envelopes itself.
//!
//! Threading: `tone()` runs on the main (wasm) thread and `render()` on the
//! audio thread. Triggers are parked in per-channel pending slots behind a
//! tiny spinlock and applied at the start of the next render, so neither side
//! ever holds the lock while mixing. Voice state is only touched by render().
//! The synth has no raylib dependency, so headless runs can render it too.

const std = @import("std");

pub const channels = 4;

/// Full-scale single-voice amplitude in s16 units (matches the other hosts).
const full_amp = 8000.0;
/// Noise LFSR clock bounds: below ~8 kHz it buzzes, above ~48 kHz it aliases.
const noise_clk_min = 8000.0;
const noise_clk_max = 48000.0;

pub const Wave = enum(u2) { pulse, noise, triangle };

/// A decoded tone() call, applied to a voice by the mixer.
pub const Trigger = struct {
    wave: Wave,
    fm: bool,
    fm_ratio: u8,
    fm_index: f64,
    duty: f64,
    duty_to: f64,
    f0: f64,
    f1: f64,
    frames: [4]u8, // attack, decay, sustain, release
    hold: bool,
    release_only: bool,
    peak: f64,
    sus: f64,
    gl: f64,
    gr: f64,

    /// Decode tone()'s packed arguments (layouts in vex.h). Every field is
    /// clamped defensively. Returns the channel alongside the trigger.
    pub fn decode(freq: i32, duration: i32, volume: i32, flags_in: i32) struct { u2, Trigger } {
        const flags: u32 = @bitCast(flags_in);
        const dur: u32 = @bitCast(duration);
        const vol: u32 = @bitCast(volume);
        const fq: u32 = @bitCast(freq);

        const duty_table = [4]f64{ 0.5, 0.25, 0.125, 0.75 };
        const pan_l = [3]f64{ 0.70710678, 1.0, 0.0 };
        const pan_r = [3]f64{ 0.70710678, 0.0, 1.0 };

        const ch: u2 = @truncate(flags);
        const mode: u2 = @truncate(flags >> 2);
        var pan: u2 = @truncate(flags >> 4);
        if (pan > 2) pan = 0;
        var wave: u2 = @truncate(flags >> 6);
        if (wave == 3) wave = 0;
        const pwm = (flags >> 11) & 1 != 0;
        const fm = (flags >> 30) & 1 != 0;

        var f0: f64 = undefined;
        var f1: f64 = 0;
        if ((flags >> 8) & 1 != 0) { // note mode: MIDI note number
            f0 = 440.0 * std.math.pow(f64, 2.0, (@as(f64, @floatFromInt(freq)) - 69.0) / 12.0);
        } else {
            f0 = @floatFromInt(fq & 0xFFFF);
            f1 = @floatFromInt((fq >> 16) & 0xFFFF);
            if (f0 < 1.0) f0 = 1.0;
        }
        f0 = @min(f0, 20000.0);
        if (f1 > 0.0 and f1 < 1.0) f1 = 0.0;
        f1 = @min(f1, 20000.0);

        const duty = if (pwm) @as(f64, @floatFromInt((flags >> 12) & 255)) / 255.0 else duty_table[mode];
        const duty_to = if (pwm) @as(f64, @floatFromInt((flags >> 20) & 255)) / 255.0 else duty;

        const vs: u32 = @min(vol & 0xFF, 100);
        var vp: u32 = (vol >> 8) & 0xFF;
        if (vp == 0 or vp > 100) vp = 100; // unset peak defaults to full

        return .{ ch, .{
            .wave = @enumFromInt(wave),
            .fm = fm,
            .fm_ratio = @truncate(vol >> 16),
            .fm_index = if (fm) @as(f64, @floatFromInt((vol >> 24) & 255)) / 255.0 else 0.0,
            .duty = duty,
            .duty_to = duty_to,
            .f0 = f0,
            .f1 = f1,
            .frames = .{ @truncate(dur >> 24), @truncate(dur >> 16), @truncate(dur), @truncate(dur >> 8) },
            .hold = (flags >> 9) & 1 != 0,
            .release_only = (flags >> 10) & 1 != 0,
            .peak = @as(f64, @floatFromInt(vp)) / 100.0,
            .sus = @as(f64, @floatFromInt(vs)) / 100.0,
            .gl = pan_l[pan],
            .gr = pan_r[pan],
        } };
    }
};

const Seg = enum(i8) { start = -1, attack = 0, decay = 1, sustain = 2, release = 3, idle = 4 };

const Voice = struct {
    wave: Wave = .pulse,
    duty: f64 = 0.5,
    duty_to: f64 = 0.5,
    duty_step: f64 = 0,
    duty_left: i64 = 0,
    freq: f64 = 440,
    freq_to: f64 = 0,
    freq_start: f64 = 440,
    freq_step: f64 = 0,
    ph: f64 = 0,
    mod_ph: f64 = 0,
    nph: f64 = 0,
    fm: bool = false,
    fm_ratio: f64 = 1,
    fm_index: f64 = 0,
    lfsr: u16 = 0x2CE1,
    lp: f64 = 0,
    dc: f64 = 0,
    dc_prev: f64 = 0,

    seg: Seg = .idle,
    hold: bool = false,
    seg_left: i64 = 0,
    level: f64 = 0,
    slope: f64 = 0,
    seg_len: [4]i64 = .{ 0, 0, 0, 0 },
    seg_end: [4]f64 = .{ 0, 0, 0, 0 },
    gl: f64 = 0.70710678,
    gr: f64 = 0.70710678,

    fn segIndex(v: *const Voice) usize {
        return @intCast(@intFromEnum(v.seg));
    }

    /// Advance into the next non-empty envelope segment, snapping through
    /// zero-length ones. Enters idle when release finishes.
    fn nextSegment(v: *Voice) void {
        if (v.seg == .sustain and v.freq_to > 0.0) v.freq = v.freq_to;
        if (v.seg == .sustain and v.hold) {
            v.seg_left = 1;
            v.slope = 0;
            return;
        }
        while (true) {
            v.seg = @enumFromInt(@intFromEnum(v.seg) + 1);
            if (v.seg == .idle) {
                v.level = 0;
                return;
            }
            const i = v.segIndex();
            const n = v.seg_len[i];
            if (n <= 0) {
                v.level = v.seg_end[i];
                if (v.seg == .sustain) {
                    if (v.freq_to > 0.0) v.freq = v.freq_to;
                    v.duty = v.duty_to;
                    v.duty_step = 0;
                    v.duty_left = 0;
                    if (v.hold) {
                        v.seg_left = 1;
                        v.slope = 0;
                        return;
                    }
                }
                continue;
            }
            const nf: f64 = @floatFromInt(n);
            v.seg_left = n;
            v.slope = (v.seg_end[i] - v.level) / nf;
            if (v.seg == .sustain) {
                // The slide rides the sustain: linear in Hz across its samples.
                if (v.freq_to > 0.0) v.freq_step = (v.freq_to - v.freq_start) / nf;
                if (v.duty_to != v.duty) {
                    v.duty_left = n;
                    v.duty_step = (v.duty_to - v.duty) / nf;
                }
            }
            return;
        }
    }

    fn apply(v: *Voice, t: *const Trigger, spf: f64) void {
        const samples = struct {
            fn of(frames: u8, s: f64) i64 {
                return if (frames > 0) @intFromFloat(@as(f64, @floatFromInt(frames)) * s + 0.5) else 0;
            }
        }.of;

        if (t.release_only) {
            if (v.seg == .idle) return;
            const n = samples(t.frames[3], spf);
            if (n <= 0) {
                v.seg = .idle;
                v.level = 0;
                return;
            }
            v.seg = .release;
            v.seg_end[3] = 0;
            v.seg_left = n;
            v.slope = -v.level / @as(f64, @floatFromInt(n));
            v.freq_step = 0;
            v.duty_step = 0;
            v.duty_left = 0;
            return;
        }

        v.* = .{
            .wave = t.wave,
            .duty = t.duty,
            .duty_to = t.duty_to,
            .freq_start = t.f0,
            .freq_to = t.f1,
            .freq = t.f0,
            .hold = t.hold,
            .fm = t.fm,
            .fm_ratio = @floatFromInt(t.fm_ratio),
            .fm_index = t.fm_index,
            .gl = t.gl,
            .gr = t.gr,
        };

        const ends = [4]f64{ t.peak, t.sus, t.sus, 0.0 };
        var total: i64 = 0;
        for (0..4) |i| {
            v.seg_len[i] = samples(t.frames[i], spf);
            v.seg_end[i] = ends[i];
            total += v.seg_len[i];
        }
        if (total <= 0) { // the kill idiom: every segment empty silences now
            v.seg = .idle;
            v.level = 0;
            return;
        }
        // Pad zero-length attacks to a sub-millisecond fade-in: jumping to
        // peak on the first sample clicks audibly on every trigger.
        v.seg_len[0] = @max(v.seg_len[0], 32);
        v.seg = .start;
        v.level = 0;
        v.nextSegment();
    }

    fn sample(v: *Voice, rate: f64) f64 {
        var s: f64 = switch (v.wave) {
            .noise => blk: { // full-period 15-bit LFSR
                v.nph += std.math.clamp(2.0 * v.freq, noise_clk_min, noise_clk_max) / rate;
                while (v.nph >= 1.0) {
                    v.nph -= 1.0;
                    const b: u16 = (v.lfsr ^ (v.lfsr >> 1)) & 1;
                    v.lfsr = (v.lfsr >> 1) | (b << 14);
                }
                break :blk if (v.lfsr & 1 != 0) 1.0 else -1.0;
            },
            .triangle => blk: {
                const raw = if (v.ph < 0.25) v.ph * 4.0 else if (v.ph < 0.75) 2.0 - v.ph * 4.0 else v.ph * 4.0 - 4.0;
                v.lp += 0.22 * (raw - v.lp);
                break :blk v.lp;
            },
            .pulse => blk: { // polyBLEP bandlimited, DC blocked
                const dt = v.freq / rate;
                var raw: f64 = if (v.ph < v.duty) 1.0 else -1.0;
                raw += polyBlep(v.ph, dt);
                var t2 = v.ph + 1.0 - v.duty;
                if (t2 >= 1.0) t2 -= 1.0;
                raw -= polyBlep(t2, dt);
                v.lp += 0.5 * (raw - v.lp);
                const y = v.lp;
                const dc = y - v.dc_prev + 0.995 * v.dc;
                v.dc = dc;
                v.dc_prev = y;
                break :blk dc;
            },
        };
        if (v.fm) s += @sin(std.math.tau * v.mod_ph) * (v.fm_index * 0.75);
        const out = s * full_amp * v.level;

        // The envelope advances after the sample that used this level.
        if (v.seg_left > 0) v.seg_left -= 1;
        if (v.seg_left <= 0) {
            v.level = v.seg_end[v.segIndex()];
            v.nextSegment();
        } else {
            v.level += v.slope;
            if (v.seg == .sustain and v.freq_step != 0.0) v.freq += v.freq_step;
        }
        if (v.duty_left > 0) {
            v.duty_left -= 1;
            if (v.duty_left <= 0) {
                v.duty = v.duty_to;
                v.duty_step = 0;
            } else {
                v.duty += v.duty_step;
            }
        }
        if (v.fm) {
            v.mod_ph += v.freq * v.fm_ratio / rate;
            if (v.mod_ph >= 1.0) v.mod_ph -= @floor(v.mod_ph);
        }
        v.ph += v.freq / rate;
        if (v.ph >= 1.0) v.ph -= @floor(v.ph);
        return out;
    }
};

fn polyBlep(t_in: f64, dt: f64) f64 {
    if (t_in < dt) {
        const t = t_in / dt;
        return t + t - t * t - 1.0;
    } else if (t_in > 1.0 - dt) {
        const t = (t_in - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

/// Linear below the knee, tanh above, so stacked voices saturate gently.
fn softClip(x: f64) f64 {
    const knee = 24000.0;
    const top = 32767.0;
    if (x > knee) return knee + (top - knee) * std.math.tanh((x - knee) / (top - knee));
    if (x < -knee) return -knee + (top - knee) * std.math.tanh((x + knee) / (top - knee));
    return x;
}

pub const Synth = struct {
    rate: f64,
    voices: [channels]Voice = @splat(.{}),

    lock: std.atomic.Mutex = .unlocked,
    pending: [channels]?Trigger = @splat(null),
    reset_requested: bool = false,

    pub fn init(rate: u32) Synth {
        return .{ .rate = @floatFromInt(rate) };
    }

    fn acquire(s: *Synth) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Main thread: queue a tone() call.
    pub fn tone(s: *Synth, freq: i32, duration: i32, volume: i32, flags: i32) void {
        const ch, const t = Trigger.decode(freq, duration, volume, flags);
        s.acquire();
        defer s.lock.unlock();
        s.pending[ch] = t;
    }

    /// Main thread: silence everything and drop pending triggers (cart reload).
    pub fn clear(s: *Synth) void {
        s.acquire();
        defer s.lock.unlock();
        s.pending = @splat(null);
        s.reset_requested = true;
    }

    /// Audio thread: render interleaved stereo f32 frames.
    pub fn render(s: *Synth, out: []f32) void {
        var pending: [channels]?Trigger = undefined;
        var reset: bool = undefined;
        {
            s.acquire();
            defer s.lock.unlock();
            pending = s.pending;
            reset = s.reset_requested;
            s.pending = @splat(null);
            s.reset_requested = false;
        }
        if (reset) s.voices = @splat(.{});
        const spf = s.rate / 60.0;
        for (&s.voices, pending) |*v, p| if (p) |t| v.apply(&t, spf);

        var i: usize = 0;
        while (i + 1 < out.len) : (i += 2) {
            var l: f64 = 0;
            var r: f64 = 0;
            for (&s.voices) |*v| {
                if (v.seg == .idle) continue;
                const x = v.sample(s.rate);
                l += x * v.gl;
                r += x * v.gr;
            }
            out[i] = @floatCast(softClip(l) / 32768.0);
            out[i + 1] = @floatCast(softClip(r) / 32768.0);
        }
    }
};

test "decode packs match vex.h layouts" {
    // VEX_TONE_DURATION(attack=1, decay=2, sustain=3, release=4)
    const dur: i32 = 3 | 4 << 8 | 2 << 16 | 1 << 24;
    const ch, const t = Trigger.decode(440, dur, 50, 2 | (2 << 6) | (1 << 4));
    try std.testing.expectEqual(@as(u2, 2), ch);
    try std.testing.expectEqual(Wave.triangle, t.wave);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &t.frames);
    try std.testing.expectEqual(@as(f64, 1.0), t.gl);
    try std.testing.expectEqual(@as(f64, 0.5), t.sus);
    try std.testing.expectEqual(@as(f64, 1.0), t.peak);
}

test "a note sounds and then goes idle" {
    var s = Synth.init(48000);
    s.tone(440, 2 | 1 << 8, 100, 0); // 2 frames sustain, 1 frame release
    var buf: [2 * 800]f32 = undefined;
    s.render(&buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.05);
    // 32-sample attack pad + 2 frames sustain + 1 frame release < 4 renders.
    for (0..3) |_| s.render(&buf);
    try std.testing.expectEqual(Seg.idle, s.voices[0].seg);
}
