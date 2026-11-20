//! nex - a Zig host for vex carts.
//!
//!   usage: nex [-s scale] [-w] [-n frames] [-t] [--dump file] <cart.wasm>
//!   (the terminal build installs the same program as `kex`)
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
//! Console keys in the desktop backend (Super = Cmd on macOS, Windows elsewhere):
//!   Super+Enter  toggle fullscreen
//!   Super+I      toggle integer scaling (crisp pixels vs. fill)
//!   Super+R      reload the cart from disk
//!   Escape       quit
//!
//! The kitty backend (zig build -Dbackend=kitty) has no window or audio:
//! Ctrl+R reloads, Escape quits, and the six cart buttons are arrow keys,
//! Z and X.
//!
//! Platform code lives in src/backends; the cart-facing modules stay
//! platform-independent.

const std = @import("std");
const gfx = @import("gfx.zig");
const Console = @import("Console.zig");
const Synth = @import("synth.zig").Synth;
const Cart = @import("cart.zig").Cart;
const build_options = @import("build_options");
const Backend = if (std.mem.eql(u8, build_options.backend, "kitty"))
    @import("backends/kitty.zig").Backend
else
    @import("backends/raylib.zig").Backend;

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
    std.debug.print("usage: {s} [-s scale] [-w] [-n frames] [-t] [--dump file] <cart.wasm>\n", .{if (std.mem.eql(u8, build_options.backend, "kitty")) "kex" else "nex"});
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

    runWindow(gpa, io, init.minimal.environ, &cart, opts, loaded.signature) catch return 1;
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

// ---- platform loop ----------------------------------------------------------

fn runWindow(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, cart: *Cart, opts: Options, initial_signature: u64) !void {
    var backend = try Backend.init(.{
        .console = &console,
        .synth = &synth,
        .io = io,
        .gpa = gpa,
        .environ = environ,
        .scale = opts.scale,
    });
    defer backend.deinit();

    var signature = initial_signature;
    var poll: u32 = 0;
    var reload_pressed = false;
    var due: u32 = 1; // cart ticks to run on the first frame

    while (true) {
        const frame = try backend.beginFrame();
        if (frame.quit) break;
        if (frame.reload) reload_pressed = true;

        // One cart tick per frame, plus catch-up ticks if the loop fell behind.
        // Reload checks run at tick rate so -w polls every 0.5 s.
        for (0..due) |_| {
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
            if (console.tone_used) backend.tone();
        }
        due = backend.present();
    }
}
