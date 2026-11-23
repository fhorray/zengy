#include "jolt_c_api.h"

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyLock.h>

#include <algorithm>
#include <cmath>
#include <mutex>

JPH_SUPPRESS_WARNINGS

using namespace JPH;

namespace {

namespace Layers {
    static constexpr ObjectLayer NON_MOVING = 0;
    static constexpr ObjectLayer MOVING = 1;
    static constexpr ObjectLayer NUM_LAYERS = 2;
}

class ObjectLayerPairFilterImpl final : public ObjectLayerPairFilter {
public:
    bool ShouldCollide(ObjectLayer inObject1, ObjectLayer inObject2) const override {
        switch (inObject1) {
        case Layers::NON_MOVING:
            return inObject2 == Layers::MOVING;
        case Layers::MOVING:
            return true;
        default:
            return false;
        }
    }
};

namespace BroadPhaseLayers {
    static constexpr BroadPhaseLayer NON_MOVING(0);
    static constexpr BroadPhaseLayer MOVING(1);
    static constexpr uint NUM_LAYERS(2);
}

class BPLayerInterfaceImpl final : public BroadPhaseLayerInterface {
public:
    BPLayerInterfaceImpl() {
        mObjectToBroadPhase[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
        mObjectToBroadPhase[Layers::MOVING] = BroadPhaseLayers::MOVING;
    }

    uint GetNumBroadPhaseLayers() const override {
        return BroadPhaseLayers::NUM_LAYERS;
    }

    BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer inLayer) const override {
        return mObjectToBroadPhase[inLayer];
    }

#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char *GetBroadPhaseLayerName(BroadPhaseLayer inLayer) const override {
        switch ((BroadPhaseLayer::Type)inLayer) {
        case (BroadPhaseLayer::Type)BroadPhaseLayers::NON_MOVING:
            return "NON_MOVING";
        case (BroadPhaseLayer::Type)BroadPhaseLayers::MOVING:
            return "MOVING";
        default:
            return "INVALID";
        }
    }
#endif

private:
    BroadPhaseLayer mObjectToBroadPhase[Layers::NUM_LAYERS];
};

class ObjectVsBroadPhaseLayerFilterImpl final : public ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(ObjectLayer inLayer1, BroadPhaseLayer inLayer2) const override {
        switch (inLayer1) {
        case Layers::NON_MOVING:
            return inLayer2 == BroadPhaseLayers::MOVING;
        case Layers::MOVING:
            return true;
        default:
            return false;
        }
    }
};

std::once_flag g_jolt_init_once;

void ensure_jolt_global_init() {
    std::call_once(g_jolt_init_once, []() {
        RegisterDefaultAllocator();
        Factory::sInstance = new Factory();
        RegisterTypes();
    });
}

inline BodyID decode_handle(uint64_t handle) {
    if (handle == 0) return BodyID();
    return BodyID(static_cast<uint32_t>(handle - 1));
}

inline uint64_t encode_handle(BodyID id) {
    if (id.IsInvalid()) return 0;
    return static_cast<uint64_t>(id.GetIndexAndSequenceNumber()) + 1;
}

} // namespace

struct JoltWorld {
    TempAllocatorImpl temp_allocator{2 * 1024 * 1024};
    JobSystemThreadPool job_system{cMaxPhysicsJobs, cMaxPhysicsBarriers, 1};
    BPLayerInterfaceImpl bp_layer_interface;
    ObjectVsBroadPhaseLayerFilterImpl obj_vs_bp_filter;
    ObjectLayerPairFilterImpl obj_pair_filter;
    PhysicsSystem physics_system;
    bool broadphase_dirty = false;

    JoltWorld() {
        const uint cMaxBodies = 4096;
        const uint cNumBodyMutexes = 0;
        const uint cMaxBodyPairs = 4096;
        const uint cMaxContactConstraints = 2048;

        physics_system.Init(
            cMaxBodies,
            cNumBodyMutexes,
            cMaxBodyPairs,
            cMaxContactConstraints,
            bp_layer_interface,
            obj_vs_bp_filter,
            obj_pair_filter
        );
    }
};

