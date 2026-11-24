#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_cur;   // this frame's ray-march: in-scatter (rgb), marched distance (a)
layout(set = 2, binding = 1) uniform sampler2D u_hist;  // previous resolved result (linear filtered)
layout(set = 2, binding = 2) uniform sampler2D u_depth; // scene depth (nearest)

layout(std140, set = 3, binding = 0) uniform VolResolveParams {
    mat4 inv_view_proj;
    mat4 prev_view_proj;
    vec4 cam_pos_max;  // xyz = camera position, w = max_distance
    vec4 size_blend;   // xy = target size in texels, z = weight of the current frame, w = 1 when history is usable
};

layout(location = 0) out vec4 frag_color;

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);
    vec4 cur = texelFetch(u_cur, px, 0);
    if (size_blend.w < 0.5) {
        frag_color = cur;
        return;
    }

    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    float d = textureLod(u_depth, uv, 0.0).r;
    bool sky = d >= 0.9999;
    vec4 wp4 = inv_view_proj * vec4(v_ndc, sky ? 1.0 : d, 1.0);
    vec3 wp = wp4.xyz / max(wp4.w, 1e-5);
    if (sky) {
        // Sky pixels have no surface: reproject the point at the fog horizon along the view ray.
        wp = cam_pos_max.xyz + normalize(wp - cam_pos_max.xyz) * cam_pos_max.w;
    }

    vec4 pc = prev_view_proj * vec4(wp, 1.0);
    vec2 puv = vec2(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    if (pc.w <= 0.0001 || puv.x < 0.0 || puv.x > 1.0 || puv.y < 0.0 || puv.y > 1.0) {
        frag_color = cur;
        return;
    }

    vec4 hist = textureLod(u_hist, puv, 0.0);
    // The marched distance is geometry: a different value means the surface changed, so the history is stale.
    float rel = abs(hist.a - cur.a) / max(cur.a, 0.5);
    if (rel > 0.2) {
        frag_color = cur;
        return;
    }

    // Variance clipping against the 3x3 neighbourhood keeps the history inside what this frame can explain.
    ivec2 max_px = ivec2(size_blend.xy) - ivec2(1);
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec3 s = texelFetch(u_cur, clamp(px + ivec2(x, y), ivec2(0), max_px), 0).rgb;
            m1 += s;
            m2 += s * s;
        }
    }
    vec3 mean = m1 / 9.0;
    vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
    vec3 clipped = clamp(hist.rgb, mean - 1.5 * sigma, mean + 1.5 * sigma);
    frag_color = vec4(mix(clipped, cur.rgb, size_blend.z), cur.a);
}
