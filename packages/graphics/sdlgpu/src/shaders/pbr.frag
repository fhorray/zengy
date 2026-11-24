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

struct GpuPointLight {
    vec4 pos_range;  // xyz=pos, w=range
    vec4 col_radius; // rgb=color*scale, w=shadow_tile (-1 = none)
};

struct GpuSpotLight {
    vec4 pos_range;     // xyz=pos, w=range
    vec4 dir_cos_inner; // xyz=dir, w=cos_inner
    vec4 col_cos_outer; // rgb=color*scale, w=cos_outer
    vec4 shadow_params; // x=shadow_tile (-1=none), y=bias, z=0, w=0
};

struct GpuRectLight {
    vec4 pos_range; // xyz=pos, w=range
    vec4 dir_two;   // xyz=dir, w=two_sided
    vec4 right_hx;  // xyz=right, w=half_width
    vec4 up_hy;     // xyz=up, w=half_height
    vec4 col_pad;   // rgb=color*scale
};

struct GpuReflectionProbe {
    vec4 pos_int;    // xyz=pos, w=intensity
    vec4 half_blend; // xyz=half_extents, w=blend_distance
    vec4 sky_box;    // rgb=sky_tint, w=box_projection
    vec4 ground_pad; // rgb=ground_tint
};

layout(std430, set = 2, binding = 8) readonly buffer ClusterLightsBuffer {
    GpuPointLight c_points[256];
    GpuSpotLight c_spots[256];
    GpuRectLight c_rects[64];
    GpuReflectionProbe c_probes[32];
};

layout(std430, set = 2, binding = 9) readonly buffer ClusterGridBuffer {
    uvec4 clusters[];
};

layout(std430, set = 2, binding = 10) readonly buffer ClusterIndicesBuffer {
    uint cluster_indices[];
};

layout(std430, set = 2, binding = 11) readonly buffer LocalShadowBuffer {
    mat4 local_shadow_vp[16];
    vec4 local_atlas_rect[16]; // x, y, w, h in [0,1]
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
};

layout(location = 0) out vec4 frag_color;

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
    float bias_m = max(0.025, mat_flags.z * 5.0) * (1.0 + slope * 2.5);
    float bias = bias_m / depth_range;
    vec2 texel = 1.0 / vec2(textureSize(u_shadow_tex, 0));
    float pcss_boost = (probe_volumetric.y > 0.5) ? (1.0 + clamp(view_depth / 30.0, 0.0, 1.5)) : 1.0;
    float radius_texels = (2.2 - float(c_idx) * 0.2) * pcss_boost;
    int taps = (c_idx < 2) ? 12 : 8;
    float shadow = 0.0;
    for (int i = 0; i < taps; ++i) {
        vec2 o = vogelDisk(i, taps, rot) * radius_texels * texel;
        vec2 suv = clamp(uv + o, q_min + texel, q_max - texel);
        shadow += texture(u_shadow_tex, vec3(suv, proj.z - bias));
    }
    return shadow / float(taps);
}

