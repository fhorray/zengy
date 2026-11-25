#version 450

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_world_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in vec4 v_light_pos[4];

layout(set = 2, binding = 0) uniform sampler2D u_base_color_tex;
layout(set = 2, binding = 1) uniform sampler2D u_normal_tex;
layout(set = 2, binding = 2) uniform sampler2D u_mr_tex;
layout(set = 2, binding = 3) uniform sampler2DShadow u_shadow_tex;
layout(set = 2, binding = 4) uniform sampler2D u_prefilter_env;
layout(set = 2, binding = 5) uniform sampler2D u_brdf_lut;
layout(set = 2, binding = 6) uniform sampler2D u_ssao_tex;
layout(set = 2, binding = 7) uniform sampler2DShadow u_local_shadow_tex;
layout(set = 2, binding = 8) uniform sampler2D u_ao_tex;
layout(set = 2, binding = 9) uniform sampler2D u_emissive_tex;
layout(set = 2, binding = 10) uniform sampler2D u_shadow_raw; // same depth as u_shadow_tex, read without comparison (PCSS blocker search)
layout(set = 2, binding = 11) uniform sampler2D u_local_shadow_raw;
layout(set = 2, binding = 12) uniform sampler2D u_probe_environment;
layout(set = 2, binding = 13) uniform sampler2D u_ltc; // same for the local shadow atlas

struct GpuPointLight {
    vec4 pos_range;  // xyz=pos, w=range
    vec4 col_radius; // rgb=color*scale, w=shadow_tile (-1 = none)
    vec4 shadow_params; // x=light source radius in metres (PCSS, near-field softening), y=layer mask, z=specular scale
};

struct GpuSpotLight {
    vec4 pos_range;     // xyz=pos, w=range
    vec4 dir_cos_inner; // xyz=dir, w=cos_inner
    vec4 col_cos_outer; // rgb=color*scale, w=cos_outer
    vec4 shadow_params; // x=shadow_tile (-1=none), y=bias, z=light source radius in metres (PCSS), w=layer mask
};

struct GpuRectLight {
    vec4 pos_range; // xyz=pos, w=range
    vec4 dir_two;   // xyz=dir, w=two_sided
    vec4 right_hx;  // xyz=right, w=half_width
    vec4 up_hy;     // xyz=up, w=half_height
    vec4 col_pad;   // rgb=color*scale, w=layer mask
};

struct GpuReflectionProbe {
    vec4 pos_int;    // xyz=pos, w=intensity
    vec4 half_blend; // xyz=half_extents, w=blend_distance
    vec4 sky_box;    // rgb=sky_tint, w=box_projection
    vec4 ground_pad; // rgb=ground_tint, w=diffuse scale
    vec4 environment_info; // x=authored map, y=max mip
};


struct DynamicGiProbe {
    vec4 lobes[6];
    vec4 moments[6];
    vec4 offset_validity;
};

layout(std430, set = 2, binding = 14) readonly buffer ClusterLightsBuffer {
    GpuPointLight c_points[256];
    GpuSpotLight c_spots[256];
    GpuRectLight c_rects[64];
    GpuReflectionProbe c_probes[32];
    vec4 gi_origin_enabled;
    vec4 gi_spacing;
    DynamicGiProbe c_gi[64];
};

layout(std430, set = 2, binding = 15) readonly buffer ClusterGridBuffer {
    uvec4 clusters[];
};

layout(std430, set = 2, binding = 16) readonly buffer ClusterIndicesBuffer {
    uint cluster_indices[];
};

layout(std430, set = 2, binding = 17) readonly buffer LocalShadowBuffer {
    mat4 local_shadow_vp[16];
    vec4 local_atlas_rect[16]; // x, y, w, h in [0,1]
    vec4 local_shadow_info[16]; // x = tan(half fov), y = near, z = far
};

layout(std140, set = 3, binding = 0) uniform PbrFragUniforms {
    vec4 camera_pos_fog;
    vec4 base_color;
    vec4 emissive_weight;
    vec4 mat_params;       // x=metallic, y=roughness, z=reflectance, w=ao_strength
    vec4 mat_flags;        // x=unlit, y=normal_scale, z=shadow_bias, w=shadows_enabled
    vec4 ambient_sky;      // xyz=ambient, w=fog_density
    vec4 fog_color_start;  // xyz=fog_color, w=fog_start
    vec4 dir_light_dir;    // xyz=to_sun, w=illuminance_scale
    vec4 dir_light_col;    // xyz=color, w=point_count
    vec4 point_pos[4];
    vec4 point_col[4];
    vec4 sky_zenith;       // xyz=sky_tint, w=spot_count
    vec4 sky_horizon;      // xyz=horizon_tint, w=max_env_mip
    vec4 spot_pos[2];
    vec4 spot_dir[2];
    vec4 spot_col[2];
    vec4 sh_coeffs[9];     // xyz=SH9 RGB; [0].w=ssao_on, [1].w=inv_screen_w, [2].w=inv_screen_h, [3].w=contact_on
    vec4 camera_fwd_overlap; // xyz=camera_forward, w=overlap_proportion
    vec4 cascade_splits;     // 4 exponential cascade far bounds
    vec4 cascade_depth_ranges; // 4 cascade depth ranges in metres
    vec4 cluster_factors;    // x=z_scale, y=z_bias, z=clustered_on, w=0
    vec4 probe_volumetric;   // x=probe_count, y=pcss_on, z=vol_fog_on, w=vol_scattering
    vec4 layer_info;         // x=receiver layer mask, y=sun layer mask (24-bit masks carried as floats)
    vec4 cascade_info;       // x=number of cascades rendered this frame (0..4), y=PCSS light size (tangent of half-angle), z=minimum depth bias in metres, w=1 for blocker-search PCSS on local lights
};

