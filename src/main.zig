//! nex - a Zig host for vex carts.
//!
//!   usage: nex [-s scale] [-w] [-n frames] [-t] [--dump file] <cart.wasm>
//!
//!   -s, --scale N    initial window scale (1..20, default 3)
//!   -w, --watch      reload the cart whenever its file changes
//!   -n, --frames N   run N frames headless, then print a report
//!   -t, --trace      with -n, print a line per framebuffer change
//!   --dump FILE      with -n, write the raw RGBA framebuffer to FILE
//!
//! Window mode runs the cart at a fixed 60 ticks per second with keyboard,
//! gamepad, mouse and audio. Headless mode has no window and no audio and
//! reads every input as released, so runs are deterministic and report in the
//! same format as the C host's `-n` for pixel-parity diffs.
//!
//! Console keys (Super = Cmd on macOS, the Windows key elsewhere):
//!   Super+Enter  toggle fullscreen
//!   Super+I      toggle integer scaling (crisp pixels vs. fill)
//!   Super+R      reload the cart from disk
//!   Escape       quit

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("rl");
const gfx = @import("gfx.zig");
const Console = @import("Console.zig");
const Synth = @import("synth.zig").Synth;
const Cart = @import("cart.zig").Cart;

const W = gfx.W;
const H = gfx.H;
const tick_dt = 1.0 / 60.0;
const sample_rate = 48000;
const max_cart_size = 16 << 20;
const max_scale = 20;
/// Ticks between watch polls (0.5 s).
const watch_ticks = 30;
const Fnv = std.hash.Fnv1a_64;

// The console holds ~400 KiB of framebuffer and scratch: keep it off the stack.
var console: Console = .{};
var synth: Synth = .init(sample_rate);

const Options = struct {
    cart_path: []const u8,
    scale: i32 = 3,
    watch: bool = false,
    trace: bool = false,
    frames: ?u64 = null,
    dump_path: ?[]const u8 = null,
};

fn usage() void {
    std.debug.print("usage: nex [-s scale] [-w] [-n frames] [-t] [--dump file] <cart.wasm>\n", .{});
}

pub fn main(init: std.process.Init) !u8 {
    const opts = parseArgs(init) catch {
        usage();
        return 1;
    };
    const gpa = init.gpa;
    const io = init.io;

    const loaded = loadCartStable(gpa, io, opts.cart_path) catch return 1;
    var cart = loaded.cart;
    defer cart.deinit(gpa);

    console.reset();
    cart.boot() catch return 1;
    // Start every run from a known frame: palette 0 as boot() left it.
    console.gfx.prime();

    if (opts.frames) |n| return headless(io, &cart, opts, n);

    runWindow(gpa, io, &cart, opts, loaded.signature) catch return 1;
    return 0;
}

fn parseArgs(init: std.process.Init) !Options {
    var it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = it.next();
    var cart_path: ?[]const u8 = null;
    var opts: Options = .{ .cart_path = undefined };
    while (it.next()) |a| {
        if (eql(a, "-s") or eql(a, "--scale")) {
            const v = it.next() orelse "";
            const n = std.fmt.parseInt(i32, v, 10) catch {
                std.debug.print("nex: {s} requires an integer scale\n", .{a});
                return error.Usage;
            };
            opts.scale = std.math.clamp(n, 1, max_scale);
        } else if (eql(a, "-n") or eql(a, "--frames")) {
            const v = it.next() orelse "";
            opts.frames = std.fmt.parseInt(u64, v, 10) catch {
                std.debug.print("nex: {s} requires a frame count\n", .{a});
                return error.Usage;
            };
        } else if (eql(a, "-t") or eql(a, "--trace")) {
            opts.trace = true;
        } else if (eql(a, "-w") or eql(a, "--watch")) {
            opts.watch = true;
        } else if (eql(a, "--dump")) {
            opts.dump_path = it.next() orelse {
                std.debug.print("nex: {s} requires a file path\n", .{a});
                return error.Usage;
            };
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("nex: unknown option {s}\n", .{a});
            return error.Usage;
        } else if (cart_path == null) {
            cart_path = a;
        }
    }
    opts.cart_path = cart_path orelse return error.Usage;
    return opts;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- loading ----------------------------------------------------------------

fn readCart(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_cart_size));
}

/// FNV-1a of the file as it is on disk right now, so the watcher can tell a
/// finished write from a half-written one. 0 means unreadable.
fn fileSignature(gpa: std.mem.Allocator, io: std.Io, path: []const u8) u64 {
    const bytes = readCart(gpa, io, path) catch return 0;
    defer gpa.free(bytes);
    return Fnv.hash(bytes);
}

