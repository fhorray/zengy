#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_depth;

layout(std140, set = 3, binding = 0) uniform SsaoParams {
    mat4 proj;
    mat4 inv_proj;
    vec4 params;         // x=radius, y=bias, z=intensity, w=ssao_enabled
    vec4 sun_view_dir;   // xyz=to_sun in view space, w=contact_length
    vec4 contact_params; // x=opacity, y=thickness, z=sample_count, w=contact_enabled
};

layout(location = 0) out vec4 frag_color;

vec3 reconstructViewPos(vec2 uv, float depth) {
    vec4 ndc = vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    vec4 vp = inv_proj * ndc;
    return vp.xyz / max(vp.w, 1e-5);
}

float hash12(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
    if (params.w < 0.5 && contact_params.w < 0.5) {
        frag_color = vec4(1.0);
        return;
    }
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    float d = texture(u_depth, uv).r;
    if (d >= 0.9999) {
        frag_color = vec4(1.0);
        return;
    }

    vec3 pos = reconstructViewPos(uv, d);
    vec2 texel = 1.0 / vec2(textureSize(u_depth, 0));
    vec3 px = reconstructViewPos(uv + vec2(texel.x, 0.0), texture(u_depth, uv + vec2(texel.x, 0.0)).r);
    vec3 py = reconstructViewPos(uv + vec2(0.0, texel.y), texture(u_depth, uv + vec2(0.0, texel.y)).r);
    vec3 N = normalize(cross(py - pos, px - pos));

    float dist_fade = 1.0 - smoothstep(18.0, 38.0, abs(pos.z));
    float ao = 1.0;
    if (params.w > 0.5 && dist_fade > 0.01) {
        float radius = params.x;
        float bias = params.y + 0.004 * abs(pos.z);
        float occ = 0.0;
        float rot = hash12(gl_FragCoord.xy) * 6.2831853;

        for (int i = 0; i < 12; ++i) {
            float fi = float(i);
            float ang = rot + fi * 2.3999632; // golden angle
            float r = sqrt((fi + 0.5) / 12.0) * radius;
            vec3 offset = vec3(cos(ang), sin(ang), 0.35 + 0.4 * fract(fi * 0.37));
            vec3 dir = normalize(offset);
            if (dot(dir, N) < 0.0) dir = -dir;
            dir = normalize(dir + N * 0.25);
            vec3 sp = pos + dir * r;

            vec4 clip = proj * vec4(sp, 1.0);
            vec2 suv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;

            float sd = texture(u_depth, suv).r;
            vec3 sample_vp = reconstructViewPos(suv, sd);
            float range_check = smoothstep(0.0, 1.0, radius / max(abs(pos.z - sample_vp.z), 0.001));
            occ += ((sample_vp.z >= sp.z + bias) ? 1.0 : 0.0) * range_check;
        }
        ao = clamp(1.0 - (occ / 12.0) * params.z * dist_fade, 0.05, 1.0);
    }

    float contact = 1.0;
    if (contact_params.w > 0.5 && dist_fade > 0.01) {
        vec3 ldir_v = normalize(sun_view_dir.xyz);
        float ndotl_v = dot(N, ldir_v);
        // Only march contact rays on surfaces facing the light to prevent grazing self-occlusion lines.
        if (ndotl_v > 0.08) {
            float step_len = sun_view_dir.w / max(contact_params.z, 4.0);
            float occ_c = 0.0;
            float slope_bias = (0.03 + 0.012 * abs(pos.z)) / max(ndotl_v, 0.25);
            vec3 start_pos = pos + N * slope_bias;
            float jitter = hash12(gl_FragCoord.xy + vec2(17.0, 31.0));
            for (int i = 1; i <= 16; ++i) {
                if (float(i) > contact_params.z) break;
                vec3 rp = start_pos + ldir_v * ((float(i) - 0.5 + jitter * 0.5) * step_len);
                vec4 rclip = proj * vec4(rp, 1.0);
                vec2 ruv = vec2(rclip.x / rclip.w * 0.5 + 0.5, 0.5 - rclip.y / rclip.w * 0.5);
                if (ruv.x < 0.0 || ruv.x > 1.0 || ruv.y < 0.0 || ruv.y > 1.0) break;
                float rd = texture(u_depth, ruv).r;
                vec3 rvp = reconstructViewPos(ruv, rd);
                float dz = rvp.z - rp.z;
                if (dz > slope_bias && dz < contact_params.y + slope_bias) {
                    occ_c = 1.0;
                    break;
                }
            }
            float fade_n = smoothstep(0.08, 0.28, ndotl_v);
            contact = 1.0 - occ_c * contact_params.x * dist_fade * fade_n;
        }
    }

    frag_color = vec4(ao, contact, 1.0, 1.0);
}