layout(location = 0) out vec4 frag_color;
#ifdef ZENGY_SCREEN_TRANSPORT
layout(location = 1) out vec4 out_surface;
layout(location = 2) out vec4 out_diffuse;
layout(location = 3) out vec4 out_specular;
vec2 encodeNormal(vec3 n) {
    n /= max(abs(n.x)+abs(n.y)+abs(n.z),1e-6);
    return n.z >= 0.0 ? n.xy : (1.0-abs(n.yx))*mix(vec2(-1),vec2(1),greaterThanEqual(n.xy,vec2(0)));
}
float packRgb(vec3 v) {
    uvec3 q=uvec3(round(clamp(v,0.0,1.0)*255.0));
    return float(q.x|(q.y<<8)|(q.z<<16));
}
#endif

const float PI = 3.14159265359;

float distributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * denom * denom, 0.0001);
}

float geometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / max(NdotV * (1.0 - k) + k, 0.0001);
}

float geometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    return geometrySchlickGGX(max(dot(N, V), 0.0), roughness) *
           geometrySchlickGGX(max(dot(N, L), 0.0), roughness);
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 evalSH9Diffuse(vec3 n) {
    float b[9];
    b[0] = 0.282095;
    b[1] = 0.488603 * n.y;
    b[2] = 0.488603 * n.z;
    b[3] = 0.488603 * n.x;
    b[4] = 1.092548 * n.x * n.y;
    b[5] = 1.092548 * n.y * n.z;
    b[6] = 0.315392 * (3.0 * n.z * n.z - 1.0);
    b[7] = 1.092548 * n.x * n.z;
    b[8] = 0.546274 * (n.x * n.x - n.y * n.y);
    vec3 res = vec3(0.0);
    for (int i = 0; i < 9; ++i) {
        res += sh_coeffs[i].xyz * b[i];
    }
    return max(res, vec3(0.0));
}

