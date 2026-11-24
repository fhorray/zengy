#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;

layout(std140, set = 1, binding = 0) uniform PbrVertUniforms {
    mat4 model;
    mat4 mvp;
    mat4 light_vp[4];
};

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec4 v_light_pos[4];

void main() {
    vec4 wp = model * vec4(in_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = normalize(mat3(model) * in_normal);
    v_uv = in_uv;
    for (int i = 0; i < 4; ++i) {
        v_light_pos[i] = light_vp[i] * wp;
    }
    gl_Position = mvp * vec4(in_pos, 1.0);
}
