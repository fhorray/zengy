#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_depth;

layout(std140, set = 3, binding = 0) uniform SsaoParams {
    mat4 proj;
    mat4 inv_proj;
    vec4 params;         // x=radius, y=bias, z=intensity, w=ssao_enabled
    vec4 sun_view_dir;   // xyz=to_sun in view space, w=contact_length
    vec4 contact_params; // x=opacity, y=thickness, z=sample_count, w=contact_enabled
    vec4 fade_range;     // x=view distance where the fade starts, y=where it reaches zero
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
    vec2 ux = clamp(uv + vec2(texel.x, 0), vec2(0), vec2(1));
    vec2 lx = clamp(uv - vec2(texel.x, 0), vec2(0), vec2(1));
    vec2 uy = clamp(uv + vec2(0, texel.y), vec2(0), vec2(1));
    vec2 ly = clamp(uv - vec2(0, texel.y), vec2(0), vec2(1));
    float dr = texture(u_depth, ux).r;
    float dl = texture(u_depth, lx).r;
    float dd = texture(u_depth, uy).r;
    float du = texture(u_depth, ly).r;
    vec3 right = reconstructViewPos(ux, dr) - pos;
    vec3 left = pos - reconstructViewPos(lx, dl);
    vec3 down = reconstructViewPos(uy, dd) - pos;
    vec3 up = pos - reconstructViewPos(ly, du);
    bool right_valid = dot(right,right) > 1e-12 && dr < 0.9999;
    bool left_valid = dot(left,left) > 1e-12 && dl < 0.9999;
    bool down_valid = dot(down,down) > 1e-12 && dd < 0.9999;
    bool up_valid = dot(up,up) > 1e-12 && du < 0.9999;
    vec3 dx = right_valid && (!left_valid || abs(right.z) < abs(left.z)) ? right : (left_valid ? left : vec3(0));
    vec3 dy = down_valid && (!up_valid || abs(down.z) < abs(up.z)) ? down : (up_valid ? up : vec3(0));
    vec3 nn = cross(dy, dx);
    vec3 N = dot(nn,nn) > 1e-12 ? normalize(nn) : -pos * inversesqrt(max(dot(pos,pos),1e-12));
    if (dot(N, -pos) < 0.0) N = -N;

    // Shared distance fade for AO and contact shadows, driven by ContactShadowSettings.distance_fade.
    float dist_fade = 1.0 - smoothstep(max(fade_range.x, 0.0), max(fade_range.y, max(fade_range.x, 0.0) + 0.001), abs(pos.z));
    float ao = 1.0;
    if (params.w > 0.5 && dist_fade > 0.01) {
        float radius = max(params.x, 0.001);
        float bias = max(params.y, 0.0) + 0.004 * abs(pos.z);
        float occ = 0.0;
        float rot = hash12(gl_FragCoord.xy) * 6.2831853;

        if (fade_range.z > 0.5) {
            // Four horizon directions, three samples each. Same tap budget as legacy SSAO.
            vec2 radius_uv = abs(vec2(proj[0][0], proj[1][1])) * radius / max(abs(pos.z)*2.0,0.001);
            for (int i=0; i<4; ++i) {
                float ang = rot + float(i)*1.57079632679;
                vec2 axis = vec2(cos(ang),sin(ang));
                float horizon = 0.0;
                for (int j=1; j<=3; ++j) {
                    vec2 suv = uv + axis*radius_uv*(float(j)/3.0);
                    if (any(lessThan(suv,vec2(0.0))) || any(greaterThan(suv,vec2(1.0)))) continue;
                    float sd = texture(u_depth,suv).r;
                    if (sd >= 0.9999) continue;
                    vec3 delta = reconstructViewPos(suv,sd)-pos;
                    float len = length(delta);
                    if (len <= max(bias,0.0001) || len >= radius) continue;
                    float falloff = 1.0-smoothstep(radius*0.25,radius,len);
                    horizon = max(horizon,max(dot(N,delta/len)-bias/len,0.0)*falloff);
                }
                occ += horizon*3.0;
            }
        } else for (int i = 0; i < 12; ++i) {
            float fi = float(i);
            float ang = rot + fi * 2.3999632; // golden angle
            float r = sqrt((fi + 0.5) / 12.0) * radius;
            vec3 offset = vec3(cos(ang), sin(ang), 0.35 + 0.4 * fract(fi * 0.37));
            vec3 dir = normalize(offset);
            if (dot(dir, N) < 0.0) dir = -dir;
            dir = normalize(dir + N * 0.25);
            vec3 sp = pos + dir * r;

            vec4 clip = proj * vec4(sp, 1.0);
            if (clip.w <= 0.0001) continue;
            vec2 suv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;

            float sd = texture(u_depth, suv).r;
            if (sd >= 0.9999) continue;
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
                if (rclip.w <= 0.0001) break;
                vec2 ruv = vec2(rclip.x / rclip.w * 0.5 + 0.5, 0.5 - rclip.y / rclip.w * 0.5);
                if (ruv.x < 0.0 || ruv.x > 1.0 || ruv.y < 0.0 || ruv.y > 1.0) break;
                float rd = texture(u_depth, ruv).r;
                if (rd >= 0.9999) continue;
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
