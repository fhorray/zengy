#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_sky_hdri;

layout(std140, set = 3, binding = 0) uniform SkyUniforms {
    mat4 inv_view_proj;
    vec4 sun_dir_size;        // xyz=to_sun, w=sun_size
    vec4 sky_zenith_thick;    // xyz=zenith, w=thickness
    vec4 sky_horizon_mode;    // xyz=horizon, w=mode (0=proc, 1=solid, 2=hdri)
    vec4 ground_solid;        // xyz=ground/solid, w=disk_mode (0=none,1=simple,2=hq) or hdri_ev
    vec4 sun_col_intensity;   // xyz=sun_color, w=intensity
};

layout(location = 0) out vec4 frag_color;

const float PI = 3.14159265359;

void main() {
    if (sky_horizon_mode.w > 0.5 && sky_horizon_mode.w < 1.5) {
        frag_color = vec4(ground_solid.rgb, 1.0);
        return;
    }

    vec4 near_p = inv_view_proj * vec4(v_ndc, 0.0, 1.0);
    vec4 far_p = inv_view_proj * vec4(v_ndc, 1.0, 1.0);
    vec3 dir = normalize(far_p.xyz / far_p.w - near_p.xyz / near_p.w);

    if (sky_horizon_mode.w >= 1.5) {
        float u = atan(dir.x, -dir.z) / (2.0 * PI) + 0.5;
        float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
        vec3 col = textureLod(u_sky_hdri, vec2(u, v), 0.0).rgb * exp2(sun_col_intensity.w);
        frag_color = vec4(max(col, vec3(0.0)), 1.0);
        return;
    }

    float h = clamp(dir.y, -1.0, 1.0);
    float up_t = pow(clamp(h, 0.0, 1.0), 0.55);
    vec3 sky = mix(sky_horizon_mode.rgb, sky_zenith_thick.rgb, up_t);
    if (h < 0.0) {
        sky = mix(sky_horizon_mode.rgb, ground_solid.rgb, clamp(-h * 4.0, 0.0, 1.0));
    }

    // Sunset horizon warmth & Mie sun halo.
    vec3 sun_dir = normalize(sun_dir_size.xyz);
    float sun_elev = clamp(1.0 - abs(sun_dir.y) * 2.0, 0.0, 1.0);
    float cos_theta = clamp(dot(dir, sun_dir), 0.0, 1.0);
    vec3 sunset_tint = vec3(1.0, 0.55, 0.25);
    sky = mix(sky, sunset_tint * 1.4, pow(1.0 - abs(h), 4.0) * sun_elev * 0.45 * sky_zenith_thick.w);

    // Sun disc + soft corona.
    if (ground_solid.w > 0.5) {
        float r = max(sun_dir_size.w, 0.005);
        float ang = acos(cos_theta);
        float disc = 1.0 - smoothstep(r * 0.85, r * 1.15, ang);
        float halo = (ground_solid.w > 1.5) ? pow(cos_theta, 32.0) * 0.45 : 0.0;
        sky += sun_col_intensity.rgb * (disc * sun_col_intensity.w * 4.0 + halo * sun_col_intensity.w);
    }

    frag_color = vec4(max(sky, vec3(0.0)), 1.0);
}
