//! Pull the terminal backend's unit tests into the src test module.
test {
    _ = @import("backends/kitty.zig");
}
