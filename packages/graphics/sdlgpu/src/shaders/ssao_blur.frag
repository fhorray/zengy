#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_ssao;

layout(location = 0) out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    vec2 texel = 1.0 / vec2(textureSize(u_ssao, 0));
    vec2 sum = vec2(0.0);
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            sum += texture(u_ssao, uv + vec2(x, y) * texel).rg;
        }
    }
    frag_color = vec4(sum / 9.0, 1.0, 1.0);
}