vec2 equirectUv(vec3 d) {
    float u = atan(d.x, -d.z) / (2.0 * PI) + 0.5;
    float v = acos(clamp(d.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

vec3 perturbNormal(vec3 N, vec3 V, vec2 uv) {
    vec3 map_n = texture(u_normal_tex, uv).xyz * 2.0 - 1.0;
    if (length(map_n) < 0.01) return N;
    map_n.xy *= mat_flags.y;
    vec3 dp1 = dFdx(v_world_pos);
    vec3 dp2 = dFdy(v_world_pos);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);
    vec3 dp2perp = cross(dp2, N);
    vec3 dp1perp = cross(N, dp1);
    vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float invmax = inversesqrt(max(dot(T, T), dot(B, B)) + 1e-8);
    mat3 TBN = mat3(T * invmax, B * invmax, N);
    return normalize(TBN * map_n);
}

bool layersOverlap(float light_mask, float mesh_mask) {
    // Masks are exact integers below 2^24, so the float converts exactly; adding 0.5 would round 2^24 - 1 up.
    return (uint(light_mask) & uint(mesh_mask)) != 0u;
}

float ign(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec2 vogelDisk(int idx, int count, float phi) {
    float r = sqrt((float(idx) + 0.5) / float(count));
    float theta = float(idx) * 2.39996323 + phi;
    return vec2(cos(theta), sin(theta)) * r;
}

float sampleCascadePCF(int c_idx, vec3 N, vec3 L, float rot, float view_depth) {
    vec4 light_pos = v_light_pos[c_idx];
    vec3 proj = light_pos.xyz / max(light_pos.w, 0.0001);
    vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
    if (uv.x < 0.01 || uv.x > 0.99 || uv.y < 0.01 || uv.y > 0.99 || proj.z > 1.0 || proj.z < 0.0) {
        return -1.0;
    }
    vec2 q_min = vec2((c_idx & 1) * 0.5, (c_idx >> 1) * 0.5);
    vec2 q_max = q_min + vec2(0.5, 0.5);
    uv = mix(q_min, q_max, uv);
    float slope = 1.0 - max(dot(N, L), 0.0);
    float depth_range = max(cascade_depth_ranges[c_idx], 1.0);
    float bias_m = max(cascade_info.z, mat_flags.z * 8.0) * (1.0 + slope * 3.5) * (1.0 + float(c_idx) * 0.65);
    float bias = bias_m / depth_range;
    vec2 texel = 1.0 / vec2(textureSize(u_shadow_tex, 0));
    float pcss_boost = (probe_volumetric.y > 0.5) ? (1.0 + clamp(view_depth / 30.0, 0.0, 1.5)) : 1.0;
    float radius_texels = (2.2 - float(c_idx) * 0.2) * pcss_boost;
    int taps = (c_idx < 2) ? 12 : 8;
    if (probe_volumetric.y > 1.5) {
        // PCSS: find blockers around the receiver, then widen the filter with the receiver-blocker distance.
        // Cascade extents mirror computeCascade on the CPU: half_ext = max(far * 1.25, 12), 1024 texels across.
        float texel_world = 2.0 * max(cascade_splits[c_idx] * 1.25, 12.0) / 1024.0;
        float blocker_sum = 0.0;
        float blocker_n = 0.0;
        for (int i = 0; i < 12; ++i) {
            vec2 o = vogelDisk(i, 12, rot) * 6.0 * texel;
            vec2 suv = clamp(uv + o, q_min + texel, q_max - texel);
            float r = textureLod(u_shadow_raw, suv, 0.0).r;
            if (r < proj.z - bias) {
                blocker_sum += r;
                blocker_n += 1.0;
            }
        }
        if (blocker_n < 0.5) return 1.0;
        float depth_gap_m = (proj.z - blocker_sum / blocker_n) * depth_range;
        // cascade_info.y is the tangent of the light's apparent half-size; larger values give wider penumbrae.
        radius_texels = clamp(depth_gap_m * cascade_info.y / texel_world, 1.0, 14.0);
        taps = 16;
    }
    float shadow = 0.0;
    for (int i = 0; i < taps; ++i) {
        vec2 o = vogelDisk(i, taps, rot) * radius_texels * texel;
        vec2 suv = clamp(uv + o, q_min + texel, q_max - texel);
        shadow += texture(u_shadow_tex, vec3(suv, proj.z - bias));
    }
    return shadow / float(taps);
}

float sampleShadowCSM(vec3 N, vec3 L, float view_depth) {
    // Only cascades rendered this frame are sampled; the rest of the atlas is never read.
    int count = clamp(int(cascade_info.x + 0.5), 0, 4);
    if (mat_flags.w < 0.5 || count == 0) return 1.0;
    float max_dist = max(cascade_splits[count - 1], 1.0);
    if (view_depth > max_dist) return 1.0;

    int idx = 0;
    for (int i = 0; i < 3; ++i) {
        if (i < count - 1 && view_depth > cascade_splits[i]) idx = i + 1;
    }

    float rot = ign(gl_FragCoord.xy) * 6.2831853;
    float lit = sampleCascadePCF(idx, N, L, rot, view_depth);
    if (lit < 0.0) {
        for (int k = idx + 1; k < count; ++k) {
            lit = sampleCascadePCF(k, N, L, rot, view_depth);
            if (lit >= 0.0) break;
        }
        if (lit < 0.0) lit = 1.0;
    } else if (idx < count - 1) {
        float prev_b = (idx == 0) ? 0.0 : cascade_splits[idx - 1];
        float split = cascade_splits[idx];
        float band = max((split - prev_b) * clamp(camera_fwd_overlap.w, 0.02, 0.4), 0.5);
        float t = clamp((view_depth - (split - band)) / band, 0.0, 1.0);
        if (t > 0.0) {
            float next_lit = sampleCascadePCF(idx + 1, N, L, rot, view_depth);
            if (next_lit >= 0.0) lit = mix(lit, next_lit, t);
        }
    }

    float fade = clamp((view_depth - max_dist * 0.85) / (max_dist * 0.15), 0.0, 1.0);
    return mix(lit, 1.0, fade);
}

// View-space distance of a perspective shadow depth value (near/far from local_shadow_info).
float localLinearDepth(float z, float near_d, float far_d) {
    return near_d * far_d / max(far_d - z * (far_d - near_d), 1e-4);
}

float sampleLocalTile(int tile_idx, vec3 world_pos, float bias, float rot, float light_size) {
    if (tile_idx < 0 || tile_idx >= 16) return 1.0;
    vec4 lp = local_shadow_vp[tile_idx] * vec4(world_pos, 1.0);
    if (lp.w <= 0.001) return 1.0;
    vec3 proj = lp.xyz / lp.w;
    vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || proj.z < 0.0 || proj.z > 1.0) {
        return 1.0;
    }
    vec4 rect = local_atlas_rect[tile_idx];
    vec2 suv = rect.xy + uv * rect.zw;
    vec2 texel = 1.0 / vec2(textureSize(u_local_shadow_tex, 0));
    // Filter radius follows the tile's share of the atlas, so large and small tiles blur the same angle.
    float radius_texels = 1.6 * (rect.z / 0.25);
    int taps = 6;
    if (cascade_info.w > 0.5 && light_size > 0.0) {
        // PCSS: the blocker search finds how far the occluders are, and the penumbra follows from the light size.
        vec4 info = local_shadow_info[tile_idx];
        float tile_px = rect.z * float(textureSize(u_local_shadow_tex, 0).x);
        float d_r = localLinearDepth(proj.z, info.y, info.z);
        float texel_world = max(2.0 * d_r * info.x / tile_px, 1e-5);
        float search = clamp(light_size * (d_r - info.y) / max(d_r, 0.01) / texel_world, 2.0, 10.0);
        float blocker_sum = 0.0;
        float blocker_n = 0.0;
        for (int i = 0; i < 12; ++i) {
            vec2 o = vogelDisk(i, 12, rot) * search * texel;
            vec2 cuv = clamp(suv + o, rect.xy + texel, rect.xy + rect.zw - texel);
            float r = textureLod(u_local_shadow_raw, cuv, 0.0).r;
            if (r < proj.z - bias) {
                blocker_sum += localLinearDepth(r, info.y, info.z);
                blocker_n += 1.0;
            }
        }
        if (blocker_n < 0.5) return 1.0;
        float d_b = blocker_sum / blocker_n;
        radius_texels = clamp((d_r - d_b) * light_size / max(d_b, 0.01) / texel_world, 1.0, 12.0);
        taps = 16;
    }
    float s = 0.0;
    for (int i = 0; i < taps; ++i) {
        vec2 o = vogelDisk(i, taps, rot) * radius_texels * texel;
        vec2 cuv = clamp(suv + o, rect.xy + texel, rect.xy + rect.zw - texel);
        s += texture(u_local_shadow_tex, vec3(cuv, proj.z - bias));
    }
    return s / float(taps);
}

float samplePointShadow(int base_tile, vec3 light_pos, vec3 N, vec3 L, float rot, float light_size) {
    if (base_tile < 0 || base_tile > 10) return 1.0;
    vec3 d = v_world_pos - light_pos;
    vec3 ad = abs(d);
    int face = 0;
    if (ad.x >= ad.y && ad.x >= ad.z) {
        face = (d.x > 0.0) ? 0 : 1;
    } else if (ad.y >= ad.x && ad.y >= ad.z) {
        face = (d.y > 0.0) ? 2 : 3;
    } else {
        face = (d.z > 0.0) ? 4 : 5;
    }
    float slope = 1.0 - max(dot(N, L), 0.0);
    float bias = 0.0015 + slope * 0.0045;
    return sampleLocalTile(base_tile + face, v_world_pos, bias, rot, light_size);
}

// `spec_scale` 0 makes a light diffuse-only (bounce lights must not leave sharp specular glints on glossy floors).
vec3 evalLight(vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness, vec3 L, vec3 radiance, float spec_scale) {
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) return vec3(0.0);
    vec3 half_vector = V + L;
    vec3 H = half_vector * inversesqrt(max(dot(half_vector, half_vector), 1e-12));
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
    if (spec_scale <= 0.0) return kD * albedo / PI * radiance * NdotL;
    float NDF = distributionGGX(N, H, roughness);
    float G = geometrySmith(N, V, L, roughness);
    vec3 spec = (NDF * G * F) / max(4.0 * max(dot(N, V), 0.0) * NdotL, 0.0001);
    return (kD * albedo / PI + spec * spec_scale) * radiance * NdotL;
}


// Six-lobe diffuse irradiance and directional visibility; grid is updated by CPU ray queries.
int giSector(vec3 d) {
    vec3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) return d.x >= 0.0 ? 0 : 1;
    if (a.y >= a.z) return d.y >= 0.0 ? 2 : 3;
    return d.z >= 0.0 ? 4 : 5;
}
vec4 sampleDynamicGi(vec3 p, vec3 n) {
    if (gi_origin_enabled.w <= 0.0 || any(isnan(gi_origin_enabled)) || any(isinf(gi_origin_enabled))) return vec4(0.0);
    if (gi_spacing.w > 0.0 && !layersOverlap(gi_spacing.w, layer_info.x)) return vec4(0.0);
    if (any(isnan(p)) || any(isinf(p)) || any(isnan(n)) || any(isinf(n)) || any(lessThanEqual(gi_spacing.xyz, vec3(0.01))) || any(isnan(gi_spacing.xyz)) || any(isinf(gi_spacing.xyz))) return vec4(0.0);
    float nlen2 = dot(n,n);
    if (nlen2 <= 1e-12) return vec4(0.0);
    vec3 n2 = n*n / nlen2;
    vec3 q = (p - gi_origin_enabled.xyz) / gi_spacing.xyz;
    if (any(lessThan(q, vec3(-0.05))) || any(greaterThan(q, vec3(3.05)))) return vec4(0.0);
    q = clamp(q, vec3(0.0), vec3(3.0));
    ivec3 base = min(ivec3(floor(q)), ivec3(2));
    vec3 f = q - vec3(base);
    vec3 sum_rgb = vec3(0.0);
    float sum_w = 0.0;
    for (int i = 0; i < 8; ++i) {
        ivec3 o = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        ivec3 c = base + o;
        int idx = c.x + 4*c.y + 16*c.z;
        vec3 w3 = mix(1.0-f, f, vec3(o));
        float w = w3.x*w3.y*w3.z*c_gi[idx].offset_validity.w;
        if (w <= 0.00001) continue;
        vec3 pos = gi_origin_enabled.xyz + vec3(c)*gi_spacing.xyz + c_gi[idx].offset_validity.xyz;
        vec3 delta = p - pos;
        float dist = length(delta);
        int s = giSector(delta);
        vec4 moment = c_gi[idx].moments[s];
        float mean = c_gi[idx].lobes[s].w;
        float variance = max(moment.x - mean*mean, 0.0025);
        float excess = max(dist - mean - 0.05, 0.0);
        float vis = variance / (variance + excess*excess);
        if (moment.y <= 0.0) continue;
        vis = vis*vis*vis;
        vec3 radiance = c_gi[idx].lobes[n.x >= 0.0 ? 0 : 1].rgb*n2.x
                      + c_gi[idx].lobes[n.y >= 0.0 ? 2 : 3].rgb*n2.y
                      + c_gi[idx].lobes[n.z >= 0.0 ? 4 : 5].rgb*n2.z;
        sum_rgb += radiance*w*vis;
        sum_w += w;
    }
    // Keep occluded samples dark, while fading to the legacy fallback for uninitialized probes.
    return vec4(sum_rgb/max(sum_w, 0.00001), clamp(sum_w, 0.0, 1.0));
}