extern "C" {

JoltWorld *jolt_world_create(void) {
    ensure_jolt_global_init();
    return new JoltWorld();
}

void jolt_world_destroy(JoltWorld *world) {
    delete world;
}

uint64_t jolt_world_create_body(
    JoltWorld *world,
    uint64_t entity_u64,
    const float pos[3],
    uint8_t body_type,
    float mass,
    float linear_damping,
    float angular_damping,
    bool lock_rotation,
    uint8_t shape_kind,
    float dim0,
    float dim1,
    float dim2,
    float friction,
    float restitution,
    bool is_sensor
) {
    if (!world) return 0;

    ShapeRefC shape;
    if (shape_kind == 1) {
        shape = new SphereShape(std::max(0.01f, dim0));
    } else if (shape_kind == 2) {
        shape = new CapsuleShape(std::max(0.01f, dim1), std::max(0.01f, dim0));
    } else {
        shape = new BoxShape(Vec3(std::max(0.01f, dim0), std::max(0.01f, dim1), std::max(0.01f, dim2)));
    }

    EMotionType motion = EMotionType::Dynamic;
    ObjectLayer layer = Layers::MOVING;
    EActivation activation = EActivation::Activate;
    if (body_type == 1) {
        motion = EMotionType::Static;
        layer = Layers::NON_MOVING;
        activation = EActivation::DontActivate;
    } else if (body_type == 2) {
        motion = EMotionType::Kinematic;
        layer = Layers::MOVING;
    }

    BodyCreationSettings settings(
        shape,
        RVec3(pos[0], pos[1], pos[2]),
        Quat::sIdentity(),
        motion,
        layer
    );
    settings.mUserData = entity_u64;
    settings.mFriction = friction;
    settings.mRestitution = restitution;
    settings.mIsSensor = is_sensor;
    settings.mLinearDamping = linear_damping;
    settings.mAngularDamping = angular_damping;
    if (motion == EMotionType::Dynamic && mass > 0.0f) {
        settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = mass;
    }
    if (lock_rotation) {
        settings.mAllowedDOFs = EAllowedDOFs::TranslationX | EAllowedDOFs::TranslationY | EAllowedDOFs::TranslationZ;
    }

    BodyInterface &bi = world->physics_system.GetBodyInterface();
    BodyID id = bi.CreateAndAddBody(settings, activation);
    if (id.IsInvalid()) return 0;

    world->broadphase_dirty = true;
    return encode_handle(id);
}

void jolt_world_destroy_body(JoltWorld *world, uint64_t body_handle) {
    if (!world) return;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    bi.RemoveBody(id);
    bi.DestroyBody(id);
}

void jolt_world_set_transform(JoltWorld *world, uint64_t body_handle, const float pos[3], const float rot_euler[3]) {
    if (!world) return;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    Quat q = Quat::sEulerAngles(Vec3(rot_euler[0], rot_euler[1], rot_euler[2]));
    bi.SetPositionAndRotation(id, RVec3(pos[0], pos[1], pos[2]), q, EActivation::Activate);
}

bool jolt_world_get_transform(JoltWorld *world, uint64_t body_handle, float out_pos[3], float out_rot_euler[3]) {
    if (!world) return false;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return false;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    if (!bi.IsAdded(id)) return false;
    RVec3 p;
    Quat q;
    bi.GetPositionAndRotation(id, p, q);
    out_pos[0] = static_cast<float>(p.GetX());
    out_pos[1] = static_cast<float>(p.GetY());
    out_pos[2] = static_cast<float>(p.GetZ());
    Vec3 euler = q.GetEulerAngles();
    out_rot_euler[0] = euler.GetX();
    out_rot_euler[1] = euler.GetY();
    out_rot_euler[2] = euler.GetZ();
    return true;
}

void jolt_world_set_velocity(JoltWorld *world, uint64_t body_handle, const float vel[3], const float ang_vel[3]) {
    if (!world) return;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    bi.SetLinearAndAngularVelocity(id, Vec3(vel[0], vel[1], vel[2]), Vec3(ang_vel[0], ang_vel[1], ang_vel[2]));
}

bool jolt_world_get_velocity(JoltWorld *world, uint64_t body_handle, float out_vel[3], float out_ang_vel[3]) {
    if (!world) return false;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return false;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    if (!bi.IsAdded(id)) return false;
    Vec3 v = bi.GetLinearVelocity(id);
    Vec3 av = bi.GetAngularVelocity(id);
    out_vel[0] = v.GetX();
    out_vel[1] = v.GetY();
    out_vel[2] = v.GetZ();
    out_ang_vel[0] = av.GetX();
    out_ang_vel[1] = av.GetY();
    out_ang_vel[2] = av.GetZ();
    return true;
}

void jolt_world_apply_force(JoltWorld *world, uint64_t body_handle, const float force[3]) {
    if (!world) return;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    bi.AddForce(id, Vec3(force[0], force[1], force[2]));
}

void jolt_world_apply_impulse(JoltWorld *world, uint64_t body_handle, const float impulse[3]) {
    if (!world) return;
    BodyID id = decode_handle(body_handle);
    if (id.IsInvalid()) return;
    BodyInterface &bi = world->physics_system.GetBodyInterface();
    bi.AddImpulse(id, Vec3(impulse[0], impulse[1], impulse[2]));
}

void jolt_world_step(JoltWorld *world, float dt, const float gravity[3]) {
    if (!world || dt <= 0.0f) return;
    if (world->broadphase_dirty) {
        world->physics_system.OptimizeBroadPhase();
        world->broadphase_dirty = false;
    }
    world->physics_system.SetGravity(Vec3(gravity[0], gravity[1], gravity[2]));
    int collision_steps = (dt > (1.0f / 55.0f)) ? std::min(4, std::max(1, static_cast<int>(std::ceil(dt / (1.0f / 60.0f))))) : 1;
    world->physics_system.Update(dt, collision_steps, &world->temp_allocator, &world->job_system);
}

bool jolt_world_raycast(
    JoltWorld *world,
    const float origin[3],
    const float dir[3],
    float max_distance,
    uint64_t *out_entity_u64,
    float *out_distance,
    float out_point[3],
    float out_normal[3]
) {
    if (!world || max_distance <= 0.0f) return false;
    if (world->broadphase_dirty) {
        world->physics_system.OptimizeBroadPhase();
        world->broadphase_dirty = false;
    }

    Vec3 d(dir[0], dir[1], dir[2]);
    float len = d.Length();
    if (len <= 1e-6f) return false;
    Vec3 dir_norm = d / len;

    RRayCast ray(RVec3(origin[0], origin[1], origin[2]), dir_norm * max_distance);
    RayCastResult hit;
    if (!world->physics_system.GetNarrowPhaseQuery().CastRay(ray, hit)) {
        return false;
    }

    BodyLockRead lock(world->physics_system.GetBodyLockInterface(), hit.mBodyID);
    if (!lock.Succeeded()) return false;
    const Body &body = lock.GetBody();

    RVec3 hit_pos = ray.GetPointOnRay(hit.mFraction);
    Vec3 normal = body.GetWorldSpaceSurfaceNormal(hit.mSubShapeID2, hit_pos);

    if (out_entity_u64) *out_entity_u64 = body.GetUserData();
    if (out_distance) *out_distance = hit.mFraction * max_distance;
    if (out_point) {
        out_point[0] = static_cast<float>(hit_pos.GetX());
        out_point[1] = static_cast<float>(hit_pos.GetY());
        out_point[2] = static_cast<float>(hit_pos.GetZ());
    }
    if (out_normal) {
        out_normal[0] = normal.GetX();
        out_normal[1] = normal.GetY();
        out_normal[2] = normal.GetZ();
    }
    return true;
}

} // extern "C"
