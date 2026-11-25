// Ported from sky.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct SkyUniforms {
    inv_view_proj: mat4x4<f32>,
    sun_dir_size: vec4<f32>,
    sky_zenith_thick: vec4<f32>,
    sky_horizon_mode: vec4<f32>,
    ground_solid: vec4<f32>,
    sun_col_intensity: vec4<f32>,
    hdri_rotation: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

const PI: f32 = 3.1415927f;

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_sky_hdri_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_sky_hdri_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: SkyUniforms;
var<private> frag_color: vec4<f32>;

fn main_1() {
    var near_p: vec4<f32>;
    var far_p: vec4<f32>;
    var dir: vec3<f32>;
    var u: f32;
    var v: f32;
    var col: vec3<f32>;
    var h: f32;
    var up_t: f32;
    var sky: vec3<f32>;
    var sun_dir: vec3<f32>;
    var sun_elev: f32;
    var cos_theta: f32;
    var sunset_tint: vec3<f32> = vec3<f32>(1f, 0.55f, 0.25f);
    var r: f32;
    var ang: f32;
    var disc: f32;
    var local: f32;
    var halo: f32;

    let _e19 = global.sky_horizon_mode;
    let _e23 = global.sky_horizon_mode;
    if ((_e19.w > 0.5f) && (_e23.w < 1.5f)) {
        {
            let _e28 = global.ground_solid;
            let _e30 = global.hdri_rotation;
            let _e32 = (_e28.xyz * _e30.y);
            frag_color = vec4<f32>(_e32.x, _e32.y, _e32.z, 1f);
            return;
        }
    }
    let _e38 = global.inv_view_proj;
    let _e39 = v_ndc_1;
    near_p = (_e38 * vec4<f32>(_e39.x, _e39.y, 0f, 1f));
    let _e47 = global.inv_view_proj;
    let _e48 = v_ndc_1;
    far_p = (_e47 * vec4<f32>(_e48.x, _e48.y, 1f, 1f));
    let _e56 = far_p;
    let _e58 = far_p;
    let _e62 = near_p;
    let _e64 = near_p;
    dir = normalize(((_e56.xyz / vec3(_e58.w)) - (_e62.xyz / vec3(_e64.w))));
    let _e71 = global.sky_horizon_mode;
    if (_e71.w >= 1.5f) {
        {
            let _e75 = dir;
            let _e77 = dir;
            let _e87 = global.hdri_rotation;
            u = (((atan2(_e75.x, -(_e77.z)) / 6.2831855f) + 0.5f) + _e87.x);
            let _e91 = dir;
            v = (acos(clamp(_e91.y, -1f, 1f)) / PI);
            let _e100 = u;
            let _e101 = v;
            let _e104 = textureSampleLevel(zengy_u_sky_hdri_image, zengy_u_sky_hdri_sampler, vec2<f32>(_e100, _e101), 0f);
            let _e106 = global.sun_col_intensity;
            col = (_e104.xyz * exp2(_e106.w));
            let _e111 = col;
            let _e112 = global.hdri_rotation;
            let _e119 = clamp((_e111 * _e112.y), vec3(0f), vec3(65000f));
            frag_color = vec4<f32>(_e119.x, _e119.y, _e119.z, 1f);
            return;
        }
    }
    let _e125 = dir;
    h = clamp(_e125.y, -1f, 1f);
    let _e132 = h;
    up_t = pow(clamp(_e132, 0f, 1f), 0.55f);
    let _e139 = global.sky_horizon_mode;
    let _e141 = global.sky_zenith_thick;
    let _e143 = up_t;
    sky = mix(_e139.xyz, _e141.xyz, vec3(_e143));
    let _e147 = h;
    if (_e147 < 0f) {
        {
            let _e150 = global.sky_horizon_mode;
            let _e152 = global.ground_solid;
            let _e154 = h;
            sky = mix(_e150.xyz, _e152.xyz, vec3(clamp((-(_e154) * 4f), 0f, 1f)));
        }
    }
    let _e163 = global.sun_dir_size;
    sun_dir = normalize(_e163.xyz);
    let _e168 = sun_dir;
    sun_elev = clamp((1f - (abs(_e168.y) * 2f)), 0f, 1f);
    let _e178 = dir;
    let _e179 = sun_dir;
    cos_theta = clamp(dot(_e178, _e179), 0f, 1f);
    let _e190 = sky;
    let _e191 = sunset_tint;
    let _e195 = h;
    let _e200 = sun_elev;
    let _e204 = global.sky_zenith_thick;
    sky = mix(_e190, (_e191 * 1.4f), vec3((((pow((1f - abs(_e195)), 4f) * _e200) * 0.45f) * _e204.w)));
    let _e209 = global.ground_solid;
    if (_e209.w > 0.5f) {
        {
            let _e213 = global.sun_dir_size;
            r = max(_e213.w, 0.005f);
            let _e218 = cos_theta;
            ang = acos(_e218);
            let _e222 = r;
            let _e225 = r;
            let _e228 = ang;
            disc = (1f - smoothstep((_e222 * 0.85f), (_e225 * 1.15f), _e228));
            let _e232 = global.ground_solid;
            if (_e232.w > 1.5f) {
                let _e236 = cos_theta;
                local = (pow(_e236, 32f) * 0.45f);
            } else {
                local = 0f;
            }
            let _e243 = local;
            halo = _e243;
            let _e245 = sky;
            let _e246 = global.sun_col_intensity;
            let _e248 = disc;
            let _e249 = global.sun_col_intensity;
            let _e254 = halo;
            let _e255 = global.sun_col_intensity;
            sky = (_e245 + (_e246.xyz * (((_e248 * _e249.w) * 4f) + (_e254 * _e255.w))));
        }
    }
    let _e261 = sky;
    let _e265 = global.hdri_rotation;
    let _e267 = (max(_e261, vec3(0f)) * _e265.y);
    frag_color = vec4<f32>(_e267.x, _e267.y, _e267.z, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e27 = frag_color;
    return FragmentOutput(_e27);
}
