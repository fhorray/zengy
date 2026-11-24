#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_src;

layout(std140, set = 3, binding = 0) uniform BloomDownParams {
    vec4 texel_thresh; // xy=1/src_size, z=threshold, w=first_pass
};

layout(location = 0) out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    vec2 t = texel_thresh.xy;

    vec3 c0 = texture(u_src, uv + vec2(-t.x, -t.y)).rgb;
    vec3 c1 = texture(u_src, uv + vec2( t.x, -t.y)).rgb;
    vec3 c2 = texture(u_src, uv + vec2(-t.x,  t.y)).rgb;
    vec3 c3 = texture(u_src, uv + vec2( t.x,  t.y)).rgb;
    vec3 c4 = texture(u_src, uv).rgb;
    vec3 col = (c0 + c1 + c2 + c3) * 0.125 + c4 * 0.5;

    if (texel_thresh.w > 0.5) {
        // Soft-knee threshold so sky/midtones stay crisp while HDR emissives & sun bloom smoothly.
        float lum = max(max(col.r, col.g), col.b);
        float thresh = texel_thresh.z;
        float knee = thresh * 0.5;
        float soft = clamp(lum - thresh + knee, 0.0, 2.0 * knee);
        soft = (soft * soft) / max(4.0 * knee, 1e-5);
        float contrib = max(soft, lum - thresh) / max(lum, 1e-5);
        col *= contrib;
    }
    frag_color = vec4(col, 1.0);
}
