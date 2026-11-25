//! Root of the real-GPU test binary: the device conformance suite plus renderer output checks.
test {
    _ = @import("gpu_device_tests.zig");
    _ = @import("render_2d_gpu_tests.zig");
    _ = @import("render_3d_gpu_tests.zig");
    _ = @import("windowed_gpu_tests.zig");
}