fn loadCart(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Cart {
    const wasm = readCart(gpa, io, path) catch |err| {
        std.debug.print("nex: cannot read {s}: {t}\n", .{ path, err });
        return err;
    };
    errdefer gpa.free(wasm);
    return Cart.load(wasm, &console);
}

const Loaded = struct { cart: Cart, signature: u64 };

/// Load, then prove the bytes booted are the bytes on disk. Retries only when
/// the file changed underneath (an editor or cart build caught mid-write); a
/// cart that genuinely fails to load fails on the first try.
fn loadCartStable(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    for (0..3) |_| {
        var cart = try loadCart(gpa, io, path);
        const sig = cart.signature();
        if (sig != 0 and sig == fileSignature(gpa, io, path)) return .{ .cart = cart, .signature = sig };
        cart.deinit(gpa);
    }
    return error.CartUnstable;
}

/// Reload the cart into a fresh runtime and swap it in only if it loads and
/// boots cleanly; otherwise every host state the candidate touched is put
/// back and the running cart carries on. Returns true if the cart was replaced.
fn reload(gpa: std.mem.Allocator, io: std.Io, cart: *Cart, path: []const u8, signature: *u64) bool {
    const S = struct {
        var previous: Console.Snapshot = undefined;
    };
    console.snapshot(&S.previous);

    // The candidate's tone() calls stay silent until it is swapped in, so a
    // rejected reload can't leave a half-started voice behind.
    const live_synth = console.synth;
    console.synth = null;
    defer console.synth = live_synth;

    const loaded = loadCartStable(gpa, io, path) catch {
        console.restore(&S.previous);
        return false;
    };
    var fresh = loaded.cart;

    console.gfx.palreset();
    console.gfx.prime();
    console.setTitle(Console.default_title);
    console.input.prev = 0;
    console.input.pressed = 0;

    fresh.boot() catch {
        fresh.deinit(gpa);
        console.restore(&S.previous);
        return false;
    };
    console.input.prev = console.input.held;
    console.input.pressed = 0;

    // A rewrite during boot() means the cart is stale before it was shown.
    if (loaded.signature != fileSignature(gpa, io, path)) {
        fresh.deinit(gpa);
        console.restore(&S.previous);
        return false;
    }

    if (live_synth) |s| s.clear();
    cart.deinit(gpa);
    cart.* = fresh;
    signature.* = loaded.signature;
    return true;
}

// ---- headless ---------------------------------------------------------------

fn headless(io: std.Io, cart: *Cart, opts: Options, frames: u64) !u8 {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    const t0 = std.Io.Timestamp.now(io, .awake);
    var prev = Fnv.hash(console.gfx.bytes());
    var changes: u64 = 0;
    for (0..frames) |i| {
        cart.update() catch {
            out.flush() catch {};
            return 1;
        };
        const h = Fnv.hash(console.gfx.bytes());
        if (h != prev) {
            changes += 1;
            if (opts.trace) try out.print("frame {d} fb={x:0>16}\n", .{ i, h });
            prev = h;
        }
    }
    const ns: f64 = @floatFromInt(t0.untilNow(io, .awake).toNanoseconds());
    const ms = ns / 1e6;

    try out.print("cart={s} frames={d} total-ms={d:.2} ms/frame={d:.3}\n", .{
        opts.cart_path, frames, ms, if (frames > 0) ms / @as(f64, @floatFromInt(frames)) else ms,
    });
    try out.print("fb-changes={d} fnv1a64={x:0>16} mem={d}\n", .{ changes, prev, cart.memorySize() });
    for (console.gfx.palette, 0..) |p, i| {
        try out.print("palette[{X}]={X:0>2}{X:0>2}{X:0>2}\n", .{ i, p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF });
    }
    try out.flush();

    if (opts.dump_path) |path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = console.gfx.bytes() }) catch {
            std.debug.print("nex: cannot write {s}\n", .{path});
            return 1;
        };
    }
    return 0;
}

// ---- audio ------------------------------------------------------------------

/// raylib attenuates a centered stream; undo it so levels match the other hosts.
const raylib_center_gain_inv = 16.0 / 11.0;

