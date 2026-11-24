#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_hdr;
layout(set = 2, binding = 1) uniform sampler2D u_bloom;
layout(set = 2, binding = 2) uniform sampler2D u_exposure;

layout(std140, set = 3, binding = 0) uniform PostFxParams {
    vec4 bloom_tint_int;   // xyz=tint, w=intensity
    vec4 grade_params;     // x=exposure_ev, y=contrast, z=saturation, w=tonemap_mode (0..4)
    vec4 grade_tint_look;  // xyz=filter_tint, w=agx_punchy (0/1)
    vec4 vignette_params;  // xyz=color, w=intensity (0=off)
    vec4 vignette_extra;   // x=smoothness, y=use_auto_exp
};

layout(location = 0) out vec4 frag_color;

float linearToSrgb1(float c) {
    c = clamp(c, 0.0, 1.0);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

vec3 linearToSrgb(vec3 c) {
    return vec3(linearToSrgb1(c.r), linearToSrgb1(c.g), linearToSrgb1(c.b));
}

vec3 acesFit(vec3 x) {
    return (x * (x + 0.0245786) - 0.000090537) / (x * (0.983729 * x + 0.4329510) + 0.238081);
}

vec3 tonemapACES(vec3 c) {
    const mat3 input_mat = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777
    );
    const mat3 output_mat = mat3(
         1.60475, -0.10208, -0.00327,
        -0.53108,  1.10813, -0.07276,
        -0.07367, -0.00605,  1.07602
    );
    return clamp(output_mat * acesFit(input_mat * max(c * 1.4, vec3(0.0))), 0.0, 1.0);
}

vec3 tonemapPbrNeutral(vec3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;
    float x = min(color.r, min(color.g, color.b));
    float offset = (x < 0.08) ? (x - 6.25 * x * x) : 0.04;
    color -= offset;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression) return color;
    float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;
    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, vec3(newPeak), g);
}

vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5 * x4 * x2
           - 40.14 * x4 * x
           + 31.96 * x4
           - 6.868 * x2 * x
           + 0.4298 * x2
           + 0.1191 * x
           - 0.00232;
}

vec3 tonemapAgX(vec3 val, bool punchy) {
    const mat3 agx_mat = mat3(
        0.842479062253094,  0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772,  0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104
    );
    const mat3 agx_mat_inv = mat3(
        1.19687900512017,  -0.0528968517574562, -0.0529716355144438,
       -0.0980208811401368, 1.15190312990417,   -0.0980434501171241,
       -0.0990297440797205, -0.0989611768448433, 1.15107367264116
    );
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    val = agx_mat * max(val, vec3(1e-6));
    val = clamp(log2(val), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    val = agxDefaultContrastApprox(val);
    val = clamp(agx_mat_inv * val, 0.0, 1.0);
    if (punchy) {
        float luma = dot(val, vec3(0.2126, 0.7152, 0.0722));
        val = pow(val, vec3(1.18));
        val = mix(vec3(luma), val, 1.22);
    }
    return pow(clamp(val, 0.0, 1.0), vec3(2.2));
}

float interleavedGradientNoise(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);

    vec3 hdr = texture(u_hdr, uv).rgb;
    vec3 bloom = texture(u_bloom, uv).rgb;
    hdr += bloom * bloom_tint_int.rgb * bloom_tint_int.w;

    float ev = grade_params.x;
    if (vignette_extra.y > 0.5) {
        ev += texelFetch(u_exposure, ivec2(0, 0), 0).r;
    }
    vec3 col = hdr * exp2(-ev);

    int mode = int(grade_params.w + 0.5);
    if (mode == 1) {
        col = col / (1.0 + col);
    } else if (mode == 2) {
        col = tonemapACES(col);
    } else if (mode == 3) {
        col = tonemapAgX(col, grade_tint_look.w > 0.5);
    } else if (mode == 4) {
        col = tonemapPbrNeutral(col);
    } else {
        col = clamp(col, 0.0, 1.0);
    }

    col = (col - 0.5) * grade_params.y + 0.5;
    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(luma), col, grade_params.z) * grade_tint_look.rgb;

    if (vignette_params.w > 0.001) {
        vec2 d = uv - 0.5;
        float vig = smoothstep(0.75, 0.75 - max(vignette_extra.x, 0.05), length(d) * (1.0 + vignette_params.w));
        col = mix(vignette_params.rgb, col, vig);
    }

    vec3 srgb = linearToSrgb(col);
    // Triangular screen-space dither to eliminate 8-bit sky gradient banding.
    float dither = (interleavedGradientNoise(gl_FragCoord.xy) - 0.5) / 255.0;
    frag_color = vec4(clamp(srgb + dither, 0.0, 1.0), 1.0);
}
