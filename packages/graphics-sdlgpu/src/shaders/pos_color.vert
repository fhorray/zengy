#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec4 in_color;

layout(std140, set = 1, binding = 0) uniform FrameUniforms {
    vec4 viewport_and_mode; // x = width, y = height, z = use_pixel_coords (> 0.5), w = unused
};

layout(location = 0) out vec4 v_color;

void main() {
    vec2 pos = in_pos;
    if (viewport_and_mode.z > 0.5) {
        float w = max(viewport_and_mode.x, 1.0);
        float h = max(viewport_and_mode.y, 1.0);
        pos.x = (in_pos.x / w) * 2.0 - 1.0;
        pos.y = 1.0 - (in_pos.y / h) * 2.0;
    }
    gl_Position = vec4(pos, 0.0, 1.0);
    v_color = in_color;
}
