#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_vol;   // scatter target: in-scatter (rgb) and marched distance (a)
layout(set = 2, binding = 1) uniform sampler2D u_depth; // full-res scene depth (nearest)

// Two passes share this shader, selected by `vol_size_dist.w`:
//   0 = transmittance: the HDR target is multiplied by T (blend: dst *= src).
//   1 = scatter:       the HDR target gets in-scatter plus ambient fog colour (additive).
// Applying them as separate passes gives L = L_scene * T + L_scatter without reading the HDR target.
layout(std140, set = 3, binding = 0) uniform VolCompositeParams {
    mat4 inv_view_proj;
    vec4 cam_pos;           // xyz = camera position
    vec4 vol_size_dist;     // xy = scatter target size in texels, z = max_distance, w = pass mode
    vec4 fog_color_density; // xyz = fog colour, w = extinction density
};

layout(location = 0) out vec4 frag_color;

// Scene distance along the view ray, defined exactly as in volumetric_fog.frag so both agree.
float sceneDistance(vec2 ndc, float d, float max_d, vec3 cam) {
    if (d >= 0.9999) return max_d;
    vec4 wp4 = inv_view_proj * vec4(ndc, d, 1.0);
    vec3 wp = wp4.xyz / max(wp4.w, 1e-5);
    return min(length(wp - cam), max_d);
}

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    float max_d = vol_size_dist.z;
    float d = texture(u_depth, uv).r;
    float dist_here = sceneDistance(v_ndc, d, max_d, cam_pos.xyz);
    // Sky is not attenuated: its distance is the fog horizon, which would otherwise darken it entirely.
    float T = (d >= 0.9999) ? 1.0 : exp(-max(fog_color_density.w, 0.0) * max(dist_here, 0.0));

    if (vol_size_dist.w < 0.5) {
        frag_color = vec4(vec3(T), 1.0);
        return;
    }

    vec2 size = vol_size_dist.xy;
    ivec2 max_texel = ivec2(size) - ivec2(1);
    vec2 q = uv * size - 0.5;
    ivec2 base = ivec2(floor(q));
    vec2 f = q - vec2(base);

    // Joint bilateral upsample: the four scatter texels around this pixel are weighted by bilinear
    // distance and by how close their marched distance is to this pixel's scene distance.
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int k = 0; k < 4; ++k) {
        ivec2 o = ivec2(k & 1, k >> 1);
        ivec2 t = clamp(base + o, ivec2(0), max_texel);
        vec4 s = texelFetch(u_vol, t, 0);
        float wx = ((k & 1) == 0) ? (1.0 - f.x) : f.x;
        float wy = ((k >> 1) == 0) ? (1.0 - f.y) : f.y;
        float rel = abs(s.a - dist_here) / max(dist_here, 0.5);
        float w = wx * wy * exp(-rel * rel * 64.0);
        acc += s.rgb * w;
        wsum += w;
    }

    // All taps rejected by depth: fall back to the nearest scatter sample instead of a black hole.
    vec3 scatter = acc / max(wsum, 1e-5);
    if (wsum < 1e-4) {
        ivec2 nearest_t = clamp(ivec2(floor(uv * size)), ivec2(0), max_texel);
        scatter = texelFetch(u_vol, nearest_t, 0).rgb;
    }

    // Only light actually scattered by the lights is added. A flat ambient fog colour here washes out the
    // whole frame, so the colour term is intentionally omitted.
    // Additive blend target: alpha stays zero so the HDR alpha is untouched.
    frag_color = vec4(scatter * cam_pos.w, 0.0);
}