fn audioCallback(buffer: ?*anyopaque, frames: c_uint) callconv(.c) void {
    const out: [*]f32 = @ptrCast(@alignCast(buffer orelse return));
    synth.render(out[0 .. @as(usize, frames) * 2]);
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
    /// over the viewport in present().
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

    fn present(v: View, screen: rl.Texture2D) void {
        const src: rl.Rectangle = .{ .x = 0, .y = 0, .width = W, .height = H };
        const dw = W * v.scale;
        const dh = H * v.scale;
        rl.BeginDrawing();
        defer rl.EndDrawing();
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

fn applyTitle() void {
    rl.SetWindowTitle(console.title().ptr);
    console.title_dirty = false;
}

fn superDown() bool {
    return rl.IsKeyDown(rl.KEY_LEFT_SUPER) or rl.IsKeyDown(rl.KEY_RIGHT_SUPER);
}

fn runWindow(gpa: std.mem.Allocator, io: std.Io, cart: *Cart, opts: Options, initial_signature: u64) !void {
    // Errors only: raylib's INFO chatter is noise during normal play.
    rl.SetTraceLogLevel(rl.LOG_ERROR);
    // Windows only enables the maximize button on resizable windows.
    if (builtin.os.tag == .windows) rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(W * opts.scale, H * opts.scale, console.title().ptr);
    defer rl.CloseWindow();
    console.title_dirty = false;
    rl.SetTargetFPS(60);

    var screen = try makeScreen();
    defer rl.UnloadTexture(screen);

    var audio: Audio = .init();
    defer audio.deinit();
    if (audio.ready) console.synth = &synth;
    defer console.synth = null;

    var integer_scale = false; // switched on automatically in fullscreen
    var was_maximized = false;
    var signature = initial_signature;
    var poll: u32 = 0;
    var reload_pressed = false;

    // Fixed 60 TPS from the wall clock, not one tick per frame, so 120/144 Hz
    // displays don't run carts fast.
    var acc: f64 = 0;
    var prev_time = rl.GetTime();

    while (!rl.WindowShouldClose()) {
        if (latchKeyPresses()) reload_pressed = true;

        const now = rl.GetTime();
        var dt = now - prev_time;
        prev_time = now;
        if (dt > 0.25) dt = 0; // hidden/minimized: don't fast-forward
        acc = @min(acc + dt, 5 * tick_dt); // slow frames: no catch-up burst

        const super = superDown();
        // Latched per frame: IsKeyPressed lasts one frame, and a 144 Hz frame
        // often runs zero ticks. Consumed by the next tick.
        reload_pressed = reload_pressed or (super and rl.IsKeyPressed(rl.KEY_R));

        if (super and rl.IsKeyPressed(rl.KEY_ENTER)) {
            if (!rl.IsWindowFullscreen()) {
                enterFullscreen();
                integer_scale = true; // crisp by default in fullscreen
            } else {
                rl.ToggleFullscreen();
                rl.SetWindowSize(W * opts.scale, H * opts.scale);
            }
            screen = try rebuildScreen(screen);
        }
        if (super and rl.IsKeyPressed(rl.KEY_I)) integer_scale = !integer_scale;

        // Windows: the maximize button means fullscreen.
        if (builtin.os.tag == .windows) {
            const is_maximized = rl.IsWindowMaximized();
            if (is_maximized != was_maximized) {
                was_maximized = is_maximized;
                if (is_maximized and !rl.IsWindowFullscreen()) {
                    enterFullscreen();
                    integer_scale = true;
                    screen = try rebuildScreen(screen);
                }
            }
        }

        const view = View.fit(integer_scale);
        pollInput(view);

        // Fixed-rate cart ticks: 0, 1 or a few catch-up ticks per frame.
        // Reload checks run at tick rate so -w polls every 0.5 s at any Hz.
        var ticked = false;
        while (acc >= tick_dt) : (acc -= tick_dt) {
            var want_reload = reload_pressed;
            reload_pressed = false;
            if (opts.watch) {
                poll += 1;
                if (poll >= watch_ticks) {
                    poll = 0;
                    const sig = fileSignature(gpa, io, opts.cart_path);
                    if (sig != 0 and sig != signature) want_reload = true;
                }
            }
            if (want_reload) _ = reload(gpa, io, cart, opts.cart_path, &signature);

            cart.update() catch return error.CartTrap;
            console.input.endTick();
            if (console.tone_used) audio.ensureStream();
            ticked = true;
        }
        if (ticked) rl.UpdateTexture(screen, &console.gfx.fb);
        if (console.title_dirty) applyTitle();

        view.present(screen);
    }
}

// ---- input ------------------------------------------------------------------

const keys = [6]c_int{ rl.KEY_LEFT, rl.KEY_RIGHT, rl.KEY_UP, rl.KEY_DOWN, rl.KEY_Z, rl.KEY_X };

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
fn latchKeyPresses() bool {
    var reload_req = false;
    while (true) {
        const key = rl.GetKeyPressed();
        if (key == 0) break;
        if (key == rl.KEY_R and superDown()) reload_req = true;
        for (keys, 0..) |k, i| if (key == k) {
            console.input.pressed |= @as(u8, 1) << @intCast(i);
        };
    }
    for (0..keys.len) |i| {
        if (padButton(i, true)) console.input.pressed |= @as(u8, 1) << @intCast(i);
    }
    return reload_req;
}

fn pollInput(view: View) void {
    const in = &console.input;
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
