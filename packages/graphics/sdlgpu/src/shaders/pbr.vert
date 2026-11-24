#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;

layout(std140, set = 1, binding = 0) uniform PbrVertUniforms {
    mat4 model;
    mat4 normal_matrix;
    mat4 mvp;
    mat4 light_vp[4];
    vec4 shadow_offset;  // x = offset in shadow texels at grazing angles (0 = off)
    vec4 cascade_texel;  // world-space size of one shadow texel per cascade
    vec4 to_sun;         // xyz = direction to the sun
};

// Position must match bit-for-bit with shadow.vert, because the lit pass depth-tests against the prepass.
invariant gl_Position;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec4 v_light_pos[4];

void main() {
    vec4 wp = model * vec4(in_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = normalize(mat3(normal_matrix) * in_normal);
    v_uv = in_uv;
    // Normal-offset shadow lookup: move the receiver along its normal, most at grazing angles, so the depth bias
    // can stay small. With shadow_offset.x == 0 the offset is exactly zero.
    float n_dot_l = clamp(dot(v_world_normal, to_sun.xyz), 0.0, 1.0);
    float slope = sqrt(max(1.0 - n_dot_l * n_dot_l, 0.0));
    for (int i = 0; i < 4; ++i) {
        vec3 offset = v_world_normal * (shadow_offset.x * cascade_texel[i] * slope);
        v_light_pos[i] = light_vp[i] * vec4(wp.xyz + offset, 1.0);
    }
    gl_Position = mvp * vec4(in_pos, 1.0);
}
