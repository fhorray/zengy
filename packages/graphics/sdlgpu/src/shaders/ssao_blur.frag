#version 450

layout(location = 0) in vec2 v_ndc;

// Half-resolution raw SSAO: r = ambient occlusion, g = contact shadow.
layout(set = 2, binding = 0) uniform sampler2D u_ssao;
// Full-resolution scene depth.
layout(set = 2, binding = 1) uniform sampler2D u_depth;

layout(std140, set = 3, binding = 0) uniform SsaoBlurParams {
    vec4 depth_range; // x = near, y = far (camera projection)
};

layout(location = 0) out vec4 frag_color;

// Linear view-space depth from a [0, 1] projection depth value. Raw depth is hyperbolic in distance,
// so weighting by it gives a different effective tolerance near and far from the camera.
float linearDepth(float d) {
    float n = depth_range.x;
    float f = depth_range.y;
    return n * f / max(f - d * (f - n), 1e-6);
}

// Joint bilateral upsample and 3x3 blur in one pass: the half-resolution AO is read per full-resolution
// pixel, and each tap is weighted by how close its linear depth is to this pixel's linear depth.
void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    float d_c = texture(u_depth, uv).r;
    if (d_c >= 0.9999) {
        frag_color = vec4(1.0);
        return;
    }
    float lin_c = linearDepth(d_c);

    ivec2 ss = textureSize(u_ssao, 0);
    ivec2 max_texel = ss - ivec2(1);
    ivec2 centre = clamp(ivec2(uv * vec2(ss)), ivec2(0), max_texel);

    vec2 sum = vec2(0.0);
    float wsum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            ivec2 t = clamp(centre + ivec2(x, y), ivec2(0), max_texel);
            vec2 s = texelFetch(u_ssao, t, 0).rg;
            // Depth at the texel's own centre, so the tap is compared with the geometry that produced it.
            vec2 suv = (vec2(t) + 0.5) / vec2(ss);
            float lin_s = linearDepth(texture(u_depth, suv).r);
            float rel = abs(lin_s - lin_c) / max(lin_c, 0.1);
            float spatial_w = (x == 0 && y == 0) ? 1.5 : 1.0;
            // Loose tolerance (about 20% depth difference per e-fold): a tighter one rejects most neighbours on
            // curved or grazing surfaces, which leaves the per-pixel AO noise un-averaged and speckled.
            float w = spatial_w * exp(-rel * rel * 25.0);
            sum += s * w;
            wsum += w;
        }
    }

    // Every tap rejected by depth: report no occlusion rather than a value from a different surface.
    if (wsum < 1e-4) {
        frag_color = vec4(1.0);
        return;
    }
    frag_color = vec4(sum / wsum, 1.0, 1.0);
}
