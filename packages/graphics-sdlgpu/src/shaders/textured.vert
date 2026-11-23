#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(std140, set = 1, binding = 0) uniform TexturedUniforms {
    vec4 viewport; // x = width, y = height, z/w = unused
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    float w = max(viewport.x, 1.0);
    float h = max(viewport.y, 1.0);
    vec2 ndc = vec2(
        (in_pos.x / w) * 2.0 - 1.0,
        1.0 - (in_pos.y / h) * 2.0
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
