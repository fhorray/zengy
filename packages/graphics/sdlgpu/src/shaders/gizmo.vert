#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec4 in_color;

layout(std140, set = 1, binding = 0) uniform GizmoUniforms {
    mat4 view_proj;
};

layout(location = 0) out vec4 v_color;

void main() {
    v_color = in_color;
    gl_Position = view_proj * vec4(in_pos, 1.0);
}