float sampleShadowCSM(vec3 N, vec3 L, float view_depth) {
    if (mat_flags.w < 0.5) return 1.0;
    float max_dist = max(cascade_splits.w, 1.0);
    if (view_depth > max_dist) return 1.0;

    int idx = 0;
    for (int i = 0; i < 3; ++i) {
        if (view_depth > cascade_splits[i]) idx = i + 1;
    }

    float rot = ign(gl_FragCoord.xy) * 6.2831853;
    float lit = sampleCascadePCF(idx, N, L, rot, view_depth);
    if (lit < 0.0) {
        for (int k = idx + 1; k < 4; ++k) {
            lit = sampleCascadePCF(k, N, L, rot, view_depth);
            if (lit >= 0.0) break;
        }
        if (lit < 0.0) lit = 1.0;
    } else if (idx < 3) {
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

float sampleLocalTile(int tile_idx, vec3 world_pos, float bias, float rot) {
    if (tile_idx < 0 || tile_idx >= 16) return 1.0;
    vec4 lp = local_shadow_vp[tile_idx] * vec4(world_pos, 1.0);
    if (lp.w <= 0.001) return 1.0;
    vec3 proj = lp.xyz / lp.w;
    vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
    if (uv.x < 0.01 || uv.x > 0.99 || uv.y < 0.01 || uv.y > 0.99 || proj.z < 0.0 || proj.z > 1.0) {
        return 1.0;
    }
    vec4 rect = local_atlas_rect[tile_idx];
    vec2 suv = rect.xy + uv * rect.zw;
    vec2 texel = 1.0 / vec2(textureSize(u_local_shadow_tex, 0));
    float s = 0.0;
    for (int i = 0; i < 6; ++i) {
        vec2 o = vogelDisk(i, 6, rot) * 1.6 * texel;
        vec2 cuv = clamp(suv + o, rect.xy + texel, rect.xy + rect.zw - texel);
        s += texture(u_local_shadow_tex, vec3(cuv, proj.z - bias));
    }
    return s / 6.0;
}

float samplePointShadow(int base_tile, vec3 light_pos, vec3 N, vec3 L, float rot) {
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
    return sampleLocalTile(base_tile + face, v_world_pos, bias, rot);
}

vec3 evalLight(vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness, vec3 L, vec3 radiance) {
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) return vec3(0.0);
    vec3 H = normalize(V + L);
    float NDF = distributionGGX(N, H, roughness);
    float G = geometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    vec3 spec = (NDF * G * F) / max(4.0 * max(dot(N, V), 0.0) * NdotL, 0.0001);
    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
    return (kD * albedo / PI + spec) * radiance * NdotL;
}

vec3 evalRectLight(GpuRectLight rl, vec3 N, vec3 V, vec3 F0, vec3 albedo, float metallic, float roughness) {
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
    return evalLight(N, V, F0, albedo, metallic, roughness, L, rl.col_pad.rgb * att * facing);
}

void main() {
    vec4 tex_albedo = texture(u_base_color_tex, v_uv);
    vec4 albedo_a = vec4(tex_albedo.rgb * base_color.rgb, tex_albedo.a * base_color.a);

    if (mat_flags.x > 0.5) {
        frag_color = vec4(albedo_a.rgb + emissive_weight.rgb, albedo_a.a);
        return;
    }

    vec4 mr = texture(u_mr_tex, v_uv);
    float metallic = clamp(mat_params.x * mr.b, 0.0, 1.0);
    float roughness = clamp(mat_params.y * mr.g, 0.045, 1.0);
    vec3 N = normalize(v_world_normal);
    vec3 V = normalize(camera_pos_fog.xyz - v_world_pos);
    if (mat_flags.y > 0.0) {
        N = perturbNormal(N, V, v_uv);
    }
    vec3 F0 = mix(vec3(0.16 * mat_params.z * mat_params.z), albedo_a.rgb, metallic);
    float view_depth = max(dot(v_world_pos - camera_pos_fog.xyz, normalize(camera_fwd_overlap.xyz)), 0.0);
    vec2 suv = gl_FragCoord.xy * vec2(sh_coeffs[1].w, sh_coeffs[2].w);
    vec4 ssao_sample = texture(u_ssao_tex, suv);
    float ssao = (sh_coeffs[0].w > 0.5) ? ssao_sample.r : 1.0;
    float contact_shadow = (sh_coeffs[3].w > 0.5) ? ssao_sample.g : 1.0;
    float rot = ign(gl_FragCoord.xy) * 6.2831853;

    vec3 Lo = vec3(0.0);
    if (dir_light_dir.w > 0.0) {
        vec3 L = normalize(dir_light_dir.xyz);
        float vis = sampleShadowCSM(N, L, view_depth) * contact_shadow;
        Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, dir_light_col.rgb * dir_light_dir.w) * vis;
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
            vec3 to_l = pl.pos_range.xyz - v_world_pos;
            float dist = length(to_l);
            float range = max(pl.pos_range.w, 0.001);
            if (dist < range) {
                float att = clamp(1.0 - pow(dist / range, 4.0), 0.0, 1.0);
                att = (att * att) / (dist * dist + 1.0);
                vec3 L = to_l / max(dist, 0.0001);
                float vis = (pl.col_radius.w >= 0.0) ? samplePointShadow(int(pl.col_radius.w + 0.5), pl.pos_range.xyz, N, L, rot) : 1.0;
                Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, pl.col_radius.rgb * att) * vis;
            }
        }

        uint s_off = cl.y >> 8u;
        uint s_cnt = cl.y & 0xFFu;
        for (uint i = 0u; i < s_cnt; ++i) {
            GpuSpotLight sl = c_spots[cluster_indices[s_off + i]];
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
                float spot_bias = 0.0012 + (1.0 - max(dot(N, L), 0.0)) * 0.004;
                float vis = (sl.shadow_params.x >= 0.0) ? sampleLocalTile(int(sl.shadow_params.x + 0.5), v_world_pos, spot_bias, rot) : 1.0;
                Lo += evalLight(N, V, F0, albedo_a.rgb, metallic, roughness, L, sl.col_cos_outer.rgb * att * cone) * vis;
            }
        }

        uint r_off = cl.z >> 8u;
        uint r_cnt = cl.z & 0xFFu;
        for (uint i = 0u; i < r_cnt; ++i) {
            GpuRectLight rl = c_rects[cluster_indices[r_off + i]];
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
                probe_irr += mix(pr.ground_pad.rgb, pr.sky_box.rgb, hemi) * w;
                float r_hemi = R.y * 0.5 + 0.5;
                probe_spec += mix(pr.ground_pad.rgb, pr.sky_box.rgb, r_hemi) * w;
                probe_w += w;
            }
        }
        float pw = clamp(probe_w, 0.0, 1.0);
        if (pw > 0.0) {
            diffuse_ibl = mix(diffuse_ibl, (probe_irr / max(probe_w, 1e-4)) * albedo_a.rgb, pw);
            prefiltered = mix(prefiltered, probe_spec / max(probe_w, 1e-4), pw);
        }
    }

    vec2 brdf = texture(u_brdf_lut, vec2(NdotV, roughness)).rg;
    vec3 FssEss = F0 * brdf.x + brdf.y;
    float Ess = brdf.x + brdf.y;
    float Ems = 1.0 - Ess;
    vec3 Favg = F0 + (1.0 - F0) / 21.0;
    vec3 Fms = FssEss * Favg / max(vec3(1.0) - Ems * Favg, vec3(1e-4));
    vec3 specular_ibl = prefiltered * (FssEss + Fms * Ems);

    vec3 ambient = (kD_env * diffuse_ibl + specular_ibl) * mat_params.w * ssao;
    vec3 color = ambient + Lo + emissive_weight.rgb;

    if (camera_pos_fog.w > 0.5) {
        float d = max(length(camera_pos_fog.xyz - v_world_pos) - fog_color_start.w, 0.0);
        float fog_f = 1.0 - exp(-d * ambient_sky.w);
        vec3 fog_c = fog_color_start.rgb;
        if (probe_volumetric.z > 0.5 && dir_light_dir.w > 0.0) {
            float cos_a = dot(-V, normalize(dir_light_dir.xyz));
            float g = 0.6;
            float phase = (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * cos_a, 0.01), 1.5));
            fog_c += dir_light_col.rgb * dir_light_dir.w * phase * probe_volumetric.w;
        }
        color = mix(color, fog_c, clamp(fog_f, 0.0, 1.0));
    }

    frag_color = vec4(color, albedo_a.a);
}
