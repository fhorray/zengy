// Build script for the optional JoltPhysics backend plugin (`official.physics.jolt`).
//
// Kept out of the root build on purpose: `jolt` is only fetched when this package is built
// (`cd packages/physics/jolt && zig build`), so the engine and visual demos never depend on it.
//
// Outputs:
// - `zigeng_physics_jolt` shared library (installed to zig-out/lib)
// - `zig build test` runs the Jolt backend tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeng = b.dependency("zigeng", .{ .target = target, .optimize = optimize });
    const engine_mod = zigeng.module("engine");
    const physics_mod = zigeng.module("physics");

    const jolt_dep = b.dependency("jolt", .{});

    const jolt_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    jolt_c_mod.addIncludePath(jolt_dep.path("."));
    jolt_c_mod.addIncludePath(b.path("src"));
    const jolt_cpp_flags: []const []const u8 = &.{
        "-std=c++17",
        "-DJPH_OBJECT_STREAM",
        "-fno-sanitize=undefined",
    };
    jolt_c_mod.addCSourceFile(.{
        .file = b.path("src/jolt_c_api.cpp"),
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
        .root_source_file = b.path("src/physics_jolt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    physics_jolt_mod.addImport("engine", engine_mod);
    physics_jolt_mod.addImport("physics", physics_mod);
    physics_jolt_mod.addIncludePath(b.path("src"));
    physics_jolt_mod.linkLibrary(jolt_c_lib);

    const jolt_plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin_entry.zig"),
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

    const test_step = b.step("test", "Run physics_jolt backend tests");
    const jolt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/physics_jolt_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "engine", .module = engine_mod },
                .{ .name = "physics", .module = physics_mod },
                .{ .name = "physics_jolt", .module = physics_jolt_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(jolt_tests).step);
}
