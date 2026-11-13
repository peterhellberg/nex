//! Loads a .wasm cart into wasm3 and links the `env` imports from vex.h /
//! vex.zig against a Console.
//!
//! Imports are plain Zig functions (see `api`). `thunk()` generates the wasm3
//! raw-call wrapper and `signature()` the wasm3 signature string for each one
//! at comptime, from the parameter types:
//!
//!   *Console  the console (from the import's userdata, takes no wasm slot)
//!   Mem       the cart's linear memory (takes no wasm slot)
//!   i32       one i32 argument
//!   Ptr       one i32 offset into linear memory
//!
//! A function returning an error traps the cart with an out-of-bounds error,
//! which is what every bounds check in here is.

const std = @import("std");
const m3 = @import("m3");
const Console = @import("Console.zig");
const Gfx = @import("gfx.zig").Gfx;

/// Offset into the cart's linear memory. Only `Mem` can turn it into bytes.
pub const Ptr = enum(u32) { _ };

pub const Mem = struct {
    bytes: []u8,

    pub fn slice(m: Mem, p: Ptr, len: usize) error{OutOfBounds}![]const u8 {
        const off: usize = @intFromEnum(p);
        if (off > m.bytes.len or len > m.bytes.len - off) return error.OutOfBounds;
        return m.bytes[off..][0..len];
    }

    /// A NUL-terminated string of at most `max` bytes, cut at the end of
    /// memory if the terminator is missing. The first byte must be in bounds.
    pub fn cstr(m: Mem, p: Ptr, max: usize) error{OutOfBounds}![]const u8 {
        const off: usize = @intFromEnum(p);
        if (off >= m.bytes.len) return error.OutOfBounds;
        const rest = m.bytes[off..][0..@min(max, m.bytes.len - off)];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
    }
};

/// Longest string text()/title() will read (matches the C host's buffer).
const max_str = 127;

/// The cart API. Names must match the import names in vex.h / vex.zig.
const api = struct {
    pub fn cls(c: *Console, color: i32) void {
        c.gfx.cls(color);
    }
    pub fn pset(c: *Console, x: i32, y: i32, color: i32) void {
        c.gfx.pset(x, y, color);
    }
    pub fn rect(c: *Console, x: i32, y: i32, w: i32, h: i32, color: i32) void {
        c.gfx.rect(x, y, w, h, color);
    }
    pub fn rectb(c: *Console, x: i32, y: i32, w: i32, h: i32, color: i32) void {
        c.gfx.rectb(x, y, w, h, color);
    }
    pub fn circ(c: *Console, x: i32, y: i32, r: i32, color: i32) void {
        c.gfx.circ(x, y, r, color);
    }
    pub fn circb(c: *Console, x: i32, y: i32, r: i32, color: i32) void {
        c.gfx.circb(x, y, r, color);
    }
    pub fn line(c: *Console, x0: i32, y0: i32, x1: i32, y1: i32, color: i32) void {
        c.gfx.line(x0, y0, x1, y1, color);
    }
    pub fn tri(c: *Console, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color: i32) void {
        c.gfx.tri(x1, y1, x2, y2, x3, y3, color);
    }
    pub fn trib(c: *Console, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color: i32) void {
        c.gfx.trib(x1, y1, x2, y2, x3, y3, color);
    }
    pub fn blit(c: *Console, mem: Mem, data: Ptr, x: i32, y: i32, w: i32, h: i32, key: i32) !void {
        const len = Gfx.blitSize(x, y, w, h) orelse return;
        c.gfx.blit(try mem.slice(data, len), x, y, w, h, key, null);
    }
    pub fn blitm(c: *Console, mem: Mem, data: Ptr, x: i32, y: i32, w: i32, h: i32, key: i32, map: Ptr) !void {
        const len = Gfx.blitSize(x, y, w, h) orelse return;
        const px = try mem.slice(data, len);
        const m = try mem.slice(map, 16);
        c.gfx.blit(px, x, y, w, h, key, m[0..16]);
    }
    pub fn text(c: *Console, mem: Mem, s: Ptr, x: i32, y: i32, color: i32) !void {
        c.gfx.text(try mem.cstr(s, max_str), x, y, color);
    }
    pub fn title(c: *Console, mem: Mem, s: Ptr) !void {
        c.setTitle(try mem.cstr(s, max_str));
    }
    pub fn btn(c: *Console, b: i32) i32 {
        return @intFromBool(c.input.btn(b));
    }
    pub fn btnp(c: *Console, b: i32) i32 {
        return @intFromBool(c.input.btnp(b));
    }
    pub fn mx(c: *Console) i32 {
        return c.input.mouse_x;
    }
    pub fn my(c: *Console) i32 {
        return c.input.mouse_y;
    }
    pub fn mbtn(c: *Console, b: i32) i32 {
        return @intFromBool(c.input.mbtn(b));
    }
    pub fn pal(c: *Console, index: i32, rgb: i32) void {
        c.gfx.pal(index, rgb);
    }
    pub fn palreset(c: *Console) void {
        c.gfx.palreset();
    }
    pub fn tone(c: *Console, freq: i32, duration: i32, volume: i32, flags: i32) void {
        if (c.synth) |s| {
            s.tone(freq, duration, volume, flags);
            c.tone_used = true;
        }
    }
};

