const std = @import("std");

/// raylib's Linux display backend (mapped to GLFW's _GLFW_X11/_GLFW_WAYLAND).
pub const LinuxDisplayBackend = enum { X11, Wayland, Both };

// nex - Zig host for vex carts.
//
//   zig build            build ./zig-out/bin/nex and the example carts
//   zig build run        run the Zig example cart
//   zig build run-c      run the C example cart
//   zig build test       unit tests (gfx, synth, input, wasm bindings)
//   zig build carts      just the example carts (zig-out/bin/*.wasm)
//
// nex builds as release (fast) by default, since it is an end-user binary.
// Pass -Doptimize=debug for a debug build, or --release=safe / --release=small
// (or -Doptimize=safe / small) for the other release modes. Unit tests stay
// in debug, keeping Zig's safety checks, unless -Doptimize or --release says
// otherwise.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Not standardOptimizeOption: it falls back to debug when --release is
    // absent, and with a preferred mode it ignores the requested one.
    const requested = b.option(
        std.builtin.Optimize,
        "optimize",
        "Optimization mode (default: fast; tests: debug)",
    );
    const release: ?std.builtin.Optimize = switch (b.graph.release_mode) {
        .off => null,
        .any, .fast => .fast,
        .safe => .safe,
        .small => .small,
    };
    const optimize: std.builtin.Optimize = requested orelse release orelse .fast;
    const test_optimize: std.builtin.Optimize = requested orelse release orelse .debug;

    const linux_display_backend = b.option(
        LinuxDisplayBackend,
        "linux_display_backend",
        "raylib Linux display backend: X11 (default), Wayland, Both",
    ) orelse .X11;

    // ---- example carts (no host dependencies) -----------------------------
    const carts_step = b.step("carts", "Build the example carts");
    const zig_cart = addZigCart(b, "hello", "examples/hello.zig");
    const c_cart = addCCart(b, "hello_c", "examples/hello.c");
    for ([_]*std.Build.Step.Compile{ zig_cart, c_cart }) |cart| {
        const install = b.addInstallArtifact(cart, .{});
        carts_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // ---- host -------------------------------------------------------------
    const raylib_dep = b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
    }) orelse return; // not fetched yet: zig fetches lazy deps and reruns
    // Pass the mode down: wasm3's build.zig reads it with
    // standardOptimizeOption(.{}), which aborts on a bare --release.
    const wasm3_dep = b.lazyDependency("wasm3", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const rl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/raylib_c.h"),
        .target = target,
        .optimize = optimize,
    });
    rl_c.addIncludePath(raylib_dep.path("src"));
    const m3_c = b.addTranslateC(.{
        .root_source_file = wasm3_dep.path("source/wasm3.h"),
        .target = target,
        .optimize = optimize,
    });
    m3_c.addIncludePath(wasm3_dep.path("source"));

    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "rl", .module = rl_c.createModule() },
            .{ .name = "m3", .module = m3_c.createModule() },
        },
    });
    addWasm3(host_mod, wasm3_dep);
    addRaylib(host_mod, raylib_dep, linux_display_backend);

    const exe = b.addExecutable(.{ .name = "nex", .root_module = host_mod });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addArtifactArg(zig_cart);
    run.addPassthruArgs();
    b.step("run", "Run the Zig example cart").dependOn(&run.step);

    const run_c = b.addRunArtifact(exe);
    run_c.addArtifactArg(c_cart);
    run_c.addPassthruArgs();
    b.step("run-c", "Run the C example cart").dependOn(&run_c.step);

    // ---- tests ------------------------------------------------------------
    // The core files don't touch raylib, so tests never compile it. cart.zig
    // needs wasm3 for its bindings.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/gfx.zig", "src/input.zig", "src/synth.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = test_optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    const cart_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cart.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "m3", .module = m3_c.createModule() }},
    }) });
    addWasm3(cart_tests.root_module, wasm3_dep);
    test_step.dependOn(&b.addRunArtifact(cart_tests).step);
}

