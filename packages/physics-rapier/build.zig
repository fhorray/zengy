// Build script for the optional Rapier3D backend plugin (`official.physics.rapier`).
//
// Kept out of the root build like `physics-jolt`: `cargo` (Rust) is only needed when this package is
// built (`cd packages/physics-rapier && zig build`, or `zigeng add`), never for the engine itself.
//
// Outputs: `zigeng_physics_rapier` shared library (Rapier is linked in as a Rust staticlib).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeng = b.dependency("zigeng", .{ .target = target, .optimize = optimize });
    const engine_mod = zigeng.module("engine");
    const physics_mod = zigeng.module("physics");

    // 1. Rust staticlib (`crate-type = ["staticlib"]`) built by cargo on the user's machine.
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo.setCwd(b.path("."));

    const static_lib = if (target.result.abi == .msvc)
        "target/release/zigeng_rapier_ffi.lib"
    else
        "target/release/libzigeng_rapier_ffi.a";

    // 2. Zig backend wrapping the FFI.
    const rapier_mod = b.addModule("physics_rapier", .{
        .root_source_file = b.path("src/physics_rapier.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rapier_mod.addImport("engine", engine_mod);
    rapier_mod.addImport("physics", physics_mod);

    // 3. C-ABI plugin entry point as a shared library.
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin_entry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Rust's MinGW/GNU std expects the unwinder (`_Unwind_*`); libc++ pulls Zig's bundled libunwind.
        .link_libcpp = true,
    });
    plugin_mod.addImport("engine", engine_mod);
    plugin_mod.addImport("physics", physics_mod);
    plugin_mod.addImport("physics_rapier", rapier_mod);
    plugin_mod.addObjectFile(b.path(static_lib));
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "ws2_32", "userenv", "ntdll", "bcrypt", "advapi32", "kernel32" }) |lib| {
            plugin_mod.linkSystemLibrary(lib, .{});
        }
    }

    const plugin_lib = b.addLibrary(.{
        .name = "zigeng_physics_rapier",
        .linkage = .dynamic,
        .root_module = plugin_mod,
    });
    plugin_lib.step.dependOn(&cargo.step);
    b.installArtifact(plugin_lib);
}