fn ReturnPayload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

/// wasm3 signature string, e.g. "v(*iiiii)" for blit.
fn importSignature(comptime F: type) [:0]const u8 {
    const sig = comptime blk: {
        var s: []const u8 = switch (ReturnPayload(F)) {
            void => "v(",
            i32 => "i(",
            else => |R| @compileError("unsupported import return type " ++ @typeName(R)),
        };
        for (@typeInfo(F).@"fn".param_types) |T| {
            s = s ++ switch (T.?) {
                *Console, Mem => "",
                i32 => "i",
                Ptr => "*",
                else => |U| @compileError("unsupported import parameter type " ++ @typeName(U)),
            };
        }
        break :blk std.fmt.comptimePrint("{s})", .{s});
    };
    return sig;
}

fn memOf(mem: ?*anyopaque) Mem {
    const p = mem orelse return .{ .bytes = &.{} };
    const base: [*]u8 = @ptrCast(p);
    return .{ .bytes = base[0..m3.m3_GetMemorySizeAt(p)] };
}

/// wasm3 raw-call wrapper for `f`. Slot layout: the return value (if any)
/// occupies slot 0, then each wasm argument takes one 64-bit slot.
fn thunk(comptime f: anytype) m3.M3RawCall {
    const F = @TypeOf(f);
    const params = @typeInfo(F).@"fn".param_types;
    const has_ret = ReturnPayload(F) != void;
    const fallible = @typeInfo(@typeInfo(F).@"fn".return_type.?) == .error_union;

    return &struct {
        fn call(_: m3.IM3Runtime, ctx: m3.IM3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
            var args: std.meta.ArgsTuple(F) = undefined;
            var slot: usize = @intFromBool(has_ret);
            inline for (params, 0..) |T, i| {
                switch (T.?) {
                    *Console => args[i] = @ptrCast(@alignCast(ctx.*.userdata)),
                    Mem => args[i] = memOf(mem),
                    i32 => {
                        args[i] = @bitCast(@as(u32, @truncate(sp[slot])));
                        slot += 1;
                    },
                    Ptr => {
                        args[i] = @enumFromInt(@as(u32, @truncate(sp[slot])));
                        slot += 1;
                    },
                    else => unreachable,
                }
            }
            const result = @call(.auto, f, args);
            const value = if (fallible) result catch return @ptrCast(m3.m3Err_trapOutOfBoundsMemoryAccess) else result;
            if (has_ret) sp[0] = @as(u32, @bitCast(value));
            return null; // m3Err_none
        }
    }.call;
}

pub const Error = error{ CartLoad, CartTrap, OutOfMemory };

