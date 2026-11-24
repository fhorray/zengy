#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;

layout(std140, set = 1, binding = 0) uniform ShadowUniforms {
    mat4 light_mvp;
};

void main() {
    gl_Position = light_mvp * vec4(in_pos, 1.0);
}
