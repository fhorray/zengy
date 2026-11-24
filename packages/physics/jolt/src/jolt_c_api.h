#ifndef ZENGY_JOLT_C_API_H
#define ZENGY_JOLT_C_API_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JoltWorld JoltWorld;

// body_type: 0 = dynamic, 1 = static, 2 = kinematic
// shape_kind: 0 = box (half_x, half_y, half_z), 1 = sphere (radius, _, _), 2 = capsule (radius, half_height, _)
JoltWorld *jolt_world_create(void);
void jolt_world_destroy(JoltWorld *world);

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
);

void jolt_world_destroy_body(JoltWorld *world, uint64_t body_handle);

void jolt_world_set_transform(JoltWorld *world, uint64_t body_handle, const float pos[3], const float rot_euler[3]);
bool jolt_world_get_transform(JoltWorld *world, uint64_t body_handle, float out_pos[3], float out_rot_euler[3]);

void jolt_world_set_velocity(JoltWorld *world, uint64_t body_handle, const float vel[3], const float ang_vel[3]);
bool jolt_world_get_velocity(JoltWorld *world, uint64_t body_handle, float out_vel[3], float out_ang_vel[3]);

void jolt_world_apply_force(JoltWorld *world, uint64_t body_handle, const float force[3]);
void jolt_world_apply_impulse(JoltWorld *world, uint64_t body_handle, const float impulse[3]);

void jolt_world_step(JoltWorld *world, float dt, const float gravity[3]);

bool jolt_world_raycast(
    JoltWorld *world,
    const float origin[3],
    const float dir[3],
    float max_distance,
    uint64_t *out_entity_u64,
    float *out_distance,
    float out_point[3],
    float out_normal[3]
);

#ifdef __cplusplus
}
#endif

#endif // ZENGY_JOLT_C_API_H
