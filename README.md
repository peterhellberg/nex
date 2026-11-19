# nex

`nex` is a Zig host/emulator for vex fantasy-console carts: small WebAssembly modules that export `boot()` and `update()` and talk to the host through a handful of imported `env` functions.

Carts get a 320x180 SWEETIE-16 software framebuffer, six buttons, mouse, a four-voice synth, and an 8x8 bitmap font. All cart-visible state lives in `Console`; the platform layer only presents the framebuffer and feeds input back in.

## Build and run

Requires Zig 0.17.1. Example carts are built alongside the host.

```
zig build                            # nex - raylib desktop backend
zig build -Dbackend=kitty            # kex - terminal backend
zig build run                        # run the Zig example cart
zig build test                       # unit tests
```

The two backends install as separate binaries, so `nex` and `kex` can coexist in `zig-out/bin`.

## Backends

- **nex (raylib)** - window, keyboard, mouse, four gamepads and audio.
- **kex (terminal)** - Kitty Graphics Protocol for output, Kitty keyboard protocol and SGR mouse for input. No audio or gamepads. Works in kitty and Ghostty. The framebuffer is nearest-neighbour upscaled in Zig and only changed rectangles are transmitted.

The terminal build does not compile raylib and links neither GL nor X11/Wayland.

## Controls

Desktop: arrows + Z/X are cart buttons; Super+Enter toggles fullscreen, Super+I toggles integer scaling, Super+R reloads, Escape quits.

Terminal: arrows + Z/X are cart buttons; Ctrl+R reloads, Escape or Ctrl+C quits.

## Headless mode

```
nex -n 200 cart.wasm                 # deterministic run, print frame hashes
nex -n 200 -t --dump fb.rgba cart.wasm
```

Timing, input and synth are bypassed so frame hashes match the other vex hosts. This is used for pixel-parity checks.

## Layout

- `src/main.zig` - CLI, cart loading/reload, main loop
- `src/cart.zig` - wasm3 runtime and the generated `env` import table
- `src/gfx.zig`, `src/font.zig` - framebuffer and drawing primitives
- `src/input.zig`, `src/synth.zig`, `src/Console.zig` - cart-visible state
- `src/backend.zig`, `src/backends/` - platform backends
- `vex.zig`, `vex.h` - guest SDK for Zig and C carts