fn wasmTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
}

fn addZigCart(b: *std.Build, name: []const u8, path: []const u8) *std.Build.Step.Compile {
    const wasm = wasmTarget(b);
    const cart = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = wasm,
            .optimize = .small,
            .imports = &.{.{
                .name = "vex",
                .module = b.createModule(.{ .root_source_file = b.path("vex.zig") }),
            }},
        }),
    });
    cart.entry = .disabled;
    cart.rdynamic = true;
    return cart;
}

fn addCCart(b: *std.Build, name: []const u8, path: []const u8) *std.Build.Step.Compile {
    const cart = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = wasmTarget(b),
            .optimize = .small,
        }),
    });
    cart.root_module.addCSourceFile(.{ .file = b.path(path), .flags = &.{"-std=c11"} });
    cart.root_module.addIncludePath(b.path("."));
    cart.entry = .disabled;
    return cart;
}

/// wasm3 core interpreter only; the m3_api_* modules (WASI, libc, tracer)
/// are skipped since the console supplies its own imports.
fn addWasm3(mod: *std.Build.Module, dep: *std.Build.Dependency) void {
    mod.addIncludePath(dep.path("source"));
    mod.addCSourceFiles(.{
        .root = dep.path("source"),
        .files = &.{
            "m3_bind.c",     "m3_code.c", "m3_compile.c", "m3_core.c",
            "m3_env.c",      "m3_exec.c", "m3_function.c", "m3_info.c",
            "m3_module.c",   "m3_parse.c", "m3_validate.c",
        },
        // 64-bit slots keep i64 constant stores aligned; with the default
        // 32-bit slots UBSan traps on the first cart with an i64 const.
        .flags = &.{ "-Dd_m3Use32BitSlots=0", "-fwrapv" },
    });
}

/// Compile raylib (desktop GLFW backend) straight into the module and link
/// the platform libraries, rather than linking the dependency's archive.
fn addRaylib(mod: *std.Build.Module, dep: *std.Build.Dependency, backend: LinuxDisplayBackend) void {
    const os = mod.resolved_target.?.result.os.tag;

    mod.addIncludePath(dep.path("src"));
    mod.addIncludePath(dep.path("src/platforms"));
    mod.addIncludePath(dep.path("src/external/glfw/include"));

    mod.addCMacro("_GNU_SOURCE", "");
    mod.addCMacro("GL_SILENCE_DEPRECATION", "199309L");
    mod.addCMacro("PLATFORM_DESKTOP_GLFW", "");
    mod.addCMacro("GRAPHICS_API_OPENGL_33", "");

    switch (os) {
        .linux => {
            mod.linkSystemLibrary("GL", .{});
            if (backend != .Wayland) {
                mod.addCMacro("_GLFW_X11", "");
                inline for (.{ "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" }) |lib|
                    mod.linkSystemLibrary(lib, .{});
            }
            if (backend != .X11) {
                mod.addCMacro("_GLFW_WAYLAND", "");
                inline for (.{ "wayland-client", "wayland-cursor", "wayland-egl", "xkbcommon" }) |lib|
                    mod.linkSystemLibrary(lib, .{});
            }
        },
        .windows => inline for (.{ "opengl32", "winmm", "gdi32" }) |lib| mod.linkSystemLibrary(lib, .{}),
        .macos => inline for (.{ "Foundation", "CoreServices", "CoreGraphics", "AppKit", "IOKit", "QuartzCore" }) |fw|
            mod.linkFramework(fw, .{}),
        else => @panic("nex: unsupported target OS for raylib"),
    }

    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{ "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rmodels.c", "raudio.c" },
        .flags = &.{"-std=c99"},
    });
    // rglfw.c pulls in Objective-C on macOS.
    mod.addCSourceFile(.{
        .file = dep.path("src/rglfw.c"),
        .flags = if (os == .macos) &.{ "-std=c99", "-ObjC" } else &.{"-std=c99"},
    });
}
