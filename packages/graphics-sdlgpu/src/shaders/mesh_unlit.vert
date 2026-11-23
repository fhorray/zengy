#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;

layout(std140, set = 1, binding = 0) uniform MeshUniforms {
    mat4 mvp;
    vec4 base_color;
};

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec4 v_color;

void main() {
    gl_Position = mvp * vec4(in_pos, 1.0);
    v_normal = in_normal;
    v_uv = in_uv;
    v_color = base_color;
}
