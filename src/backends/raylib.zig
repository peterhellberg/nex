//! Desktop backend: raylib window, texture upload, input, audio and pacing.
//!
//! Everything in here was formerly in main.zig; the main loop talks to it
//! through backend.Config / backend.Frame only.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("rl");
const backend = @import("../backend.zig");
const gfx = @import("../gfx.zig");

const W = gfx.W;
const H = gfx.H;
const tick_dt = 1.0 / 60.0;
const sample_rate = 48000;

// ---- audio ------------------------------------------------------------------

/// raylib attenuates a centered stream; undo it so levels match the other hosts.
const raylib_center_gain_inv = 16.0 / 11.0;

fn audioCallback(buffer: ?*anyopaque, frames: c_uint) callconv(.c) void {
    const out: [*]f32 = @ptrCast(@alignCast(buffer orelse return));
    renderAudio(out[0 .. @as(usize, frames) * 2]);
}

/// Set by Backend.init() to the synth the host owns.
var audio_synth: *@import("../synth.zig").Synth = undefined;

fn renderAudio(out: []f32) void {
    audio_synth.render(out);
}

const Audio = struct {
    ready: bool,
    playing: bool = false,
    stream: rl.AudioStream = undefined,

    /// Safe without an audio device (CI, headless boxes): tone() stays silent.
    fn init() Audio {
        rl.InitAudioDevice();
        return .{ .ready = rl.IsAudioDeviceReady() };
    }

    /// Open the stream on the first audible tone().
    fn ensureStream(a: *Audio) void {
        if (a.playing or !a.ready) return;
        a.stream = rl.LoadAudioStream(sample_rate, 32, 2);
        rl.SetAudioStreamVolume(a.stream, raylib_center_gain_inv);
        rl.SetAudioStreamCallback(a.stream, audioCallback);
        rl.PlayAudioStream(a.stream);
        a.playing = true;
    }

    fn deinit(a: *Audio) void {
        if (a.playing) rl.UnloadAudioStream(a.stream);
        if (a.ready) rl.CloseAudioDevice();
        a.* = .{ .ready = false };
    }
};

// ---- window -----------------------------------------------------------------

