#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_depth;
layout(set = 2, binding = 1) uniform sampler2DShadow u_shadow_tex;
layout(set = 2, binding = 2) uniform sampler2DShadow u_local_shadow_tex;

// Slot arrays (spot_*, point_*) hold the four most relevant lights chosen on the CPU; `w` of the
// colour/status vector marks an active slot, so the loops break on the first inactive one.
layout(std140, set = 3, binding = 0) uniform VolFogParams {
    mat4 inv_view_proj;
    mat4 light_vp[4];
    vec4 cam_pos_density; // xyz=cam_pos, w=density
    vec4 sun_dir_int;     // xyz=to_sun, w=sun_intensity
    vec4 sun_col_aniso;   // xyz=sun_color, w=anisotropy g
    vec4 fog_col_scat;    // xyz=fog_color, w=scattering
    vec4 cascade_splits;  // 4 cascade far bounds (w < 0 disables sun shadow)
    vec4 cam_fwd_maxd;    // xyz=cam_forward, w=max_distance
    vec4 spot_pos_range[4]; // xyz=pos, w=range
    vec4 spot_dir_cos[4];   // xyz=dir, w=cos_outer
    vec4 spot_col_on[4];    // rgb=color*scale, w=active
    vec4 spot_shadow[4];    // x=local-atlas tile, y=1 when it casts shadows
    vec4 point_pos[4];      // xyz=pos, w=range
    vec4 point_col[4];      // rgb=color*scale, w=active
    vec4 point_shadow[4];   // x=first cube-face tile, y=1 when it casts shadows
    mat4 local_vp[16];      // local shadow atlas view-projections (point cube faces and spot tiles)
    vec4 local_rect[16];    // local shadow atlas rect: xy=offset, z=size
    vec4 cascade_info;      // x=number of cascades rendered this frame (0..4), y=per-frame jitter offset (0 when not temporal)
};

// RGB = in-scattered light, A = marched distance. The composite pass reads A to upsample depth-aware.
layout(location = 0) out vec4 frag_color;

const float PI = 3.14159265359;

float ign(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

float henyeyGreenstein(float cos_theta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 0.05), 1.5));
}

float sampleVolShadow(vec3 wp, float view_depth) {
    int count = clamp(int(cascade_info.x + 0.5), 0, 4);
    if (cascade_splits.w < 0.0 || count == 0) return 1.0;
    int idx = 0;
    for (int i = 0; i < 3; ++i) {
        if (i < count - 1 && view_depth > cascade_splits[i]) idx = i + 1;
    }
    for (int k = idx; k < count; ++k) {
        vec4 lp = light_vp[k] * vec4(wp, 1.0);
        vec3 proj = lp.xyz / max(lp.w, 0.0001);
        vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
        if (uv.x >= 0.01 && uv.x <= 0.99 && uv.y >= 0.01 && uv.y <= 0.99 && proj.z >= 0.0 && proj.z <= 1.0) {
            vec2 q_min = vec2((k & 1) * 0.5, (k >> 1) * 0.5);
            vec2 suv = q_min + uv * 0.5;
            return texture(u_shadow_tex, vec3(suv, proj.z - 0.0006));
        }
    }
    return 1.0;
}

// Visibility from one tile of the local shadow atlas (a spot tile or one point cube face).
float sampleLocalTile(int tile, vec3 wp) {
    vec4 lp = local_vp[tile] * vec4(wp, 1.0);
    if (lp.w <= 0.0001) return 1.0;
    vec3 proj = lp.xyz / lp.w;
    vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
    if (uv.x < 0.005 || uv.x > 0.995 || uv.y < 0.005 || uv.y > 0.995 || proj.z < 0.0 || proj.z > 1.0) {
        return 1.0;
    }
    vec2 suv = local_rect[tile].xy + uv * local_rect[tile].z;
    return texture(u_local_shadow_tex, vec3(suv, proj.z - 0.001));
}