vec3 evalRectLightLegacy(GpuRectLight rl, vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness) {
    vec3 to_p = v_world_pos - rl.pos_range.xyz;
    float plane_d = dot(to_p, rl.dir_two.xyz);
    if (plane_d <= 0.0 && rl.dir_two.w < 0.5) return vec3(0.0);
    vec3 p_on_plane = v_world_pos - rl.dir_two.xyz * plane_d;
    vec3 d_plane = p_on_plane - rl.pos_range.xyz;
    float cx = clamp(dot(d_plane, rl.right_hx.xyz), -rl.right_hx.w, rl.right_hx.w);
    float cy = clamp(dot(d_plane, rl.up_hy.xyz), -rl.up_hy.w, rl.up_hy.w);
    vec3 closest = rl.pos_range.xyz + rl.right_hx.xyz * cx + rl.up_hy.xyz * cy;

    vec3 to_l = closest - v_world_pos;
    float dist = length(to_l);
    float range = max(rl.pos_range.w, 0.001);
    if (dist >= range) return vec3(0.0);
    vec3 L = to_l / max(dist, 0.0001);
    float att = clamp(1.0 - pow(dist / range, 4.0), 0.0, 1.0);
    att = (att * att) / (dist * dist + 1.0);
    float facing = (rl.dir_two.w > 0.5) ? abs(dot(-L, rl.dir_two.xyz)) : max(dot(-L, rl.dir_two.xyz), 0.0);
    return evalLight(N, V, F0, albedo, metallic, roughness, L, rl.col_pad.rgb * att * facing, 1.0);
}

