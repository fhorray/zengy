#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;

layout(std140, set = 1, binding = 0) uniform ShadowUniforms {
    mat4 light_mvp;
};

// Position must match bit-for-bit with pbr.vert: the depth prepass feeds the lit pass's depth test.
invariant gl_Position;

// UV is forwarded for alpha-masked casters (shadow_mask.frag); the opaque variant ignores it.
layout(location = 0) out vec2 v_uv;

void main() {
    v_uv = in_uv;
    gl_Position = light_mvp * vec4(in_pos, 1.0);
}