// Visibility of a point light as seen from `wp`, using the cube face that the direction falls into.
// Faces follow the CPU build order: +X, -X, +Y, -Y, +Z, -Z, each stored at consecutive local-atlas tiles.
float samplePointShadow(int j, vec3 wp) {
    if (point_shadow[j].y < 0.5) return 1.0;
    vec3 d = wp - point_pos[j].xyz;
    vec3 a = abs(d);
    int face;
    if (a.x >= a.y && a.x >= a.z) {
        face = (d.x >= 0.0) ? 0 : 1;
    } else if (a.y >= a.z) {
        face = (d.y >= 0.0) ? 2 : 3;
    } else {
        face = (d.z >= 0.0) ? 4 : 5;
    }
    return sampleLocalTile(int(point_shadow[j].x + 0.5) + face, wp);
}

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    float d = texture(u_depth, uv).r;

    vec4 far_ndc = vec4(v_ndc, (d >= 0.9999) ? 1.0 : d, 1.0);
    vec4 wp4 = inv_view_proj * far_ndc;
    vec3 wp = wp4.xyz / max(wp4.w, 1e-5);

    vec3 ray = wp - cam_pos_density.xyz;
    float dist = length(ray);
    vec3 ray_dir = ray / max(dist, 1e-4);
    float max_dist = min(dist, cam_fwd_maxd.w);
    if (d >= 0.9999) {
        max_dist = cam_fwd_maxd.w;
    }
    if (max_dist < 0.1) {
        frag_color = vec4(0.0);
        return;
    }

    vec3 sun_dir = normalize(sun_dir_int.xyz);
    vec3 cam_fwd = normalize(cam_fwd_maxd.xyz);
    float cos_theta = dot(ray_dir, sun_dir);
    // Blend isotropic floor with Henyey-Greenstein so side-viewed shafts remain clearly visible.
    float hg = henyeyGreenstein(cos_theta, clamp(sun_col_aniso.w, -0.85, 0.85));
    float phase = mix(0.20, hg, 0.65);

    const int STEPS = 64;
    float step_len = max_dist / float(STEPS);
    // The offset walks the golden-ratio sequence frame to frame, so a temporal accumulator sees fresh samples.
    float jitter = fract(ign(gl_FragCoord.xy) + cascade_info.y);
    // Extinction uses the configured density exactly: the composite pass applies the same T to the scene,
    // so a floor here would darken the scene even when fog density is zero.
    float ext_density = max(cam_pos_density.w, 0.0);
    // Decouple visible in-scattering from distant surface-fog density so short shafts stay vivid.
    float scat_coeff = max(fog_col_scat.w, 0.0) * 0.18;

    vec3 accum = vec3(0.0);
    float transmittance = 1.0;

    for (int i = 0; i < STEPS; ++i) {
        float t = (float(i) + jitter) * step_len;
        vec3 p = cam_pos_density.xyz + ray_dir * t;
        float vd = max(dot(p - cam_pos_density.xyz, cam_fwd), 0.0);
        float vis = sampleVolShadow(p, vd);

        vec3 step_light = sun_col_aniso.rgb * (sun_dir_int.w * phase * vis * 0.72);

        for (int j = 0; j < 4; ++j) {
            if (point_col[j].w < 0.5) break;
            vec3 to_pt = p - point_pos[j].xyz;
            float pdist2 = dot(to_pt, to_pt);
            float pdist = sqrt(pdist2);
            float prange = point_pos[j].w;
            if (pdist < prange) {
                float win = clamp(1.0 - pdist / prange, 0.0, 1.0);
                float att = (win * win) / max(0.35 + pdist2 * 0.55, 0.12);
                float pt_phase = mix(0.25, henyeyGreenstein(dot(ray_dir, -to_pt / max(pdist, 1e-4)), 0.3), 0.5);
                // Occluded point lights must not light fog behind walls.
                step_light += point_col[j].rgb * (att * pt_phase * 0.85 * samplePointShadow(j, p));
            }
        }

        for (int j = 0; j < 4; ++j) {
            if (spot_col_on[j].w < 0.5) break;
            vec3 to_sp = p - spot_pos_range[j].xyz;
            float sdist2 = dot(to_sp, to_sp);
            float sdist = sqrt(sdist2);
            if (sdist < spot_pos_range[j].w) {
                vec3 sdir = to_sp / max(sdist, 1e-4);
                float cd = dot(sdir, normalize(spot_dir_cos[j].xyz));
                if (cd > spot_dir_cos[j].w) {
                    float cone = smoothstep(spot_dir_cos[j].w, min(spot_dir_cos[j].w + 0.14, 0.99), cd);
                    float win = clamp(1.0 - sdist / spot_pos_range[j].w, 0.0, 1.0);
                    float att = (win * win) / max(0.35 + sdist2 * 0.25, 0.12);
                    float sp_sv = (spot_shadow[j].y > 0.5) ? sampleLocalTile(int(spot_shadow[j].x + 0.5), p) : 1.0;
                    float sp_phase = mix(0.25, henyeyGreenstein(dot(ray_dir, -sdir), 0.35), 0.5);
                    step_light += spot_col_on[j].rgb * (att * cone * sp_sv * sp_phase * 1.15);
                }
            }
        }

        float step_ext = exp(-ext_density * step_len);
        accum += transmittance * step_light * (scat_coeff * step_len);
        transmittance *= step_ext;
    }

    frag_color = vec4(clamp(accum, vec3(0.0), vec3(50.0)), max_dist);
}
