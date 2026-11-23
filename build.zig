// Build script for the Modular Zig Engine (`zigeng`).
//
// Targets:
// - `engine`: Minimal headless core SDK module (`src/engine.zig`)
// - `headless-ecs`: Phase 1 standalone 1000-entity simulation (`zig build run-headless`)
// - `c_plugin`: Phase 3 pure C11 shared library plugin (`examples/c-plugin/plugin.c`)
// - Optional packages: `window`, `graphics`, `ui_core`, `ui_markup`, `ui_novaui`,
//   `ui_immediate`, `scripting_host`, `assets`, `scene`, `editor_shell`, `render_3d`
// - `engine-cli`: Diagnostic CLI (`zig build run-cli`)
// - `test`: Per-module test suites organized inside each module's `tests/` directory

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public Zig SDK module ("engine")
    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Headless ECS example (Phase 1 gate)
    const headless_mod = b.createModule(.{
        .root_source_file = b.path("examples/headless-ecs/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    headless_mod.addImport("engine", engine_mod);

    const headless_exe = b.addExecutable(.{
        .name = "headless-ecs",
        .root_module = headless_mod,
    });
    b.installArtifact(headless_exe);

    const run_headless = b.addRunArtifact(headless_exe);
    const run_headless_step = b.step("run-headless", "Run the headless ECS example (1000 entities)");
    run_headless_step.dependOn(&run_headless.step);

    // Pure C ABI example plugin (Phase 3 gate)
    const c_plugin_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_plugin_mod.addIncludePath(b.path("include"));
    c_plugin_mod.addCSourceFile(.{
        .file = b.path("examples/c-plugin/plugin.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });

    const c_plugin = b.addLibrary(.{
        .name = "c_plugin",
        .linkage = .dynamic,
        .root_module = c_plugin_mod,
    });
    const install_c_plugin = b.addInstallArtifact(c_plugin, .{});

    // Translate C ABI header for layout & compatibility tests
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/engine_extension.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_abi_mod = translate_c.createModule();

    // Optional packages (Phases 5-13)
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("packages/window/src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("engine", engine_mod);

    const graphics_mod = b.addModule("graphics", .{
        .root_source_file = b.path("packages/graphics/src/graphics.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_mod.addImport("engine", engine_mod);

    const ui_core_mod = b.addModule("ui_core", .{
        .root_source_file = b.path("packages/ui-core/src/ui_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_core_mod.addImport("engine", engine_mod);
    ui_core_mod.addImport("graphics", graphics_mod);

    const ui_markup_mod = b.addModule("ui_markup", .{
        .root_source_file = b.path("packages/ui-markup/src/ui_markup.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_markup_mod.addImport("ui_core", ui_core_mod);

    const ui_novaui_mod = b.addModule("ui_novaui", .{
        .root_source_file = b.path("packages/ui-novaui/src/novaui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_novaui_mod.addImport("ui_core", ui_core_mod);

    const ui_immediate_mod = b.addModule("ui_immediate", .{
        .root_source_file = b.path("packages/ui-immediate/src/ui_immediate.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_immediate_mod.addImport("engine", engine_mod);
    ui_immediate_mod.addImport("window", window_mod);
    ui_immediate_mod.addImport("graphics", graphics_mod);

    const scripting_host_mod = b.addModule("scripting_host", .{
        .root_source_file = b.path("packages/scripting-host/src/scripting_host.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripting_host_mod.addImport("engine", engine_mod);

    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("packages/assets/src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    assets_mod.addImport("engine", engine_mod);

    const scene_mod = b.addModule("scene", .{
        .root_source_file = b.path("packages/scene/src/scene.zig"),
        .target = target,
        .optimize = optimize,
    });
    scene_mod.addImport("engine", engine_mod);

    const physics_mod = b.addModule("physics", .{
        .root_source_file = b.path("packages/physics/src/physics.zig"),
        .target = target,
        .optimize = optimize,
    });
    physics_mod.addImport("engine", engine_mod);

    const editor_shell_mod = b.addModule("editor_shell", .{
        .root_source_file = b.path("packages/editor-shell/src/editor_shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_shell_mod.addImport("engine", engine_mod);

    // External dependencies (validated for Zig 0.17.1)
    const z_toml_dep = b.dependency("z_toml", .{
        .target = target,
        .optimize = optimize,
    });
    const lookout_dep = b.dependency("lookout", .{
        .target = target,
        .optimize = optimize,
    });
    const yyjson_dep = b.dependency("yyjson", .{});
    const jolt_dep = b.dependency("jolt", .{});

    const jolt_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    jolt_c_mod.addIncludePath(jolt_dep.path("."));
    jolt_c_mod.addIncludePath(b.path("packages/physics-jolt/src"));
    const jolt_cpp_flags: []const []const u8 = &.{
        "-std=c++17",
        "-DJPH_OBJECT_STREAM",
        "-fno-sanitize=undefined",
    };
    jolt_c_mod.addCSourceFile(.{
        .file = b.path("packages/physics-jolt/src/jolt_c_api.cpp"),
        .flags = jolt_cpp_flags,
    });
    jolt_c_mod.addCSourceFiles(.{
        .root = jolt_dep.path("Jolt"),
        .files = &.{
            "AABBTree/AABBTreeBuilder.cpp",
            "Compute/ComputeSystem.cpp",
            "Compute/CPU/ComputeBufferCPU.cpp",
            "Compute/CPU/ComputeQueueCPU.cpp",
            "Compute/CPU/ComputeSystemCPU.cpp",
            "Core/Color.cpp",
            "Core/Factory.cpp",
            "Core/IssueReporting.cpp",
            "Core/JobSystemSingleThreaded.cpp",
            "Core/JobSystemThreadPool.cpp",
            "Core/JobSystemWithBarrier.cpp",
            "Core/LinearCurve.cpp",
            "Core/Memory.cpp",
            "Core/Profiler.cpp",
            "Core/RTTI.cpp",
            "Core/Semaphore.cpp",
            "Core/StringTools.cpp",
            "Core/TickCounter.cpp",
            "Geometry/ConvexHullBuilder2D.cpp",
            "Geometry/ConvexHullBuilder.cpp",
            "Geometry/Indexify.cpp",
            "Geometry/OrientedBox.cpp",
            "Math/Vec3.cpp",
            "ObjectStream/ObjectStreamBinaryIn.cpp",
            "ObjectStream/ObjectStreamBinaryOut.cpp",
            "ObjectStream/ObjectStream.cpp",
            "ObjectStream/ObjectStreamIn.cpp",
            "ObjectStream/ObjectStreamOut.cpp",
            "ObjectStream/ObjectStreamTextIn.cpp",
            "ObjectStream/ObjectStreamTextOut.cpp",
            "ObjectStream/SerializableObject.cpp",
            "ObjectStream/TypeDeclarations.cpp",
            "Physics/Body/Body.cpp",
            "Physics/Body/BodyCreationSettings.cpp",
            "Physics/Body/BodyInterface.cpp",
            "Physics/Body/BodyManager.cpp",
            "Physics/Body/MassProperties.cpp",
            "Physics/Body/MotionProperties.cpp",
            "Physics/Character/CharacterBase.cpp",
            "Physics/Character/Character.cpp",
            "Physics/Character/CharacterVirtual.cpp",
            "Physics/Collision/BroadPhase/BroadPhaseBruteForce.cpp",
            "Physics/Collision/BroadPhase/BroadPhase.cpp",
            "Physics/Collision/BroadPhase/BroadPhaseQuadTree.cpp",
            "Physics/Collision/BroadPhase/QuadTree.cpp",
            "Physics/Collision/CastConvexVsTriangles.cpp",
            "Physics/Collision/CastSphereVsTriangles.cpp",
            "Physics/Collision/CollideConvexVsTriangles.cpp",
            "Physics/Collision/CollideSphereVsTriangles.cpp",
            "Physics/Collision/CollisionDispatch.cpp",
            "Physics/Collision/CollisionGroup.cpp",
            "Physics/Collision/EstimateCollisionResponse.cpp",
            "Physics/Collision/GroupFilter.cpp",
            "Physics/Collision/GroupFilterTable.cpp",
            "Physics/Collision/ManifoldBetweenTwoFaces.cpp",
            "Physics/Collision/NarrowPhaseQuery.cpp",
            "Physics/Collision/NarrowPhaseStats.cpp",
            "Physics/Collision/PhysicsMaterial.cpp",
            "Physics/Collision/PhysicsMaterialSimple.cpp",
            "Physics/Collision/Shape/BoxShape.cpp",
            "Physics/Collision/Shape/CapsuleShape.cpp",
            "Physics/Collision/Shape/CompoundShape.cpp",
            "Physics/Collision/Shape/ConvexHullShape.cpp",
            "Physics/Collision/Shape/ConvexShape.cpp",
            "Physics/Collision/Shape/CylinderShape.cpp",
            "Physics/Collision/Shape/DecoratedShape.cpp",
            "Physics/Collision/Shape/EmptyShape.cpp",
            "Physics/Collision/Shape/HeightFieldShape.cpp",
            "Physics/Collision/Shape/MeshShape.cpp",
            "Physics/Collision/Shape/MutableCompoundShape.cpp",
            "Physics/Collision/Shape/OffsetCenterOfMassShape.cpp",
            "Physics/Collision/Shape/PlaneShape.cpp",
            "Physics/Collision/Shape/RotatedTranslatedShape.cpp",
            "Physics/Collision/Shape/ScaledShape.cpp",
            "Physics/Collision/Shape/Shape.cpp",
            "Physics/Collision/Shape/SphereShape.cpp",
            "Physics/Collision/Shape/StaticCompoundShape.cpp",
            "Physics/Collision/Shape/TaperedCapsuleShape.cpp",
            "Physics/Collision/Shape/TaperedCylinderShape.cpp",
            "Physics/Collision/Shape/TriangleShape.cpp",
            "Physics/Collision/TransformedShape.cpp",
            "Physics/Constraints/ConeConstraint.cpp",
            "Physics/Constraints/Constraint.cpp",
            "Physics/Constraints/ConstraintManager.cpp",
            "Physics/Constraints/ContactConstraintManager.cpp",
            "Physics/Constraints/DistanceConstraint.cpp",
            "Physics/Constraints/FixedConstraint.cpp",
            "Physics/Constraints/GearConstraint.cpp",
            "Physics/Constraints/HingeConstraint.cpp",
            "Physics/Constraints/MotorSettings.cpp",
            "Physics/Constraints/PathConstraint.cpp",
            "Physics/Constraints/PathConstraintPath.cpp",
            "Physics/Constraints/PathConstraintPathHermite.cpp",
            "Physics/Constraints/PointConstraint.cpp",
            "Physics/Constraints/PulleyConstraint.cpp",
            "Physics/Constraints/RackAndPinionConstraint.cpp",
            "Physics/Constraints/SixDOFConstraint.cpp",
            "Physics/Constraints/SliderConstraint.cpp",
            "Physics/Constraints/SpringSettings.cpp",
            "Physics/Constraints/SwingTwistConstraint.cpp",
            "Physics/Constraints/TwoBodyConstraint.cpp",
            "Physics/DeterminismLog.cpp",
            "Physics/IslandBuilder.cpp",
            "Physics/LargeIslandSplitter.cpp",
            "Physics/PhysicsScene.cpp",
            "Physics/PhysicsSystem.cpp",
            "Physics/PhysicsUpdateContext.cpp",
            "Physics/Ragdoll/Ragdoll.cpp",
            "Physics/SoftBody/SoftBodyCreationSettings.cpp",
            "Physics/SoftBody/SoftBodyMotionProperties.cpp",
            "Physics/SoftBody/SoftBodyShape.cpp",
            "Physics/SoftBody/SoftBodySharedSettings.cpp",
            "Physics/StateRecorderImpl.cpp",
            "Physics/Vehicle/MotorcycleController.cpp",
            "Physics/Vehicle/TrackedVehicleController.cpp",
            "Physics/Vehicle/VehicleAntiRollBar.cpp",
            "Physics/Vehicle/VehicleCollisionTester.cpp",
            "Physics/Vehicle/VehicleConstraint.cpp",
            "Physics/Vehicle/VehicleController.cpp",
            "Physics/Vehicle/VehicleDifferential.cpp",
            "Physics/Vehicle/VehicleEngine.cpp",
            "Physics/Vehicle/VehicleTrack.cpp",
            "Physics/Vehicle/VehicleTransmission.cpp",
            "Physics/Vehicle/Wheel.cpp",
            "Physics/Vehicle/WheeledVehicleController.cpp",
            "RegisterTypes.cpp",
            "Skeleton/SkeletalAnimation.cpp",
            "Skeleton/Skeleton.cpp",
            "Skeleton/SkeletonMapper.cpp",
            "Skeleton/SkeletonPose.cpp",
            "TriangleSplitter/TriangleSplitterBinning.cpp",
            "TriangleSplitter/TriangleSplitter.cpp",
            "TriangleSplitter/TriangleSplitterMean.cpp",
        },
        .flags = jolt_cpp_flags,
    });
    const jolt_c_lib = b.addLibrary(.{
        .name = "jolt_c",
        .linkage = .static,
        .root_module = jolt_c_mod,
    });

    const physics_jolt_mod = b.addModule("physics_jolt", .{
        .root_source_file = b.path("packages/physics-jolt/src/physics_jolt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    physics_jolt_mod.addImport("engine", engine_mod);
    physics_jolt_mod.addImport("physics", physics_mod);
    physics_jolt_mod.addIncludePath(b.path("packages/physics-jolt/src"));
    physics_jolt_mod.linkLibrary(jolt_c_lib);

    const jolt_plugin_mod = b.createModule(.{
        .root_source_file = b.path("packages/physics-jolt/src/plugin_entry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    jolt_plugin_mod.addImport("engine", engine_mod);
    jolt_plugin_mod.addImport("physics", physics_mod);
    jolt_plugin_mod.addImport("physics_jolt", physics_jolt_mod);

    const jolt_plugin_lib = b.addLibrary(.{
        .name = "zigeng_physics_jolt",
        .linkage = .dynamic,
        .root_module = jolt_plugin_mod,
    });
    b.installArtifact(jolt_plugin_lib);

    const translate_yyjson = b.addTranslateC(.{
        .root_source_file = yyjson_dep.path("src/yyjson.h"),
        .target = target,
        .optimize = optimize,
    });
    const yyjson_c_mod = translate_yyjson.createModule();
    yyjson_c_mod.addIncludePath(yyjson_dep.path("src"));
    yyjson_c_mod.addCSourceFile(.{
        .file = yyjson_dep.path("src/yyjson.c"),
        .flags = &.{"-std=c11"},
    });

    const toml_format_mod = b.addModule("toml_format", .{
        .root_source_file = b.path("packages/formats/toml/src/toml_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_format_mod.addImport("engine", engine_mod);
    toml_format_mod.addImport("toml", z_toml_dep.module("toml"));

    const json_format_mod = b.addModule("json_format", .{
        .root_source_file = b.path("packages/formats/json/src/json_format.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    json_format_mod.addImport("engine", engine_mod);
    json_format_mod.addImport("yyjson_c", yyjson_c_mod);

    const file_watcher_mod = b.addModule("file_watcher", .{
        .root_source_file = b.path("packages/tooling/file-watcher/src/file_watcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_watcher_mod.addImport("engine", engine_mod);
    file_watcher_mod.addImport("lookout", lookout_dep.module("lookout"));

    const testing_sdk_mod = b.addModule("testing_sdk", .{
        .root_source_file = b.path("packages/testing/src/testing_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    testing_sdk_mod.addImport("engine", engine_mod);
    testing_sdk_mod.addImport("window", window_mod);
    testing_sdk_mod.addImport("graphics", graphics_mod);
    testing_sdk_mod.addImport("ui_core", ui_core_mod);
    testing_sdk_mod.addImport("toml_format", toml_format_mod);

    const lua_c_dep = b.dependency("lua_c", .{});
    const translate_lua = b.addTranslateC(.{
        .root_source_file = b.path("packages/scripting-lua/src/lua_bundle.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_lua.addIncludePath(lua_c_dep.path("."));
    const lua_c_mod = translate_lua.createModule();
    lua_c_mod.addIncludePath(lua_c_dep.path("."));
    lua_c_mod.addCSourceFiles(.{
        .root = lua_c_dep.path("."),
        .files = &.{
            "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",   "lcorolib.c",
            "lctype.c",   "ldblib.c",  "ldebug.c",   "ldo.c",     "ldump.c",
            "lfunc.c",    "lgc.c",     "linit.c",    "liolib.c",  "llex.c",
            "lmathlib.c", "lmem.c",    "loadlib.c",  "lobject.c", "lopcodes.c",
            "loslib.c",   "lparser.c", "lstate.c",   "lstring.c", "lstrlib.c",
            "ltable.c",   "ltablib.c", "ltm.c",      "lundump.c", "lutf8lib.c",
            "lvm.c",      "lzio.c",
        },
        .flags = &.{"-std=c99"},
    });

    const scripting_lua_mod = b.addModule("scripting_lua", .{
        .root_source_file = b.path("packages/scripting-lua/src/scripting_lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scripting_lua_mod.addImport("engine", engine_mod);
    scripting_lua_mod.addImport("scripting_host", scripting_host_mod);
    scripting_lua_mod.addImport("lua_c", lua_c_mod);

    // PocketPy v2.2.0 (MIT) vendored inside packages/scripting-python/third_party/pocketpy.
    const pocketpy_c_mod = blk: {
        const translate_pocketpy = b.addTranslateC(.{
            .root_source_file = b.path("packages/scripting-python/src/pocketpy_bundle.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_pocketpy.addIncludePath(b.path("packages/scripting-python/third_party/pocketpy"));
        const mod = translate_pocketpy.createModule();
        mod.addIncludePath(b.path("packages/scripting-python/third_party/pocketpy"));
        mod.addCSourceFile(.{
            .file = b.path("packages/scripting-python/third_party/pocketpy/pocketpy.c"),
            .flags = &.{ "-std=c11", "-DPK_ENABLE_OS=0" },
        });
        // PocketPy's `socket` module uses Winsock on Windows.
        if (target.result.os.tag == .windows) mod.linkSystemLibrary("ws2_32", .{});
        break :blk mod;
    };

    const scripting_python_mod = b.addModule("scripting_python", .{
        .root_source_file = b.path("packages/scripting-python/src/scripting_python.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scripting_python_mod.addImport("engine", engine_mod);
    scripting_python_mod.addImport("scripting_host", scripting_host_mod);
    scripting_python_mod.addImport("pocketpy_c", pocketpy_c_mod);

    const default_plugins_mod = b.addModule("default_plugins", .{
        .root_source_file = b.path("packages/default-plugins/src/default_plugins.zig"),
        .target = target,
        .optimize = optimize,
    });
    default_plugins_mod.addImport("engine", engine_mod);
    default_plugins_mod.addImport("window", window_mod);
    default_plugins_mod.addImport("graphics", graphics_mod);
    default_plugins_mod.addImport("ui_core", ui_core_mod);
    default_plugins_mod.addImport("assets", assets_mod);
    default_plugins_mod.addImport("scene", scene_mod);
    default_plugins_mod.addImport("scripting_host", scripting_host_mod);
    default_plugins_mod.addImport("toml_format", toml_format_mod);
    default_plugins_mod.addImport("json_format", json_format_mod);

    const render_3d_mod = b.addModule("render_3d", .{
        .root_source_file = b.path("packages/render-3d/src/render_3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_3d_mod.addImport("engine", engine_mod);

    // Diagnostic CLI tool (`tools/cli`)
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("tools/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("engine", engine_mod);
    cli_mod.addImport("window", window_mod);
    cli_mod.addImport("graphics", graphics_mod);
    cli_mod.addImport("ui_core", ui_core_mod);
    cli_mod.addImport("scripting_host", scripting_host_mod);
    cli_mod.addImport("assets", assets_mod);
    cli_mod.addImport("testing_sdk", testing_sdk_mod);
    cli_mod.addImport("toml_format", toml_format_mod);

    const cli_exe = b.addExecutable(.{
        .name = "zigeng",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    const cli_cmd = b.option([]const u8, "cli-cmd", "CLI subcommand (doctor, packages, list-official, new, run, add)") orelse "doctor";
    run_cli.addArg(cli_cmd);
    if (b.option([]const u8, "cli-arg", "Optional argument for CLI subcommand")) |arg| {
        run_cli.addArg(arg);
    }
    const run_cli_step = b.step("run-cli", "Run the zigeng CLI (doctor, packages, list-official, new, run, add)");
    run_cli_step.dependOn(&run_cli.step);

    // Integrated Playground example (`examples/playground`)
    const playground_mod = b.createModule(.{
        .root_source_file = b.path("examples/playground/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    playground_mod.addImport("engine", engine_mod);
    playground_mod.addImport("window", window_mod);
    playground_mod.addImport("graphics", graphics_mod);
    playground_mod.addImport("ui_core", ui_core_mod);
    playground_mod.addImport("ui_markup", ui_markup_mod);
    playground_mod.addImport("ui_novaui", ui_novaui_mod);
    playground_mod.addImport("scripting_host", scripting_host_mod);
    playground_mod.addImport("assets", assets_mod);
    playground_mod.addImport("scene", scene_mod);
    playground_mod.addImport("editor_shell", editor_shell_mod);
    playground_mod.addImport("render_3d", render_3d_mod);

    const playground_exe = b.addExecutable(.{
        .name = "playground",
        .root_module = playground_mod,
    });
    b.installArtifact(playground_exe);

    const run_playground = b.addRunArtifact(playground_exe);
    run_playground.step.dependOn(&install_c_plugin.step);
    const run_playground_step = b.step("run-playground", "Run the integrated engine playground");
    run_playground_step.dependOn(&run_playground.step);

    // SDL 3.4.20 (zlib) vendored in third_party/sdl3 (Windows x64 binaries for D1).
    const sdl3_c_mod = blk: {
        const translate_sdl3 = b.addTranslateC(.{
            .root_source_file = b.path("packages/window-sdl3/src/sdl3_bundle.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_sdl3.addIncludePath(b.path("third_party/sdl3/include"));
        const mod = translate_sdl3.createModule();
        mod.addIncludePath(b.path("third_party/sdl3/include"));
        mod.addLibraryPath(b.path("third_party/sdl3/lib/x64"));
        mod.linkSystemLibrary("SDL3", .{});
        break :blk mod;
    };

    const window_sdl3_mod = b.addModule("window_sdl3", .{
        .root_source_file = b.path("packages/window-sdl3/src/window_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_sdl3_mod.addImport("engine", engine_mod);
    window_sdl3_mod.addImport("window", window_mod);
    window_sdl3_mod.addImport("sdl3_c", sdl3_c_mod);

    // Visual hello (D1): native SDL3 window, input and DPI. Run with `zig build run-visual-hello`.
    const visual_hello_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-hello/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_hello_mod.addImport("engine", engine_mod);
    visual_hello_mod.addImport("window_sdl3", window_sdl3_mod);

    const visual_hello_exe = b.addExecutable(.{
        .name = "visual-hello",
        .root_module = visual_hello_mod,
    });
    b.installArtifact(visual_hello_exe);

    // The SDL3 runtime DLL must sit next to the executable in zig-out/bin when present.
    if (std.Io.Dir.cwd().access(b.graph.io, "third_party/sdl3/bin/x64/SDL3.dll", .{})) |_| {
        const install_sdl3_dll = b.addInstallBinFile(b.path("third_party/sdl3/bin/x64/SDL3.dll"), "SDL3.dll");
        b.getInstallStep().dependOn(&install_sdl3_dll.step);
    } else |_| {}
    // Run the installed copy: the cache copy has no SDL3.dll beside it (Windows exit 0xC0000135).
    const run_visual_hello = b.addSystemCommand(&.{"zig-out/bin/visual-hello.exe"});
    run_visual_hello.setCwd(b.path("."));
    run_visual_hello.step.dependOn(b.getInstallStep());
    const run_visual_hello_step = b.step("run-visual-hello", "Open the native SDL3 hello window (D1)");
    run_visual_hello_step.dependOn(&run_visual_hello.step);

    const text_mod = b.addModule("text", .{
        .root_source_file = b.path("packages/text/src/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_mod.addImport("graphics", graphics_mod);

    const render_2d_mod = b.addModule("render_2d", .{
        .root_source_file = b.path("packages/render-2d/src/render_2d.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_2d_mod.addImport("engine", engine_mod);
    render_2d_mod.addImport("graphics", graphics_mod);
    render_2d_mod.addImport("scene", scene_mod);

    const gpu_resources_mod = b.addModule("gpu_resources", .{
        .root_source_file = b.path("packages/graphics-sdlgpu/src/gpu_resources.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_resources_mod.addImport("graphics", graphics_mod);

    const graphics_sdlgpu_mod = b.addModule("graphics_sdlgpu", .{
        .root_source_file = b.path("packages/graphics-sdlgpu/src/graphics_sdlgpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_sdlgpu_mod.addImport("engine", engine_mod);
    graphics_sdlgpu_mod.addImport("graphics", graphics_mod);
    graphics_sdlgpu_mod.addImport("window_sdl3", window_sdl3_mod);
    graphics_sdlgpu_mod.addImport("text", text_mod);
    graphics_sdlgpu_mod.addImport("sdl3_c", sdl3_c_mod);

    // Visual GPU hello (D2): SDL3 window + SDL_GPU triangle & rect. Run with `zig build run-visual-gpu`.
    const visual_gpu_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-gpu/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_gpu_mod.addImport("engine", engine_mod);
    visual_gpu_mod.addImport("window", window_mod);
    visual_gpu_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_gpu_mod.addImport("graphics", graphics_mod);
    visual_gpu_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);

    const visual_gpu_exe = b.addExecutable(.{
        .name = "visual-gpu",
        .root_module = visual_gpu_mod,
    });
    b.installArtifact(visual_gpu_exe);

    const run_visual_gpu = b.addSystemCommand(&.{"zig-out/bin/visual-gpu.exe"});
    run_visual_gpu.setCwd(b.path("."));
    run_visual_gpu.step.dependOn(b.getInstallStep());
    const run_visual_gpu_step = b.step("run-visual-gpu", "Open the native SDL3 + SDL_GPU hello window (D2)");
    run_visual_gpu_step.dependOn(&run_visual_gpu.step);

    // Visual 2D hello (D3): Camera2D, Sprite, Transform2D, and batched textures. Run with `zig build run-visual-2d`.
    const visual_2d_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-2d/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_2d_mod.addImport("engine", engine_mod);
    visual_2d_mod.addImport("window", window_mod);
    visual_2d_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_2d_mod.addImport("graphics", graphics_mod);
    visual_2d_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_2d_mod.addImport("scene", scene_mod);
    visual_2d_mod.addImport("render_2d", render_2d_mod);

    const visual_2d_exe = b.addExecutable(.{
        .name = "visual-2d",
        .root_module = visual_2d_mod,
    });
    b.installArtifact(visual_2d_exe);

    const run_visual_2d = b.addSystemCommand(&.{"zig-out/bin/visual-2d.exe"});
    run_visual_2d.setCwd(b.path("."));
    run_visual_2d.step.dependOn(b.getInstallStep());
    const run_visual_2d_step = b.step("run-visual-2d", "Open the native SDL3 2D sprites & Camera2D demo (D3)");
    run_visual_2d_step.dependOn(&run_visual_2d.step);

    // Visual UI hello (D4): UiTree, ui_markup, font atlas text, click, textbox & clipping. Run with `zig build run-visual-ui`.
    const visual_ui_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-ui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_ui_mod.addImport("engine", engine_mod);
    visual_ui_mod.addImport("window", window_mod);
    visual_ui_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_ui_mod.addImport("graphics", graphics_mod);
    visual_ui_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_ui_mod.addImport("ui_core", ui_core_mod);
    visual_ui_mod.addImport("ui_markup", ui_markup_mod);

    const visual_ui_exe = b.addExecutable(.{
        .name = "visual-ui",
        .root_module = visual_ui_mod,
    });
    b.installArtifact(visual_ui_exe);

    const run_visual_ui = b.addSystemCommand(&.{"zig-out/bin/visual-ui.exe"});
    run_visual_ui.setCwd(b.path("."));
    run_visual_ui.step.dependOn(b.getInstallStep());
    const run_visual_ui_step = b.step("run-visual-ui", "Open the native SDL3 UI & text demo (D4)");
    run_visual_ui_step.dependOn(&run_visual_ui.step);

    // Visual Playground (D5): integrated 2D scene + UI panel (FPS, Spawn, Log). Run with `zig build run-visual-playground`.
    const visual_pg_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-playground/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_pg_mod.addImport("engine", engine_mod);
    visual_pg_mod.addImport("window", window_mod);
    visual_pg_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_pg_mod.addImport("graphics", graphics_mod);
    visual_pg_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_pg_mod.addImport("scene", scene_mod);
    visual_pg_mod.addImport("render_2d", render_2d_mod);
    visual_pg_mod.addImport("ui_core", ui_core_mod);
    visual_pg_mod.addImport("ui_markup", ui_markup_mod);

    const visual_pg_exe = b.addExecutable(.{
        .name = "visual-playground",
        .root_module = visual_pg_mod,
    });
    b.installArtifact(visual_pg_exe);

    const run_visual_pg = b.addSystemCommand(&.{"zig-out/bin/visual-playground.exe"});
    run_visual_pg.setCwd(b.path("."));
    run_visual_pg.step.dependOn(b.getInstallStep());
    const run_visual_pg_step = b.step("run-visual-playground", "Open the integrated 2D + UI Visual Playground (D5)");
    run_visual_pg_step.dependOn(&run_visual_pg.step);

    // Visual Python (PocketPy + SDL_GPU): Python script driving `engine.draw_rect`. Run with `zig build run-visual-python`.
    const visual_py_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-python/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_py_mod.addImport("engine", engine_mod);
    visual_py_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_py_mod.addImport("graphics", graphics_mod);
    visual_py_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_py_mod.addImport("scripting_host", scripting_host_mod);
    visual_py_mod.addImport("scripting_python", scripting_python_mod);

    const visual_py_exe = b.addExecutable(.{
        .name = "visual-python",
        .root_module = visual_py_mod,
    });
    b.installArtifact(visual_py_exe);

    const run_visual_py = b.addSystemCommand(&.{"zig-out/bin/visual-python.exe"});
    run_visual_py.setCwd(b.path("."));
    run_visual_py.step.dependOn(b.getInstallStep());
    const run_visual_py_step = b.step("run-visual-python", "Open the PocketPy + SDL_GPU visual demo");
    run_visual_py_step.dependOn(&run_visual_py.step);

    // Visual 3D (Phase E): 3D unlit meshes, depth buffer, Camera3D & frustum culling. Run with `zig build run-visual-3d`.
    const visual_3d_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-3d/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_3d_mod.addImport("engine", engine_mod);
    visual_3d_mod.addImport("window", window_mod);
    visual_3d_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_3d_mod.addImport("graphics", graphics_mod);
    visual_3d_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_3d_mod.addImport("render_3d", render_3d_mod);

    const visual_3d_exe = b.addExecutable(.{
        .name = "visual-3d",
        .root_module = visual_3d_mod,
    });
    b.installArtifact(visual_3d_exe);

    const run_visual_3d = b.addSystemCommand(&.{"zig-out/bin/visual-3d.exe"});
    run_visual_3d.setCwd(b.path("."));
    run_visual_3d.step.dependOn(b.getInstallStep());
    const run_visual_3d_step = b.step("run-visual-3d", "Open the Phase E 3D Foundation demo");
    run_visual_3d_step.dependOn(&run_visual_3d.step);

    // Manifesto-driven visual runtime (`tools/runtime/main.zig`): reads game.toml in CWD.
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("tools/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_mod.addImport("engine", engine_mod);
    runtime_mod.addImport("window", window_mod);
    runtime_mod.addImport("window_sdl3", window_sdl3_mod);
    runtime_mod.addImport("graphics", graphics_mod);
    runtime_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    runtime_mod.addImport("ui_core", ui_core_mod);
    runtime_mod.addImport("ui_markup", ui_markup_mod);
    runtime_mod.addImport("scripting_host", scripting_host_mod);
    runtime_mod.addImport("scripting_python", scripting_python_mod);
    runtime_mod.addImport("scripting_lua", scripting_lua_mod);
    runtime_mod.addImport("toml_format", toml_format_mod);
    runtime_mod.addImport("scene", scene_mod);
    runtime_mod.addImport("physics", physics_mod);
    runtime_mod.addImport("physics_jolt", physics_jolt_mod);

    const runtime_exe = b.addExecutable(.{
        .name = "zigeng-runtime",
        .root_module = runtime_mod,
    });
    b.installArtifact(runtime_exe);

    // Microbenchmark suite (`benchmarks/main.zig`)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("engine", engine_mod);
    bench_mod.addImport("graphics", graphics_mod);
    bench_mod.addImport("ui_core", ui_core_mod);
    bench_mod.addImport("scene", scene_mod);
    bench_mod.addImport("json_format", json_format_mod);

    const bench_exe = b.addExecutable(.{
        .name = "zigeng-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const run_bench_step = b.step("run-bench", "Run the engine microbenchmark suite");
    run_bench_step.dependOn(&run_bench.step);

    // Per-module test suites
    const test_step = b.step("test", "Run all per-module unit, integration, and C ABI tests");

    const addModuleTest = struct {
        fn add(
            builder: *std.Build,
            step: *std.Build.Step,
            path: []const u8,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            link_c: bool,
            imports: []const struct { name: []const u8, mod: *std.Build.Module },
            dep_step: ?*std.Build.Step,
        ) void {
            const m = builder.createModule(.{
                .root_source_file = builder.path(path),
                .target = tgt,
                .optimize = opt,
                .link_libc = link_c,
            });
            for (imports) |imp| {
                m.addImport(imp.name, imp.mod);
            }
            const t = builder.addTest(.{ .root_module = m });
            const r = builder.addRunArtifact(t);
            if (dep_step) |ds| r.step.dependOn(ds);
            step.dependOn(&r.step);
        }
    }.add;

    addModuleTest(b, test_step, "src/core/tests/core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
    }, null);

    addModuleTest(b, test_step, "src/core/tests/abi_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "c_abi", .mod = c_abi_mod },
    }, &install_c_plugin.step);

    addModuleTest(b, test_step, "packages/window/tests/window_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
    }, null);

    addModuleTest(b, test_step, "packages/graphics/tests/graphics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-core/tests/ui_core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-markup/tests/ui_frontends_tests.zig", target, optimize, false, &.{
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_markup", .mod = ui_markup_mod },
        .{ .name = "ui_novaui", .mod = ui_novaui_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-immediate/tests/ui_immediate_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_immediate", .mod = ui_immediate_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting-host/tests/scripting_host_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
    }, null);

    addModuleTest(b, test_step, "packages/assets/tests/assets_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "assets", .mod = assets_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scene/tests/scene_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scene", .mod = scene_mod },
    }, null);

    addModuleTest(b, test_step, "packages/editor-shell/tests/editor_shell_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "editor_shell", .mod = editor_shell_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render-3d/tests/render_3d_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
    }, null);

    addModuleTest(b, test_step, "packages/formats/toml/tests/toml_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "toml_format", .mod = toml_format_mod },
    }, null);

    addModuleTest(b, test_step, "packages/formats/json/tests/json_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "json_format", .mod = json_format_mod },
    }, null);

    addModuleTest(b, test_step, "packages/tooling/file-watcher/tests/file_watcher_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "file_watcher", .mod = file_watcher_mod },
    }, null);

    addModuleTest(b, test_step, "packages/testing/tests/testing_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "testing_sdk", .mod = testing_sdk_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting-lua/tests/scripting_lua_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
        .{ .name = "scripting_lua", .mod = scripting_lua_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting-python/tests/scripting_python_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
        .{ .name = "scripting_lua", .mod = scripting_lua_mod },
        .{ .name = "scripting_python", .mod = scripting_python_mod },
    }, null);

    addModuleTest(b, test_step, "packages/graphics-sdlgpu/tests/graphics_sdlgpu_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "gpu_resources", .mod = gpu_resources_mod },
    }, null);

    addModuleTest(b, test_step, "packages/text/tests/text_tests.zig", target, optimize, false, &.{
        .{ .name = "text", .mod = text_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render-2d/tests/render_2d_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "render_2d", .mod = render_2d_mod },
    }, null);

    addModuleTest(b, test_step, "packages/physics/tests/physics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "physics", .mod = physics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/physics-jolt/tests/physics_jolt_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "physics", .mod = physics_mod },
        .{ .name = "physics_jolt", .mod = physics_jolt_mod },
    }, null);
}
