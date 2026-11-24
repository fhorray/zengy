use rapier3d::prelude::*;
use std::collections::HashMap;

pub struct RapierWorld {
    gravity: Vector<f32>,
    integration_parameters: IntegrationParameters,
    physics_pipeline: PhysicsPipeline,
    island_manager: IslandManager,
    broad_phase: DefaultBroadPhase,
    narrow_phase: NarrowPhase,
    rigid_body_set: RigidBodySet,
    collider_set: ColliderSet,
    impulse_joint_set: ImpulseJointSet,
    multibody_joint_set: MultibodyJointSet,
    ccd_solver: CCDSolver,
    query_pipeline: QueryPipeline,
    next_handle: u64,
    handles: HashMap<u64, RigidBodyHandle>,
    entities: HashMap<RigidBodyHandle, u64>,
}

impl RapierWorld {
    fn new() -> Self {
        Self {
            gravity: vector![0.0, -9.81, 0.0],
            integration_parameters: IntegrationParameters::default(),
            physics_pipeline: PhysicsPipeline::new(),
            island_manager: IslandManager::new(),
            broad_phase: DefaultBroadPhase::new(),
            narrow_phase: NarrowPhase::new(),
            rigid_body_set: RigidBodySet::new(),
            collider_set: ColliderSet::new(),
            impulse_joint_set: ImpulseJointSet::new(),
            multibody_joint_set: MultibodyJointSet::new(),
            ccd_solver: CCDSolver::new(),
            query_pipeline: QueryPipeline::new(),
            next_handle: 1,
            handles: HashMap::new(),
            entities: HashMap::new(),
        }
    }
}

#[no_mangle]
pub extern "C" fn rapier_world_create() -> *mut RapierWorld {
    Box::into_raw(Box::new(RapierWorld::new()))
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_destroy(world: *mut RapierWorld) {
    if !world.is_null() {
        drop(Box::from_raw(world));
    }
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_create_body(
    world: *mut RapierWorld,
    entity_u64: u64,
    pos: *const [f32; 3],
    body_type: u8,
    mass: f32,
    linear_damping: f32,
    angular_damping: f32,
    lock_rotation: bool,
    shape_kind: u8,
    dim0: f32,
    dim1: f32,
    dim2: f32,
    friction: f32,
    restitution: f32,
    is_sensor: bool,
) -> u64 {
    if world.is_null() || pos.is_null() {
        return 0;
    }
    let w = &mut *world;
    let p = *pos;

    let mut rb_builder = match body_type {
        1 => RigidBodyBuilder::fixed(),
        2 => RigidBodyBuilder::kinematic_position_based(),
        _ => RigidBodyBuilder::dynamic(),
    }
    .translation(vector![p[0], p[1], p[2]])
    .linear_damping(linear_damping)
    .angular_damping(angular_damping);

    if lock_rotation {
        rb_builder = rb_builder.lock_rotations();
    }

    let rb_handle = w.rigid_body_set.insert(rb_builder.build());

    let mut col_builder = match shape_kind {
        1 => ColliderBuilder::ball(dim0.max(0.01)),
        2 => ColliderBuilder::capsule_y(dim1.max(0.01), dim0.max(0.01)),
        _ => ColliderBuilder::cuboid(dim0.max(0.01), dim1.max(0.01), dim2.max(0.01)),
    }
    .friction(friction)
    .restitution(restitution)
    .sensor(is_sensor);

    if body_type == 0 && mass > 0.0 {
        col_builder = col_builder.mass(mass);
    }

    w.collider_set
        .insert_with_parent(col_builder.build(), rb_handle, &mut w.rigid_body_set);

    let id = w.next_handle;
    w.next_handle += 1;
    w.handles.insert(id, rb_handle);
    w.entities.insert(rb_handle, entity_u64);
    id
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_destroy_body(world: *mut RapierWorld, body_handle: u64) {
    if world.is_null() {
        return;
    }
    let w = &mut *world;
    if let Some(rb) = w.handles.remove(&body_handle) {
        w.entities.remove(&rb);
        w.rigid_body_set.remove(
            rb,
            &mut w.island_manager,
            &mut w.collider_set,
            &mut w.impulse_joint_set,
            &mut w.multibody_joint_set,
            true,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_get_transform(
    world: *mut RapierWorld,
    body_handle: u64,
    out_pos: *mut [f32; 3],
    out_rot_euler: *mut [f32; 3],
) -> bool {
    if world.is_null() || out_pos.is_null() || out_rot_euler.is_null() {
        return false;
    }
    let w = &*world;
    let Some(&rb_handle) = w.handles.get(&body_handle) else {
        return false;
    };
    let Some(rb) = w.rigid_body_set.get(rb_handle) else {
        return false;
    };
    let t = rb.translation();
    *out_pos = [t.x, t.y, t.z];
    let (rx, ry, rz) = rb.rotation().euler_angles();
    *out_rot_euler = [rx, ry, rz];
    true
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_apply_impulse(
    world: *mut RapierWorld,
    body_handle: u64,
    impulse: *const [f32; 3],
) {
    if world.is_null() || impulse.is_null() {
        return;
    }
    let w = &mut *world;
    if let Some(&rb_handle) = w.handles.get(&body_handle) {
        if let Some(rb) = w.rigid_body_set.get_mut(rb_handle) {
            let imp = *impulse;
            rb.apply_impulse(vector![imp[0], imp[1], imp[2]], true);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rapier_world_step(
    world: *mut RapierWorld,
    dt: f32,
    gravity: *const [f32; 3],
) {
    if world.is_null() || gravity.is_null() || dt <= 0.0 {
        return;
    }
    let w = &mut *world;
    let g = *gravity;
    w.gravity = vector![g[0], g[1], g[2]];
    w.integration_parameters.dt = dt;
    w.physics_pipeline.step(
        &w.gravity,
        &w.integration_parameters,
        &mut w.island_manager,
        &mut w.broad_phase,
        &mut w.narrow_phase,
        &mut w.rigid_body_set,
        &mut w.collider_set,
        &mut w.impulse_joint_set,
        &mut w.multibody_joint_set,
        &mut w.ccd_solver,
        Some(&mut w.query_pipeline),
        &(),
        &(),
    );
}