vec3 evalRectLightQuadrature(GpuRectLight rl, vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness) {
    vec3 to_p = v_world_pos - rl.pos_range.xyz;
    float plane_d = dot(to_p, rl.dir_two.xyz);
    if (plane_d <= 0.0 && rl.dir_two.w < 0.5) return vec3(0.0);
    // Tensor-product 2x2 Gauss-Legendre quadrature over the finite emitter.
    // Flux is split equally, retaining the legacy far-field scale.
    vec3 sum_rgb = vec3(0.0);
    const float node = 0.57735026919;
    float range = max(rl.pos_range.w, 0.001);
    for (int i = 0; i < 4; ++i) {
        float sx = (i & 1) == 0 ? -node : node;
        float sy = (i & 2) == 0 ? -node : node;
        vec3 sample_pos = rl.pos_range.xyz + rl.right_hx.xyz * (sx * rl.right_hx.w)
                        + rl.up_hy.xyz * (sy * rl.up_hy.w);
        vec3 delta = sample_pos - v_world_pos;
        float dist = length(delta);
        if (dist >= range || dist < 0.0001) continue;
        vec3 L = delta / dist;
        float r = dist / range;
        float att = 1.0 - r*r*r*r;
        att = att*att/(dist*dist + 1.0);
        float facing = dot(-L, rl.dir_two.xyz);
        facing = rl.dir_two.w > 0.5 ? abs(facing) : max(facing, 0.0);
        sum_rgb += evalLight(N, V, F0, albedo, metallic, roughness, L, rl.col_pad.rgb * (att * facing * 0.25), 1.0);
    }
    return sum_rgb;
}

vec4 ltcLookup(vec2 uv,bool amplitude) {
    vec2 p=clamp(uv,vec2(0),vec2(1))*15.0;
    ivec2 i=min(ivec2(floor(p)),ivec2(14));
    vec2 f=p-vec2(i);
    ivec2 base=i+ivec2(0,amplitude?16:0);
    vec4 a=texelFetch(u_ltc,base,0),b=texelFetch(u_ltc,base+ivec2(1,0),0);
    vec4 c=texelFetch(u_ltc,base+ivec2(0,1),0),d=texelFetch(u_ltc,base+ivec2(1,1),0);
    return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}