pub const Cart = struct {
    env: m3.IM3Environment,
    rt: m3.IM3Runtime,
    mod: m3.IM3Module,
    boot_fn: m3.IM3Function,
    update_fn: m3.IM3Function,
    /// wasm3 references the module bytes after parsing; keep them alive.
    wasm: []const u8,

    /// On success the cart owns `wasm`, freed by deinit() with the same gpa.
    pub fn load(wasm: []const u8, console: *Console) Error!Cart {
        const env = m3.m3_NewEnvironment() orelse return error.OutOfMemory;
        errdefer m3.m3_FreeEnvironment(env);
        const rt = m3.m3_NewRuntime(env, 64 * 1024, null) orelse return error.OutOfMemory;
        errdefer m3.m3_FreeRuntime(rt);

        var mod: m3.IM3Module = null;
        try check(rt, "parse", m3.m3_ParseModule(env, &mod, wasm.ptr, @intCast(wasm.len)));
        if (m3.m3_LoadModule(rt, mod)) |err| {
            m3.m3_FreeModule(mod); // the runtime owns mod only once loaded
            try check(rt, "load", err);
        }

        // Linking an import the cart doesn't use reports functionLookupFailed,
        // which is fine: carts only import what they call.
        inline for (comptime std.meta.declarations(api)) |name| {
            const f = @field(api, name);
            const r = m3.m3_LinkRawFunctionEx(mod, "env", name, importSignature(@TypeOf(f)), thunk(f), console);
            if (r != m3.m3Err_functionLookupFailed) try check(rt, "link " ++ name, r);
        }

        // Resolving a function compiles it, which is where wasm3 first
        // notices a missing import, so only a lookup failure means "absent".
        var boot_fn: m3.IM3Function = null;
        const rb = m3.m3_FindFunction(&boot_fn, rt, "boot");
        if (rb != m3.m3Err_functionLookupFailed) try check(rt, "boot", rb);

        var update_fn: m3.IM3Function = null;
        const ru = m3.m3_FindFunction(&update_fn, rt, "update");
        if (ru == m3.m3Err_functionLookupFailed) {
            std.debug.print("nex: cart has no update() export\n", .{});
            return error.CartLoad;
        }
        try check(rt, "update", ru);

        return .{ .env = env, .rt = rt, .mod = mod, .boot_fn = boot_fn, .update_fn = update_fn, .wasm = wasm };
    }

    pub fn deinit(c: *Cart, gpa: std.mem.Allocator) void {
        m3.m3_FreeRuntime(c.rt);
        m3.m3_FreeEnvironment(c.env);
        gpa.free(c.wasm);
        c.* = undefined;
    }

    pub fn boot(c: *Cart) Error!void {
        if (c.boot_fn != null) try check(c.rt, "boot", m3.m3_Call(c.boot_fn, 0, null));
    }

    pub fn update(c: *Cart) Error!void {
        try check(c.rt, "update", m3.m3_Call(c.update_fn, 0, null));
    }

    /// FNV-1a of the module bytes: the cart's on-disk signature.
    pub fn signature(c: *const Cart) u64 {
        return std.hash.Fnv1a_64.hash(c.wasm);
    }

    pub fn memorySize(c: *const Cart) usize {
        return m3.m3_GetMemorySize(c.mod, 0);
    }
};

fn check(rt: m3.IM3Runtime, what: []const u8, result: m3.M3Result) Error!void {
    const err = result orelse return;
    var info: m3.M3ErrorInfo = undefined;
    m3.m3_GetErrorInfo(rt, &info);
    const msg = if (info.message) |p| std.mem.span(@as([*:0]const u8, p)) else "";
    const sep = if (msg.len > 0) ": " else "";
    // A missing import means the cart was built against an API this host
    // doesn't provide (removed, renamed or newer), not that the file is broken.
    if (err == m3.m3Err_functionImportMissing) {
        std.debug.print("nex: cart needs a host function this nex doesn't provide{s}{s}\n", .{ sep, msg });
    } else if (msg.len > 0) {
        std.debug.print("nex: {s}: {s} ({s})\n", .{ what, std.mem.span(err), msg });
    } else {
        std.debug.print("nex: {s}: {s}\n", .{ what, std.mem.span(err) });
    }
    return error.CartTrap;
}

test "signatures" {
    try std.testing.expectEqualStrings("v(*iiiii)", importSignature(@TypeOf(api.blit)));
    try std.testing.expectEqualStrings("v(*iiiii*)", importSignature(@TypeOf(api.blitm)));
    try std.testing.expectEqualStrings("i()", importSignature(@TypeOf(api.mx)));
    try std.testing.expectEqualStrings("v(iiii)", importSignature(@TypeOf(api.tone)));
}

test "mem bounds" {
    var buf = [_]u8{ 'h', 'i', 0, 'x' };
    const m: Mem = .{ .bytes = &buf };
    try std.testing.expectEqualStrings("hi", try m.cstr(@enumFromInt(0), 10));
    try std.testing.expectEqualStrings("x", try m.cstr(@enumFromInt(3), 10));
    try std.testing.expectError(error.OutOfBounds, m.cstr(@enumFromInt(4), 10));
    try std.testing.expectError(error.OutOfBounds, m.slice(@enumFromInt(2), 3));
    _ = try m.slice(@enumFromInt(4), 0);
}
