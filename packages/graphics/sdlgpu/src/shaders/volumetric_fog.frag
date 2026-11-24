#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_depth;
layout(set = 2, binding = 1) uniform sampler2DShadow u_shadow_tex;

layout(std140, set = 3, binding = 0) uniform VolFogParams {
    mat4 inv_view_proj;
    mat4 light_vp[4];
    vec4 cam_pos_density; // xyz=cam_pos, w=density
    vec4 sun_dir_int;     // xyz=to_sun, w=sun_intensity
    vec4 sun_col_aniso;   // xyz=sun_color, w=anisotropy g
    vec4 fog_col_scat;    // xyz=fog_color, w=scattering
    vec4 cascade_splits;  // 4 cascade far bounds
    vec4 cam_fwd_maxd;    // xyz=cam_forward, w=max_distance
    vec4 spot_pos_range;  // xyz=spot_pos, w=range
    vec4 spot_dir_cos;    // xyz=spot_dir, w=cos_outer
    vec4 spot_col_on;     // xyz=spot_color, w=has_spot
};

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
    int idx = 0;
    for (int i = 0; i < 3; ++i) {
        if (view_depth > cascade_splits[i]) idx = i + 1;
    }
    for (int k = idx; k < 4; ++k) {
        vec4 lp = light_vp[k] * vec4(wp, 1.0);
        vec3 proj = lp.xyz / max(lp.w, 0.0001);
        vec2 uv = vec2(proj.x * 0.5 + 0.5, 0.5 - proj.y * 0.5);
        if (uv.x >= 0.01 && uv.x <= 0.99 && uv.y >= 0.01 && uv.y <= 0.99 && proj.z >= 0.0 && proj.z <= 1.0) {
            vec2 q_min = vec2((k & 1) * 0.5, (k >> 1) * 0.5);
            vec2 suv = q_min + uv * 0.5;
            return texture(u_shadow_tex, vec3(suv, proj.z - 0.0005));
        }
    }
    return 1.0;
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
    float phase = henyeyGreenstein(cos_theta, clamp(sun_col_aniso.w, -0.85, 0.85));

    const int STEPS = 16;
    float step_len = max_dist / float(STEPS);
    float jitter = ign(gl_FragCoord.xy);
    float density = max(cam_pos_density.w, 0.001);

    vec3 accum = vec3(0.0);
    float transmittance = 1.0;

    for (int i = 0; i < STEPS; ++i) {
        float t = (float(i) + jitter) * step_len;
        vec3 p = cam_pos_density.xyz + ray_dir * t;
        float vd = max(dot(p - cam_pos_density.xyz, cam_fwd), 0.0);
        float vis = sampleVolShadow(p, vd);

        vec3 sun_scatter = sun_col_aniso.rgb * sun_dir_int.w * phase * vis;
        vec3 amb_scatter = fog_col_scat.rgb * 0.08;
        vec3 step_light = sun_scatter + amb_scatter;

        if (spot_col_on.w > 0.5) {
            vec3 to_sp = p - spot_pos_range.xyz;
            float sdist = length(to_sp);
            if (sdist < spot_pos_range.w) {
                vec3 sdir = to_sp / max(sdist, 1e-4);
                float cd = dot(sdir, normalize(spot_dir_cos.xyz));
                if (cd > spot_dir_cos.w) {
                    float cone = smoothstep(spot_dir_cos.w, min(spot_dir_cos.w + 0.15, 0.99), cd);
                    float att = clamp(1.0 - sdist / spot_pos_range.w, 0.0, 1.0);
                    step_light += spot_col_on.rgb * (att * att * cone * 0.45);
                }
            }
        }

        float step_ext = exp(-density * step_len);
        accum += transmittance * step_light * (1.0 - step_ext);
        transmittance *= step_ext;
    }

    vec3 out_scatter = accum * fog_col_scat.w;
    frag_color = vec4(clamp(out_scatter, vec3(0.0), vec3(50.0)), 1.0);
}