float ltcPolygon(vec3 corners[4],mat3 invM) {
    // Clip the transformed polygon against the cosine hemisphere, then integrate edges.
    vec3 v[4];for(int i=0;i<4;++i)v[i]=invM*corners[i];
    vec3 clipped[8];int count=0;
    for(int i=0;i<4;++i){vec3 a=v[i],b=v[(i+1)%4];bool ia=a.z>0.0,ib=b.z>0.0;
        if(ia)clipped[count++]=a;
        if(ia!=ib)clipped[count++]=mix(a,b,clamp(a.z/(a.z-b.z),0.0,1.0));
    }
    if(count<3)return 0.0;
    float integral=0.0;
    for(int i=0;i<count;++i){vec3 a=clipped[i],b=clipped[(i+1)%count];
        float la=length(a),lb=length(b);if(la<1e-6||lb<1e-6)continue;
        a/=la;b/=lb;vec3 crossAB=cross(a,b);float s=length(crossAB);
        if(s>1e-6)integral+=crossAB.z*atan(s,clamp(dot(a,b),-1.0,1.0))/s;
    }
    return clamp(abs(integral)/(2.0*PI),0.0,1.0);
}
vec3 evalRectLightLtc(GpuRectLight rl,vec3 N,vec3 V,vec3 F0,vec3 albedo,float metallic,float roughness) {
    float nv=max(dot(N,V),0.0);
    if(roughness<0.18||nv<0.1)return evalRectLightQuadrature(rl,N,V,F0,albedo,metallic,roughness);
    vec2 uv=vec2((roughness-0.18)/0.82,(1.0-nv)/0.9);
    vec4 fit=ltcLookup(uv,false),amp=ltcLookup(uv,true);
    if(fit.w>0.45)return evalRectLightQuadrature(rl,N,V,F0,albedo,metallic,roughness);
    vec3 delta=rl.pos_range.xyz-v_world_pos;
    float distance=length(delta),range=max(rl.pos_range.w,0.001);
    if(dot(-delta,rl.dir_two.xyz)<=0.0&&rl.dir_two.w<0.5)return vec3(0);
    float area=4.0*rl.right_hx.w*rl.up_hy.w;
    if(area<=1e-5||distance<1e-4)return evalRectLightQuadrature(rl,N,V,F0,albedo,metallic,roughness);
    vec3 T=V-N*nv;
    if(dot(T,T)<1e-6)T=cross(abs(N.y)<0.99?vec3(0,1,0):vec3(1,0,0),N);
    T=normalize(T);vec3 B=cross(N,T);mat3 basis=transpose(mat3(T,B,N));
    vec3 right=rl.right_hx.xyz*rl.right_hx.w,up=rl.up_hy.xyz*rl.up_hy.w;
    vec3 corners[4]=vec3[4](basis*(delta-right-up),basis*(delta+right-up),basis*(delta+right+up),basis*(delta-right+up));
    mat3 invM=mat3(vec3(fit.x,0,0),vec3(0,fit.y,0),vec3(fit.z,0,1));
    float diffuse=ltcPolygon(corners,mat3(1));float specular=ltcPolygon(corners,invM);
    vec3 fresnel=F0+(1.0-F0)*pow(1.0-nv,5.0);
    vec3 kd=(1.0-fresnel)*(1.0-metallic);
    vec3 amplitude=F0*amp.x+(1.0-F0)*amp.y;
    float nearDistance=max(distance-length(right)-length(up),0.0);
    float r=clamp(nearDistance/range,0.0,1.0);float window=1.0-r*r*r*r;
    // Keep the legacy finite-range and approximate photometric scale; no global SI migration here.
    return (kd*albedo*diffuse+amplitude*specular)*rl.col_pad.rgb*(window*window/area);
}
vec3 evalRectLight(GpuRectLight rl, vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness) {
    if(layer_info.w>1.5)return evalRectLightLtc(rl,N,V,F0,albedo,metallic,roughness);
    if (layer_info.w > 0.5) return evalRectLightQuadrature(rl,N,V,F0,albedo,metallic,roughness);
    return evalRectLightLegacy(rl,N,V,F0,albedo,metallic,roughness);
}