/// Framebuffer -> surface mapping for one frame, in logical points.
const View = struct {
    scale: f32,
    ox: f32,
    oy: f32,
    sw: f32,
    sh: f32,
    /// See fit(): the GL viewport must be driven directly this frame.
    surface_mismatch: bool,

    /// Fit the screen into the visible surface, preserving aspect ratio and
    /// centering. Normally the surface is the render size over the DPI scale
    /// (GetScreenWidth/Height go stale when toggling fullscreen on macOS).
    ///
    /// On scaled HiDPI displays raylib's render size can disagree with the
    /// real GL surface in fullscreen (a 4K monitor in a 1920x1080 "looks
    /// like" mode reports render=3840 while drawing onto 1920x1080), which
    /// would put the picture in a corner. When, and only when, the monitor
    /// size disagrees with the render size, map against the monitor and take
    /// over the viewport in draw().
    fn fit(integer: bool) View {
        const mon = rl.GetCurrentMonitor();
        const mismatch = rl.IsWindowFullscreen() and
            (rl.GetMonitorWidth(mon) != rl.GetRenderWidth() or rl.GetMonitorHeight(mon) != rl.GetRenderHeight());
        var sw: f32 = undefined;
        var sh: f32 = undefined;
        if (mismatch) {
            sw = @floatFromInt(rl.GetMonitorWidth(mon));
            sh = @floatFromInt(rl.GetMonitorHeight(mon));
        } else {
            const dpi = rl.GetWindowScaleDPI();
            sw = @as(f32, @floatFromInt(rl.GetRenderWidth())) / dpi.x;
            sh = @as(f32, @floatFromInt(rl.GetRenderHeight())) / dpi.y;
        }
        // raylib can briefly report 0 if a monitor is unplugged mid-toggle.
        sw = @max(sw, 1);
        sh = @max(sh, 1);
        var s = @min(sw / W, sh / H);
        if (integer) s = @max(@floor(s), 1);
        return .{
            .scale = s,
            .ox = (sw - W * s) / 2,
            .oy = (sh - H * s) / 2,
            .sw = sw,
            .sh = sh,
            .surface_mismatch = mismatch,
        };
    }

    fn mouseAxis(v: View, comptime x_axis: bool) i32 {
        const pos: f32 = @floatFromInt(if (x_axis) rl.GetMouseX() else rl.GetMouseY());
        const o = if (x_axis) v.ox else v.oy;
        const lim: i32 = if (x_axis) W else H;
        // Clamp in float space first so @intFromFloat can't overflow.
        const p: i32 = @intFromFloat(std.math.clamp((pos - o) / v.scale, -1, @as(f32, @floatFromInt(lim))));
        return std.math.clamp(p, 0, lim - 1);
    }

    /// Begin the frame and draw it; the caller ends it with rl.EndDrawing().
    fn draw(v: View, screen: rl.Texture2D) void {
        const src: rl.Rectangle = .{ .x = 0, .y = 0, .width = W, .height = H };
        const dw = W * v.scale;
        const dh = H * v.scale;
        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        if (!v.surface_mismatch) {
            rl.DrawTexturePro(screen, src, .{ .x = v.ox, .y = v.oy, .width = dw, .height = dh }, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
            return;
        }
        // raylib's auto viewport tracks its (wrong) render size, so set the
        // viewport to the letterboxed destination in real surface pixels and
        // draw 1:1 into it. GL's viewport origin is bottom-left.
        rl.rlDrawRenderBatchActive();
        rl.rlViewport(@intFromFloat(v.ox), @intFromFloat(v.sh - dh - v.oy), @intFromFloat(dw), @intFromFloat(dh));
        rl.rlMatrixMode(rl.RL_PROJECTION);
        rl.rlPushMatrix();
        rl.rlLoadIdentity();
        rl.rlOrtho(0, W, H, 0, -1, 1);
        rl.rlMatrixMode(rl.RL_MODELVIEW);
        rl.rlLoadIdentity();
        rl.DrawTexturePro(screen, src, src, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
        rl.rlDrawRenderBatchActive();
        rl.rlMatrixMode(rl.RL_PROJECTION);
        rl.rlPopMatrix();
        rl.rlMatrixMode(rl.RL_MODELVIEW);
        rl.rlLoadIdentity();
        rl.rlViewport(0, 0, @intFromFloat(v.sw), @intFromFloat(v.sh));
    }
};

fn makeScreen() !rl.Texture2D {
    const img = rl.GenImageColor(W, H, rl.BLANK);
    defer rl.UnloadImage(img);
    const t = rl.LoadTextureFromImage(img);
    if (t.id == 0) {
        std.debug.print("nex: cannot create framebuffer texture\n", .{});
        return error.Texture;
    }
    rl.SetTextureFilter(t, rl.TEXTURE_FILTER_POINT);
    return t;
}

/// Anything that can recreate the GL context underneath us (a macOS
/// fullscreen Space, a Windows maximize) must rebuild the texture here.
fn rebuildScreen(old: rl.Texture2D) !rl.Texture2D {
    rl.UnloadTexture(old);
    return makeScreen();
}

/// Size the window to the monitor and enter true fullscreen (which fits the
/// display exactly and hides the menu bar on notched screens).
fn enterFullscreen() void {
    const mon = rl.GetCurrentMonitor();
    rl.SetWindowSize(rl.GetMonitorWidth(mon), rl.GetMonitorHeight(mon));
    rl.ToggleFullscreen();
}

/// Paces the window loop at exactly 60 frames per second, one cart tick each.
///
/// A relative limiter (raylib's SetTargetFPS) sleeps a frame's worth after
/// each frame, and its oversleep accumulates: frames averaged ~16.84 ms on a
/// 120 Hz Mac, so every ~100 frames the cart clock had to run two ticks in
/// one frame and the picture visibly hitched. Vsync can't pace instead: on
/// macOS it is not reliably honored (frames came back 0.5-19 ms apart).
///
/// Pacer keeps absolute deadlines, so oversleep never accumulates, and a late
/// frame is absorbed by the next deadline rather than doubled up. Measured on
/// the same Mac: 600 of 600 frames ran one tick, swaps 16.667 ms apart
/// (sd 0.21 ms).
const Pacer = struct {
    next: f64,

    /// Behind by more than this many ticks (a hidden window, a debugger
    /// stop): resynchronize instead of bursting through the backlog.
    const max_catch_up = 4;

    fn init() Pacer {
        return .{ .next = rl.GetTime() + tick_dt };
    }

    /// Wait for the current deadline, then return how many cart ticks are
    /// due next frame: 1 normally, more if the loop has fallen behind.
    fn wait(p: *Pacer) u32 {
        // WaitTime sleeps most of the way and busy-waits the last 5%, which
        // lands within ~0.6 ms of the deadline without spinning a core.
        rl.WaitTime(p.next - rl.GetTime());

        p.next += tick_dt;
        const behind = rl.GetTime() - p.next;
        if (behind < 0) return 1;
        if (behind > max_catch_up * tick_dt) {
            p.next = rl.GetTime() + tick_dt;
            return 1;
        }
        const extra: u32 = @intFromFloat(@floor(behind / tick_dt) + 1);
        p.next += @as(f64, @floatFromInt(extra)) * tick_dt;
        return 1 + extra;
    }
};

// ---- input ------------------------------------------------------------------

const keys = [6]c_int{ rl.KEY_LEFT, rl.KEY_RIGHT, rl.KEY_UP, rl.KEY_DOWN, rl.KEY_Z, rl.KEY_X };

// raylib 6.2's bundled GLFW mapping database has no entry for the 8BitDo
// Ultimate 2C Wireless (VID 2dc8 / PID 301b), so over Bluetooth it connects
// as a gamepad but reports no buttons or stick movement. Load the known-good
// SDL mapping at startup; SetGamepadMappings() is additive, so other pads keep
// their built-in mappings.
const extra_gamepad_mappings =
    "03000000c82d00001b30000001000000,8BitDo Ultimate 2C," ++
    "a:b0,b:b1,back:b10,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1," ++
    "guide:b12,leftshoulder:b6,leftstick:b13,lefttrigger:a5,leftx:a0,lefty:a1," ++
    "paddle1:b5,paddle2:b2,rightshoulder:b7,rightstick:b14,righttrigger:a4," ++
    "rightx:a2,righty:a3,start:b11,x:b3,y:b4,platform:Mac OS X,";

// GLFW remaps every pad to the Xbox layout: the d-pad maps onto the arrows,
// Z/X onto the bottom/right face buttons (A/B), with LB/RB as alternates.
// GAMEPAD_BUTTON_UNKNOWN pads single bindings: no pad ever reports it.
const max_gamepads = 4; // raylib's own cap
const pad_buttons = [6][2]c_int{
    .{ rl.GAMEPAD_BUTTON_LEFT_FACE_LEFT, rl.GAMEPAD_BUTTON_UNKNOWN },
    .{ rl.GAMEPAD_BUTTON_LEFT_FACE_RIGHT, rl.GAMEPAD_BUTTON_UNKNOWN },
    .{ rl.GAMEPAD_BUTTON_LEFT_FACE_UP, rl.GAMEPAD_BUTTON_UNKNOWN },
    .{ rl.GAMEPAD_BUTTON_LEFT_FACE_DOWN, rl.GAMEPAD_BUTTON_UNKNOWN },
    .{ rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN, rl.GAMEPAD_BUTTON_LEFT_TRIGGER_1 },
    .{ rl.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT, rl.GAMEPAD_BUTTON_RIGHT_TRIGGER_1 },
};
/// Cardinal-snap point: deliberate flicks register, resting drift doesn't.
const stick_deadzone = 0.3;

/// Left stick pushed in direction `dir` (0 left, 1 right, 2 up, 3 down) on
/// any pad. Up is negative Y, as in GLFW.
fn stickHeld(dir: usize) bool {
    for (0..max_gamepads) |g| {
        const x = rl.GetGamepadAxisMovement(@intCast(g), rl.GAMEPAD_AXIS_LEFT_X);
        const y = rl.GetGamepadAxisMovement(@intCast(g), rl.GAMEPAD_AXIS_LEFT_Y);
        switch (dir) {
            0 => if (x < -stick_deadzone) return true,
            1 => if (x > stick_deadzone) return true,
            2 => if (y < -stick_deadzone) return true,
            3 => if (y > stick_deadzone) return true,
            else => {},
        }
    }
    return false;
}

fn padButton(i: usize, comptime edge: bool) bool {
    for (0..max_gamepads) |g| for (pad_buttons[i]) |b| {
        const hit = if (edge) rl.IsGamepadButtonPressed(@intCast(g), b) else rl.IsGamepadButtonDown(@intCast(g), b);
        if (hit) return true;
    };
    return false;
}

/// Drain raylib's key queue into latched cart presses. Returns true when
/// Super+R was pressed (reload).
fn latchKeyPresses(c: *@import("../Console.zig")) bool {
    var reload_req = false;
    while (true) {
        const key = rl.GetKeyPressed();
        if (key == 0) break;
        if (key == rl.KEY_R and superDown()) reload_req = true;
        for (keys, 0..) |k, i| if (key == k) {
            c.input.pressed |= @as(u8, 1) << @intCast(i);
        };
    }
    for (0..keys.len) |i| {
        if (padButton(i, true)) c.input.pressed |= @as(u8, 1) << @intCast(i);
    }
    return reload_req;
}

fn pollInput(c: *@import("../Console.zig"), view: View) void {
    const in = &c.input;
    var held: u8 = 0;
    for (0..keys.len) |i| {
        if (rl.IsKeyDown(keys[i]) or (i < 4 and stickHeld(i)) or padButton(i, false))
            held |= @as(u8, 1) << @intCast(i);
    }
    in.held = held;

    in.mouse_x = view.mouseAxis(true);
    in.mouse_y = view.mouseAxis(false);
    var mouse: u8 = 0;
    for (0..3) |b| { // raylib only defines buttons 0..2
        if (rl.IsMouseButtonDown(@intCast(b))) mouse |= @as(u8, 1) << @intCast(b);
    }
    in.mouse = mouse;
}

fn superDown() bool {
    return rl.IsKeyDown(rl.KEY_LEFT_SUPER) or rl.IsKeyDown(rl.KEY_RIGHT_SUPER);
}

// ---- backend ----------------------------------------------------------------

pub const Backend = struct {
    cfg: backend.Config,
    screen: rl.Texture2D,
    audio: Audio,
    pacer: Pacer,
    view: View = undefined,
    integer_scale: bool = false,
    was_maximized: bool = false,

    pub fn init(cfg: backend.Config) !Backend {
        // Errors only: raylib's INFO chatter is noise during normal play.
        rl.SetTraceLogLevel(rl.LOG_ERROR);
        // Windows only enables the maximize button on resizable windows.
        if (builtin.os.tag == .windows) rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
        rl.InitWindow(W * cfg.scale, H * cfg.scale, cfg.console.title().ptr);
        errdefer rl.CloseWindow();
        _ = rl.SetGamepadMappings(extra_gamepad_mappings);
        // No raylib frame limiter: Pacer presents on an absolute 60 Hz schedule.
        rl.SetTargetFPS(0);

        const screen = try makeScreen();
        errdefer rl.UnloadTexture(screen);
        var audio: Audio = .init();
        errdefer audio.deinit();
        if (audio.ready) cfg.console.synth = cfg.synth;
        audio_synth = cfg.synth;
        cfg.console.title_dirty = false;

        return .{
            .cfg = cfg,
            .screen = screen,
            .audio = audio,
            .pacer = Pacer.init(),
        };
    }

    pub fn deinit(b: *Backend) void {
        b.cfg.console.synth = null;
        b.audio.deinit();
        rl.UnloadTexture(b.screen);
        rl.CloseWindow();
    }

    /// Poll platform input, apply window hotkeys and compute this frame's view.
    pub fn beginFrame(b: *Backend) !backend.Frame {
        if (rl.WindowShouldClose()) return .{ .quit = true };
        var frame: backend.Frame = .{};
        if (latchKeyPresses(b.cfg.console)) frame.reload = true;

        const super = superDown();
        frame.reload = frame.reload or (super and rl.IsKeyPressed(rl.KEY_R));

        if (super and rl.IsKeyPressed(rl.KEY_ENTER)) {
            if (!rl.IsWindowFullscreen()) {
                enterFullscreen();
                b.integer_scale = true; // crisp by default in fullscreen
            } else {
                rl.ToggleFullscreen();
                rl.SetWindowSize(W * b.cfg.scale, H * b.cfg.scale);
            }
            b.screen = try rebuildScreen(b.screen);
        }
        if (super and rl.IsKeyPressed(rl.KEY_I)) b.integer_scale = !b.integer_scale;

        // Windows: the maximize button means fullscreen.
        if (builtin.os.tag == .windows) {
            const is_maximized = rl.IsWindowMaximized();
            if (is_maximized != b.was_maximized) {
                b.was_maximized = is_maximized;
                if (is_maximized and !rl.IsWindowFullscreen()) {
                    enterFullscreen();
                    b.integer_scale = true;
                    b.screen = try rebuildScreen(b.screen);
                }
            }
        }

        b.view = View.fit(b.integer_scale);
        pollInput(b.cfg.console, b.view);
        return frame;
    }

    /// Upload the framebuffer, draw, pace, and swap. Returns cart ticks due
    /// on the next frame.
    pub fn present(b: *Backend) u32 {
        rl.UpdateTexture(b.screen, &b.cfg.console.gfx.fb);
        if (b.cfg.console.title_dirty) {
            rl.SetWindowTitle(b.cfg.console.title().ptr);
            b.cfg.console.title_dirty = false;
        }
        b.view.draw(b.screen);
        const due = b.pacer.wait();
        rl.EndDrawing();
        return due;
    }

    pub fn tone(b: *Backend) void {
        b.audio.ensureStream();
    }
};
