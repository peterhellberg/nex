//! Contract shared by the main loop and the platform backends.
//!
//! A backend owns only platform concerns: presenting the framebuffer, reading
//! input into Console.Input, pacing, audio and console-level commands. Cart
//! state, drawing and the palette stay in Console and its raylib-free modules.

const std = @import("std");
const Console = @import("Console.zig");
const Synth = @import("synth.zig").Synth;

pub const Config = struct {
    console: *Console,
    /// Backends without an audio device simply leave console.synth null.
    synth: *Synth,
    io: std.Io,
    scale: i32,
};

pub const Frame = struct {
    quit: bool = false,
    reload: bool = false,
};
