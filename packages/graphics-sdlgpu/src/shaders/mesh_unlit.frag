#version 450

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec4 v_color;

layout(set = 2, binding = 0) uniform sampler2D u_tex;

layout(location = 0) out vec4 frag_color;

void main() {
    vec4 tex = texture(u_tex, v_uv);
    float shade = 0.65 + 0.35 * clamp(dot(normalize(v_normal), normalize(vec3(0.4, 0.8, 0.5))), -1.0, 1.0);
    frag_color = vec4(tex.rgb * v_color.rgb * shade, tex.a * v_color.a);
}