void main() {
    vec4 tex_albedo = texture(u_base_color_tex, v_uv);
    vec4 albedo_a = vec4(tex_albedo.rgb * base_color.rgb, tex_albedo.a * base_color.a);
    if (cluster_factors.w >= 0.0 && albedo_a.a < cluster_factors.w) {
        discard;
    }

#ifdef ZENGY_SCREEN_TRANSPORT
    out_surface=vec4(0,0,-1,0);
    out_diffuse=vec4(0);
    out_specular=vec4(0);
#endif
    vec3 emissive_rgb = emissive_weight.rgb * texture(u_emissive_tex, v_uv).rgb;
    if (mat_flags.x > 0.5) {
        frag_color = vec4((albedo_a.rgb + emissive_rgb) * layer_info.z, albedo_a.a);
        return;
    }

    vec4 mr = texture(u_mr_tex, v_uv);
    float metallic = clamp(mat_params.x * mr.b, 0.0, 1.0);
    float roughness = clamp(mat_params.y * mr.g, 0.045, 1.0);
    vec3 N = normalize(v_world_normal);
    // Double-sided back faces are visible only when culling is off; light them as if they faced the viewer.
    if (!gl_FrontFacing) {
        N = -N;
    }
    vec3 V = normalize(camera_pos_fog.xyz - v_world_pos);
    if (mat_flags.y > 0.0) {
        N = perturbNormal(N, V, v_uv);
    }
    // Geometric specular AA: filter perceptual roughness in the GGX alpha-squared domain.
    if (sh_coeffs[4].w > 0.5) {
        vec3 nx = dFdx(N);
        vec3 ny = dFdy(N);
        float variance = min(0.15, 0.5 * (dot(nx,nx) + dot(ny,ny)));
        float r2 = roughness * roughness;
        roughness = pow(clamp(r2*r2 + variance, 0.0000041, 1.0), 0.25);
    }
    vec3 F0 = mix(vec3(0.16 * mat_params.z * mat_params.z), albedo_a.rgb, metallic);
    float view_depth = max(dot(v_world_pos - camera_pos_fog.xyz, normalize(camera_fwd_overlap.xyz)), 0.0);
    vec2 suv = gl_FragCoord.xy * vec2(sh_coeffs[1].w, sh_coeffs[2].w);
    vec4 ssao_sample = texture(u_ssao_tex, suv);
    float ssao = (sh_coeffs[0].w > 0.5) ? ssao_sample.r : 1.0;
    float contact_shadow = (sh_coeffs[3].w > 0.5) ? ssao_sample.g : 1.0;
    float rot = ign(gl_FragCoord.xy) * 6.2831853;

    vec3 Lo = vec3(0.0);
    if (dir_light_dir.w > 0.0 && layersOverlap(layer_info.y, layer_info.x)) {
        vec3 L = normalize(dir_light_dir.xyz);
        float vis = sampleShadowCSM(N, L, view_depth) * contact_shadow;
        Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, dir_light_col.rgb * dir_light_dir.w, 1.0) * vis;
    }

    if (cluster_factors.z > 0.5) {
        int cx = clamp(int(suv.x * 16.0), 0, 15);
        int cy = clamp(int(suv.y * 9.0), 0, 8);
        int cz = clamp(int(floor(log(max(view_depth, 0.05)) * cluster_factors.x - cluster_factors.y)), 0, 23);
        uvec4 cl = clusters[(cy * 16 + cx) * 24 + cz];

        uint p_off = cl.x >> 8u;
        uint p_cnt = cl.x & 0xFFu;
        for (uint i = 0u; i < p_cnt; ++i) {
            GpuPointLight pl = c_points[cluster_indices[p_off + i]];
            if (!layersOverlap(pl.shadow_params.y, layer_info.x)) continue;
            vec3 to_l = pl.pos_range.xyz - v_world_pos;
            float dist = length(to_l);
            float range = max(pl.pos_range.w, 0.001);
            if (dist < range) {
                float att = clamp(1.0 - pow(dist / range, 4.0), 0.0, 1.0);
                // A light with a physical radius never gets brighter than a sphere of that radius allows: this removes the hotspot
                // a point light paints on a wall it sits close to.
                att = (att * att) / (dist * dist + 1.0 + pl.shadow_params.x * pl.shadow_params.x);
                vec3 L = to_l / max(dist, 0.0001);
                if (dot(N, L) <= 0.0) continue;
                float vis = (pl.col_radius.w >= 0.0) ? samplePointShadow(int(pl.col_radius.w + 0.5), pl.pos_range.xyz, N, L, rot, pl.shadow_params.x) : 1.0;
                Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, pl.col_radius.rgb * att, pl.shadow_params.z) * vis;
            }
        }

        uint s_off = cl.y >> 8u;
        uint s_cnt = cl.y & 0xFFu;
        for (uint i = 0u; i < s_cnt; ++i) {
            GpuSpotLight sl = c_spots[cluster_indices[s_off + i]];
            if (!layersOverlap(sl.shadow_params.w, layer_info.x)) continue;
            vec3 to_l = sl.pos_range.xyz - v_world_pos;
            float dist = length(to_l);
            float range = max(sl.pos_range.w, 0.001);
            if (dist < range) {
                vec3 L = to_l / max(dist, 0.0001);
                float theta = dot(L, normalize(-sl.dir_cos_inner.xyz));
                float eps = max(sl.dir_cos_inner.w - sl.col_cos_outer.w, 0.001);
                float cone = clamp((theta - sl.col_cos_outer.w) / eps, 0.0, 1.0);
                float att = clamp(1.0 - pow(dist / range, 4.0), 0.0, 1.0);
                att = (att * att) / (dist * dist + 1.0);
                if (cone <= 0.0 || dot(N, L) <= 0.0) continue;
                float spot_bias = 0.0012 + (1.0 - max(dot(N, L), 0.0)) * 0.004;
                float vis = (sl.shadow_params.x >= 0.0) ? sampleLocalTile(int(sl.shadow_params.x + 0.5), v_world_pos, spot_bias, rot, sl.shadow_params.z) : 1.0;
                Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, sl.col_cos_outer.rgb * att * cone, 1.0) * vis;
            }
        }

        uint r_off = cl.z >> 8u;
        uint r_cnt = cl.z & 0xFFu;
        for (uint i = 0u; i < r_cnt; ++i) {
            GpuRectLight rl = c_rects[cluster_indices[r_off + i]];
            if (!layersOverlap(rl.col_pad.w, layer_info.x)) continue;
            Lo += evalRectLight(rl, N, V, F0, albedo_a.rgb, metallic, roughness);
        }
    }

    // Split-Sum IBL + Box-Projected Local Reflection Probes + Multi-Scattering Energy Compensation.
    float NdotV = max(dot(N, V), 0.0);
    vec3 F_env = fresnelSchlickRoughness(NdotV, F0, roughness);
    vec3 kD_env = (vec3(1.0) - F_env) * (1.0 - metallic);
    vec3 irradiance = evalSH9Diffuse(N) + ambient_sky.rgb;
    vec3 diffuse_ibl = irradiance * albedo_a.rgb;

    vec3 R = reflect(-V, N);
    vec3 prefiltered = textureLod(u_prefilter_env, equirectUv(R), roughness * sky_horizon.w).rgb;

    int probe_cnt = int(probe_volumetric.x + 0.5);
    if (probe_cnt > 0) {
        vec3 probe_irr = vec3(0.0);
        vec3 probe_spec = vec3(0.0);
        float probe_w = 0.0;
        for (int i = 0; i < 32; ++i) {
            if (i >= probe_cnt) break;
            GpuReflectionProbe pr = c_probes[i];
            vec3 d = abs(v_world_pos - pr.pos_int.xyz);
            vec3 edge_d = pr.half_blend.xyz - d;
            if (edge_d.x > 0.0 && edge_d.y > 0.0 && edge_d.z > 0.0) {
                vec3 f3 = smoothstep(vec3(0.0), vec3(max(pr.half_blend.w, 0.05)), edge_d);
                float w = f3.x * f3.y * f3.z * pr.pos_int.w;
                float hemi = N.y * 0.5 + 0.5;
                probe_irr += mix(pr.ground_pad.rgb, pr.sky_box.rgb, hemi) * (w * pr.ground_pad.w);
                float r_hemi = R.y * 0.5 + 0.5;
                vec3 local_spec=mix(pr.ground_pad.rgb,pr.sky_box.rgb,r_hemi);
                if(pr.environment_info.x>0.5){
                    vec3 local_R=R;
                    if(pr.sky_box.w>0.5){
                        vec3 relative=v_world_pos-pr.pos_int.xyz;
                        vec3 side=mix(-pr.half_blend.xyz,pr.half_blend.xyz,greaterThanEqual(R,vec3(0)));
                        vec3 t=vec3(1e20);
                        for(int axis=0;axis<3;++axis)if(abs(R[axis])>1e-6)t[axis]=(side[axis]-relative[axis])/R[axis];
                        float travel=max(min(min(t.x,t.y),t.z),0.0);
                        vec3 corrected=relative+R*travel;
                        if(dot(corrected,corrected)>1e-8)local_R=normalize(corrected);
                    }
                    local_spec=textureLod(u_probe_environment,equirectUv(local_R),roughness*pr.environment_info.y).rgb;
                }
                probe_spec += local_spec * w;
                probe_w += w;
            }
        }
        float pw = clamp(probe_w, 0.0, 1.0);
        if (pw > 0.0) {
            diffuse_ibl = mix(diffuse_ibl, (probe_irr / max(probe_w, 1e-4)) * albedo_a.rgb, pw);
            prefiltered = mix(prefiltered, probe_spec / max(probe_w, 1e-4), pw);
        }
    }

    vec4 dynamic_gi = sampleDynamicGi(v_world_pos + N * 0.03, N);
    diffuse_ibl = mix(diffuse_ibl, dynamic_gi.rgb * albedo_a.rgb, dynamic_gi.a);
    vec2 brdf = texture(u_brdf_lut, vec2(NdotV, roughness)).rg;
    vec3 FssEss = F0 * brdf.x + brdf.y;
    float Ess = brdf.x + brdf.y;
    float Ems = 1.0 - Ess;
    vec3 Favg = F0 + (1.0 - F0) / 21.0;
    vec3 Fms = FssEss * Favg / max(vec3(1.0) - Ems * Favg, vec3(1e-4));
    vec3 specular_ibl = prefiltered * (FssEss + Fms * Ems);

    float ao_tex_val = texture(u_ao_tex, v_uv).r;
    float diff_ao = mix(1.0, ao_tex_val, mat_params.w) * ssao;
    float spec_ao = clamp(pow(NdotV + diff_ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + diff_ao, 0.0, 1.0);
    vec3 ambient = kD_env * diffuse_ibl * diff_ao + specular_ibl * spec_ao;
#ifdef ZENGY_SCREEN_TRANSPORT
    // A transparent draw invalidates the underlying opaque metadata; no screen-space
    // lighting replacement is performed on an already blended HDR pixel.
    if(sh_coeffs[5].w < 0.5 && !any(isnan(N)) && !any(isinf(N)) && dot(N,N)>1e-6 && !any(isnan(albedo_a.rgb)) && !any(isinf(albedo_a.rgb))) {
        out_surface=vec4(encodeNormal(N),packRgb(vec3(roughness,metallic,mat_params.z)),packRgb(albedo_a.rgb));
        out_diffuse=vec4(kD_env*diffuse_ibl*diff_ao*layer_info.z,diff_ao);
        out_specular=vec4(specular_ibl*spec_ao*layer_info.z,spec_ao);
    }
#endif
    vec3 color = ambient + Lo + emissive_rgb;

    // With ray-marched volumetric fog on, the composite pass applies transmittance and in-scatter
    // (L = L_scene * T + L_scatter). Applying distance fog here too would extinguish the scene twice.
    if (camera_pos_fog.w > 0.5 && probe_volumetric.z < 0.5) {
        float d = max(length(camera_pos_fog.xyz - v_world_pos) - fog_color_start.w, 0.0);
        float fog_f = 1.0 - exp(-d * ambient_sky.w);
        color = mix(color, fog_color_start.rgb, clamp(fog_f, 0.0, 1.0));
    }

    frag_color = vec4(color * layer_info.z, albedo_a.a);
}
