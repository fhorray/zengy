#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_ssao;
layout(set = 2, binding = 1) uniform sampler2D u_depth;

layout(location = 0) out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    vec2 texel = 1.0 / vec2(textureSize(u_ssao, 0));
    float d_center = texture(u_depth, uv).r;
    vec2 sum = vec2(0.0);
    float total_w = 0.0;
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            vec2 suv = uv + vec2(x, y) * texel;
            vec2 s = texture(u_ssao, suv).rg;
            float d_s = texture(u_depth, suv).r;
            float depth_w = exp(-abs(d_s - d_center) * 350.0);
            float spatial_w = (x == 0 && y == 0) ? 1.5 : 1.0;
            float w = depth_w * spatial_w;
            sum += s * w;
            total_w += w;
        }
    }
    frag_color = vec4(sum / max(total_w, 1e-4), 1.0, 1.0);
}
