// Ported from volumetric_fog.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct VolFogParams {
    inv_view_proj: mat4x4<f32>,
    light_vp: array<mat4x4<f32>, 4>,
    cam_pos_density: vec4<f32>,
    sun_dir_int: vec4<f32>,
    sun_col_aniso: vec4<f32>,
    fog_col_scat: vec4<f32>,
    cascade_splits: vec4<f32>,
    cam_fwd_maxd: vec4<f32>,
    spot_pos_range: array<vec4<f32>, 4>,
    spot_dir_cos: array<vec4<f32>, 4>,
    spot_col_on: array<vec4<f32>, 4>,
    spot_shadow: array<vec4<f32>, 4>,
    point_pos: array<vec4<f32>, 4>,
    point_col: array<vec4<f32>, 4>,
    point_shadow: array<vec4<f32>, 4>,
    local_vp: array<mat4x4<f32>, 16>,
    local_rect: array<vec4<f32>, 16>,
    cascade_info: vec4<f32>,
    froxel_params: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

const PI: f32 = 3.1415927f;

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_depth_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_shadow_tex_image: texture_depth_2d;
@group(0) @binding(33) 
var zengy_u_shadow_tex_sampler: sampler_comparison;
@group(0) @binding(2) 
var zengy_u_local_shadow_tex_image: texture_depth_2d;
@group(0) @binding(34) 
var zengy_u_local_shadow_tex_sampler: sampler_comparison;
@group(1) @binding(0) 
var<uniform> global: VolFogParams;
var<private> frag_color: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;

fn ign(p: vec2<f32>) -> f32 {
    var p_1: vec2<f32>;

    p_1 = p;
    let _e50 = p_1;
    return fract((52.982918f * fract(dot(_e50, vec2<f32>(0.06711056f, 0.00583715f)))));
}

fn henyeyGreenstein(cos_theta: f32, g: f32) -> f32 {
    var cos_theta_1: f32;
    var g_1: f32;
    var g2_: f32;

    cos_theta_1 = cos_theta;
    g_1 = g;
    let _e51 = g_1;
    let _e52 = g_1;
    g2_ = (_e51 * _e52);
    let _e56 = g2_;
    let _e62 = g2_;
    let _e65 = g_1;
    let _e67 = cos_theta_1;
    return ((1f - _e56) / (12.566371f * pow(max(((1f + _e62) - ((2f * _e65) * _e67)), 0.05f), 1.5f)));
}

fn sampleVolShadow(wp: vec3<f32>, view_depth: f32) -> f32 {
    var wp_1: vec3<f32>;
    var view_depth_1: f32;
    var count: i32;
    var idx: i32 = 0i;
    var i: i32 = 0i;
    var k: i32;
    var lp: vec4<f32>;
    var proj: vec3<f32>;
    var uv: vec2<f32>;
    var q_min: vec2<f32>;
    var suv: vec2<f32>;

    wp_1 = wp;
    view_depth_1 = view_depth;
    let _e51 = global.cascade_info;
    count = clamp(i32((_e51.x + 0.5f)), 0i, 4i);
    let _e60 = global.cascade_splits;
    let _e64 = count;
    if ((_e60.w < 0f) || (_e64 == 0i)) {
        return 1f;
    }
    loop {
        let _e73 = i;
        if !((_e73 < 3i)) {
            break;
        }
        {
            let _e80 = i;
            let _e81 = count;
            let _e85 = view_depth_1;
            let _e86 = i;
            let _e88 = global.cascade_splits[_e86];
            if ((_e80 < (_e81 - 1i)) && (_e85 > _e88)) {
                let _e91 = i;
                idx = (_e91 + 1i);
            }
        }
        continuing {
            let _e77 = i;
            i = (_e77 + 1i);
        }
    }
    let _e94 = idx;
    k = _e94;
    loop {
        let _e96 = k;
        let _e97 = count;
        if !((_e96 < _e97)) {
            break;
        }
        {
            let _e103 = k;
            let _e105 = global.light_vp[_e103];
            let _e106 = wp_1;
            lp = (_e105 * vec4<f32>(_e106.x, _e106.y, _e106.z, 1f));
            let _e114 = lp;
            let _e116 = lp;
            proj = (_e114.xyz / vec3(max(_e116.w, 0.0001f)));
            let _e123 = proj;
            let _e130 = proj;
            uv = vec2<f32>(((_e123.x * 0.5f) + 0.5f), (0.5f - (_e130.y * 0.5f)));
            let _e137 = uv;
            let _e141 = uv;
            let _e146 = uv;
            let _e151 = uv;
            let _e156 = proj;
            let _e161 = proj;
            if ((((((_e137.x >= 0.01f) && (_e141.x <= 0.99f)) && (_e146.y >= 0.01f)) && (_e151.y <= 0.99f)) && (_e156.z >= 0f)) && (_e161.z <= 1f)) {
                {
                    let _e166 = k;
                    let _e172 = k;
                    q_min = vec2<f32>((f32((_e166 & 1i)) * 0.5f), (f32((_e172 >> 1u)) * 0.5f));
                    let _e181 = q_min;
                    let _e182 = uv;
                    suv = (_e181 + (_e182 * 0.5f));
                    let _e187 = suv;
                    let _e188 = proj;
                    let _e194 = vec3<f32>(_e187.x, _e187.y, (_e188.z - 0.0006f));
                    let _e197 = textureSampleCompare(zengy_u_shadow_tex_image, zengy_u_shadow_tex_sampler, _e194.xy, _e194.z);
                    return _e197;
                }
            }
        }
        continuing {
            let _e100 = k;
            k = (_e100 + 1i);
        }
    }
    return 1f;
}

fn sampleLocalTile(tile: i32, wp_2: vec3<f32>) -> f32 {
    var tile_1: i32;
    var wp_3: vec3<f32>;
    var lp_1: vec4<f32>;
    var proj_1: vec3<f32>;
    var uv_1: vec2<f32>;
    var suv_1: vec2<f32>;

    tile_1 = tile;
    wp_3 = wp_2;
    let _e51 = tile_1;
    let _e54 = tile_1;
    if ((_e51 < 0i) || (_e54 >= 16i)) {
        return 1f;
    }
    let _e59 = tile_1;
    let _e61 = global.local_vp[_e59];
    let _e62 = wp_3;
    lp_1 = (_e61 * vec4<f32>(_e62.x, _e62.y, _e62.z, 1f));
    let _e70 = lp_1;
    if (_e70.w <= 0.0001f) {
        return 1f;
    }
    let _e75 = lp_1;
    let _e77 = lp_1;
    proj_1 = (_e75.xyz / vec3(_e77.w));
    let _e82 = proj_1;
    let _e89 = proj_1;
    uv_1 = vec2<f32>(((_e82.x * 0.5f) + 0.5f), (0.5f - (_e89.y * 0.5f)));
    let _e96 = uv_1;
    let _e100 = uv_1;
    let _e105 = uv_1;
    let _e110 = uv_1;
    let _e115 = proj_1;
    let _e120 = proj_1;
    if ((((((_e96.x < 0.005f) || (_e100.x > 0.995f)) || (_e105.y < 0.005f)) || (_e110.y > 0.995f)) || (_e115.z < 0f)) || (_e120.z > 1f)) {
        return 1f;
    }
    let _e126 = tile_1;
    let _e128 = global.local_rect[_e126];
    let _e130 = uv_1;
    let _e131 = tile_1;
    let _e133 = global.local_rect[_e131];
    suv_1 = (_e128.xy + (_e130 * _e133.z));
    let _e138 = suv_1;
    let _e139 = proj_1;
    let _e145 = vec3<f32>(_e138.x, _e138.y, (_e139.z - 0.001f));
    let _e148 = textureSampleCompare(zengy_u_local_shadow_tex_image, zengy_u_local_shadow_tex_sampler, _e145.xy, _e145.z);
    return _e148;
}

fn samplePointShadow(j: i32, wp_4: vec3<f32>) -> f32 {
    var j_1: i32;
    var wp_5: vec3<f32>;
    var d: vec3<f32>;
    var a: vec3<f32>;
    var face: i32;
    var local: i32;
    var local_1: i32;
    var local_2: i32;

    j_1 = j;
    wp_5 = wp_4;
    let _e51 = j_1;
    let _e53 = global.point_shadow[_e51];
    if (_e53.y < 0.5f) {
        return 1f;
    }
    let _e58 = wp_5;
    let _e59 = j_1;
    let _e61 = global.point_pos[_e59];
    d = (_e58 - _e61.xyz);
    let _e65 = d;
    a = abs(_e65);
    let _e69 = a;
    let _e71 = a;
    let _e74 = a;
    let _e76 = a;
    if ((_e69.x >= _e71.y) && (_e74.x >= _e76.z)) {
        let _e80 = d;
        if (_e80.x >= 0f) {
            local = 0i;
        } else {
            local = 1i;
        }
        let _e87 = local;
        face = _e87;
    } else {
        let _e88 = a;
        let _e90 = a;
        if (_e88.y >= _e90.z) {
            let _e93 = d;
            if (_e93.y >= 0f) {
                local_1 = 2i;
            } else {
                local_1 = 3i;
            }
            let _e100 = local_1;
            face = _e100;
        } else {
            let _e101 = d;
            if (_e101.z >= 0f) {
                local_2 = 4i;
            } else {
                local_2 = 5i;
            }
            let _e108 = local_2;
            face = _e108;
        }
    }
    let _e109 = j_1;
    let _e111 = global.point_shadow[_e109];
    let _e116 = face;
    let _e118 = wp_5;
    let _e119 = sampleLocalTile((i32((_e111.x + 0.5f)) + _e116), _e118);
    return _e119;
}

fn evaluateStepLight(p_2: vec3<f32>, vd: f32, phase: f32, ray_dir: vec3<f32>) -> vec3<f32> {
    var p_3: vec3<f32>;
    var vd_1: f32;
    var phase_1: f32;
    var ray_dir_1: vec3<f32>;
    var local_3: f32;
    var vis: f32;
    var local_4: f32;
    var step_light: vec3<f32>;
    var j_2: i32 = 0i;
    var to_pt: vec3<f32>;
    var pdist2_: f32;
    var prange: f32;
    var pdist: f32;
    var win: f32;
    var att: f32;
    var pt_phase: f32;
    var j_3: i32 = 0i;
    var to_sp: vec3<f32>;
    var sdist2_: f32;
    var range: f32;
    var sdist: f32;
    var sdir: vec3<f32>;
    var cd: f32;
    var cone: f32;
    var win_1: f32;
    var att_1: f32;
    var local_5: f32;
    var sp_sv: f32;
    var sp_phase: f32;

    p_3 = p_2;
    vd_1 = vd;
    phase_1 = phase;
    ray_dir_1 = ray_dir;
    let _e55 = global.sun_dir_int;
    if (_e55.w > 0f) {
        let _e59 = p_3;
        let _e60 = vd_1;
        let _e61 = sampleVolShadow(_e59, _e60);
        local_3 = _e61;
    } else {
        local_3 = 0f;
    }
    let _e64 = local_3;
    vis = _e64;
    let _e66 = global.sun_col_aniso;
    let _e68 = global.sun_dir_int;
    let _e70 = phase_1;
    let _e72 = vis;
    let _e74 = global.cascade_info;
    if (_e74.w > 0.5f) {
        local_4 = 1f;
    } else {
        local_4 = 0.72f;
    }
    let _e81 = local_4;
    step_light = (_e66.xyz * (((_e68.w * _e70) * _e72) * _e81));
    loop {
        let _e87 = j_2;
        if !((_e87 < 4i)) {
            break;
        }
        {
            let _e94 = j_2;
            let _e96 = global.point_col[_e94];
            if (_e96.w < 0.5f) {
                continue;
            }
            let _e100 = p_3;
            let _e101 = j_2;
            let _e103 = global.point_pos[_e101];
            to_pt = (_e100 - _e103.xyz);
            let _e107 = to_pt;
            let _e108 = to_pt;
            pdist2_ = dot(_e107, _e108);
            let _e111 = j_2;
            let _e113 = global.point_pos[_e111];
            prange = _e113.w;
            let _e116 = prange;
            let _e119 = pdist2_;
            let _e120 = prange;
            let _e121 = prange;
            if ((_e116 <= 0f) || (_e119 >= (_e120 * _e121))) {
                continue;
            }
            let _e125 = pdist2_;
            pdist = sqrt(_e125);
            let _e129 = pdist;
            let _e130 = prange;
            win = clamp((1f - (_e129 / _e130)), 0f, 1f);
            let _e137 = win;
            let _e138 = win;
            let _e141 = pdist2_;
            att = ((_e137 * _e138) / max((0.35f + (_e141 * 0.55f)), 0.12f));
            let _e150 = ray_dir_1;
            let _e151 = to_pt;
            let _e153 = pdist;
            let _e160 = henyeyGreenstein(dot(_e150, (-(_e151) / vec3(max(_e153, 0.0001f)))), 0.3f);
            pt_phase = mix(0.25f, _e160, 0.5f);
            let _e164 = step_light;
            let _e165 = j_2;
            let _e167 = global.point_col[_e165];
            let _e169 = att;
            let _e170 = pt_phase;
            let _e174 = j_2;
            let _e175 = p_3;
            let _e176 = samplePointShadow(_e174, _e175);
            step_light = (_e164 + (_e167.xyz * (((_e169 * _e170) * 0.85f) * _e176)));
        }
        continuing {
            let _e91 = j_2;
            j_2 = (_e91 + 1i);
        }
    }
    loop {
        let _e182 = j_3;
        if !((_e182 < 4i)) {
            break;
        }
        {
            let _e189 = j_3;
            let _e191 = global.spot_col_on[_e189];
            if (_e191.w < 0.5f) {
                continue;
            }
            let _e195 = p_3;
            let _e196 = j_3;
            let _e198 = global.spot_pos_range[_e196];
            to_sp = (_e195 - _e198.xyz);
            let _e202 = to_sp;
            let _e203 = to_sp;
            sdist2_ = dot(_e202, _e203);
            let _e206 = j_3;
            let _e208 = global.spot_pos_range[_e206];
            range = _e208.w;
            let _e211 = range;
            let _e214 = sdist2_;
            let _e215 = range;
            let _e216 = range;
            if ((_e211 <= 0f) || (_e214 >= (_e215 * _e216))) {
                continue;
            }
            let _e220 = sdist2_;
            sdist = sqrt(_e220);
            let _e223 = to_sp;
            let _e224 = sdist;
            sdir = (_e223 / vec3(max(_e224, 0.0001f)));
            let _e230 = sdir;
            let _e231 = j_3;
            let _e233 = global.spot_dir_cos[_e231];
            cd = dot(_e230, normalize(_e233.xyz));
            let _e238 = cd;
            let _e239 = j_3;
            let _e241 = global.spot_dir_cos[_e239];
            if (_e238 > _e241.w) {
                {
                    let _e244 = j_3;
                    let _e246 = global.spot_dir_cos[_e244];
                    let _e248 = j_3;
                    let _e250 = global.spot_dir_cos[_e248];
                    let _e254 = j_3;
                    let _e256 = global.spot_dir_cos[_e254];
                    let _e263 = cd;
                    cone = smoothstep(_e246.w, max((_e250.w + 0.001f), min((_e256.w + 0.14f), 0.99f)), _e263);
                    let _e267 = sdist;
                    let _e268 = range;
                    win_1 = clamp((1f - (_e267 / _e268)), 0f, 1f);
                    let _e275 = win_1;
                    let _e276 = win_1;
                    let _e279 = sdist2_;
                    att_1 = ((_e275 * _e276) / max((0.35f + (_e279 * 0.25f)), 0.12f));
                    let _e287 = j_3;
                    let _e289 = global.spot_shadow[_e287];
                    if (_e289.y > 0.5f) {
                        let _e293 = j_3;
                        let _e295 = global.spot_shadow[_e293];
                        let _e300 = p_3;
                        let _e301 = sampleLocalTile(i32((_e295.x + 0.5f)), _e300);
                        local_5 = _e301;
                    } else {
                        local_5 = 1f;
                    }
                    let _e304 = local_5;
                    sp_sv = _e304;
                    let _e307 = ray_dir_1;
                    let _e308 = sdir;
                    let _e312 = henyeyGreenstein(dot(_e307, -(_e308)), 0.35f);
                    sp_phase = mix(0.25f, _e312, 0.5f);
                    let _e316 = step_light;
                    let _e317 = j_3;
                    let _e319 = global.spot_col_on[_e317];
                    let _e321 = att_1;
                    let _e322 = cone;
                    let _e324 = sp_sv;
                    let _e326 = sp_phase;
                    step_light = (_e316 + (_e319.xyz * ((((_e321 * _e322) * _e324) * _e326) * 1.15f)));
                }
            }
        }
        continuing {
            let _e186 = j_3;
            j_3 = (_e186 + 1i);
        }
    }
    let _e332 = step_light;
    return _e332;
}

fn injectFroxel() {
    var w: f32;
    var h: f32;
    var count_1: f32;
    var slice: f32;
    var uv_2: vec2<f32>;
    var ndc: vec2<f32>;
    var wp_6: vec4<f32>;
    var ray: vec3<f32>;
    var dir: vec3<f32>;
    var max_dist: f32;
    var lo: f32;
    var hi: f32;
    var distance: f32;
    var p_4: vec3<f32>;
    var fwd: vec3<f32>;
    var sun: vec3<f32>;
    var hg: f32;
    var local_6: f32;
    var phase_2: f32;
    var density: f32;
    var local_7: f32;
    var scattering: f32;
    var source: vec3<f32>;

    let _e47 = global.froxel_params;
    w = _e47.x;
    let _e50 = global.froxel_params;
    h = _e50.y;
    let _e53 = global.froxel_params;
    count_1 = _e53.z;
    let _e57 = gl_FragCoord_1;
    let _e59 = h;
    slice = floor((_e57.y / _e59));
    let _e63 = gl_FragCoord_1;
    let _e65 = w;
    let _e67 = gl_FragCoord_1;
    let _e69 = h;
    let _e74 = h;
    uv_2 = vec2<f32>((_e63.x / _e65), ((_e67.y - (floor((_e67.y / _e69)) * _e69)) / _e74));
    let _e78 = uv_2;
    let _e85 = uv_2;
    ndc = vec2<f32>(((_e78.x * 2f) - 1f), (1f - (_e85.y * 2f)));
    let _e92 = global.inv_view_proj;
    let _e93 = ndc;
    wp_6 = (_e92 * vec4<f32>(_e93.x, _e93.y, 1f, 1f));
    let _e101 = wp_6;
    let _e103 = wp_6;
    let _e109 = global.cam_pos_density;
    ray = ((_e101.xyz / vec3(max(_e103.w, 0.00001f))) - _e109.xyz);
    let _e113 = ray;
    let _e114 = ray;
    let _e115 = ray;
    dir = (_e113 * inverseSqrt(max(dot(_e114, _e115), 0.000000000001f)));
    let _e122 = global.cam_fwd_maxd;
    max_dist = max(_e122.w, 0.1f);
    let _e127 = max_dist;
    let _e129 = slice;
    let _e131 = count_1;
    lo = ((_e127 * (exp2(((4f * _e129) / _e131)) - 1f)) / 15f);
    let _e140 = max_dist;
    let _e142 = slice;
    let _e146 = count_1;
    hi = ((_e140 * (exp2(((4f * (_e142 + 1f)) / _e146)) - 1f)) / 15f);
    let _e155 = lo;
    let _e156 = hi;
    distance = mix(_e155, _e156, 0.5f);
    let _e160 = global.cam_pos_density;
    let _e162 = dir;
    let _e163 = distance;
    p_4 = (_e160.xyz + (_e162 * _e163));
    let _e167 = global.cam_fwd_maxd;
    let _e169 = global.cam_fwd_maxd;
    let _e171 = global.cam_fwd_maxd;
    fwd = (_e167.xyz * inverseSqrt(max(dot(_e169.xyz, _e171.xyz), 0.000000000001f)));
    let _e179 = global.sun_dir_int;
    let _e181 = global.sun_dir_int;
    let _e183 = global.sun_dir_int;
    sun = (_e179.xyz * inverseSqrt(max(dot(_e181.xyz, _e183.xyz), 0.000000000001f)));
    let _e191 = dir;
    let _e192 = sun;
    let _e194 = global.sun_col_aniso;
    let _e200 = henyeyGreenstein(dot(_e191, _e192), clamp(_e194.w, -0.85f, 0.85f));
    hg = _e200;
    let _e202 = global.cascade_info;
    if (_e202.w > 0.5f) {
        let _e206 = hg;
        local_6 = _e206;
    } else {
        let _e208 = hg;
        local_6 = mix(0.2f, _e208, 0.65f);
    }
    let _e212 = local_6;
    phase_2 = _e212;
    let _e214 = global.cam_pos_density;
    density = max(_e214.w, 0f);
    let _e219 = global.cascade_info;
    if (_e219.w > 0.5f) {
        let _e223 = density;
        let _e224 = global.fog_col_scat;
        local_7 = (_e223 * clamp(_e224.w, 0f, 1f));
    } else {
        let _e230 = global.fog_col_scat;
        local_7 = (max(_e230.w, 0f) * 0.18f);
    }
    let _e237 = local_7;
    scattering = _e237;
    let _e239 = scattering;
    if (_e239 <= 0f) {
        {
            frag_color = vec4(0f);
            return;
        }
    }
    let _e245 = p_4;
    let _e246 = p_4;
    let _e247 = global.cam_pos_density;
    let _e250 = fwd;
    let _e254 = phase_2;
    let _e255 = dir;
    let _e256 = evaluateStepLight(_e245, max(dot((_e246 - _e247.xyz), _e250), 0f), _e254, _e255);
    let _e257 = scattering;
    source = (_e256 * _e257);
    let _e260 = source;
    let _e267 = clamp(_e260, vec3(0f), vec3(65000f));
    frag_color = vec4<f32>(_e267.x, _e267.y, _e267.z, 0f);
    return;
}

fn main_1() {
    var uv_3: vec2<f32>;
    var d_1: f32;
    var local_8: f32;
    var far_ndc: vec4<f32>;
    var wp4_: vec4<f32>;
    var wp_7: vec3<f32>;
    var ray_1: vec3<f32>;
    var dist: f32;
    var ray_dir_2: vec3<f32>;
    var local_9: f32;
    var max_dist_1: f32;
    var sun_dir: vec3<f32>;
    var cam_fwd: vec3<f32>;
    var cos_theta_2: f32;
    var hg_1: f32;
    var local_10: f32;
    var phase_3: f32;
    var steps: i32;
    var step_len: f32;
    var jitter: f32;
    var ext_density: f32;
    var local_11: f32;
    var scat_coeff: f32;
    var step_ext: f32;
    var local_12: f32;
    var step_integral: f32;
    var accum: vec3<f32> = vec3(0f);
    var transmittance: f32 = 1f;
    var i_1: i32 = 0i;
    var t: f32;
    var p_5: vec3<f32>;
    var vd_2: f32;
    var step_light_1: vec3<f32>;

    let _e48 = global.froxel_params;
    if (_e48.w > 0.5f) {
        {
            injectFroxel();
            return;
        }
    }
    let _e52 = v_ndc_1;
    let _e59 = v_ndc_1;
    uv_3 = vec2<f32>(((_e52.x * 0.5f) + 0.5f), (0.5f - (_e59.y * 0.5f)));
    let _e66 = uv_3;
    let _e67 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e66);
    d_1 = _e67.x;
    let _e70 = v_ndc_1;
    let _e71 = d_1;
    if (_e71 >= 0.9999f) {
        local_8 = 1f;
    } else {
        let _e75 = d_1;
        local_8 = _e75;
    }
    let _e77 = local_8;
    far_ndc = vec4<f32>(_e70.x, _e70.y, _e77, 1f);
    let _e83 = global.inv_view_proj;
    let _e84 = far_ndc;
    wp4_ = (_e83 * _e84);
    let _e87 = wp4_;
    let _e89 = wp4_;
    wp_7 = (_e87.xyz / vec3(max(_e89.w, 0.00001f)));
    let _e96 = global.cam_pos_density;
    let _e100 = global.fog_col_scat;
    if ((_e96.w <= 0f) && (_e100.w <= 0f)) {
        {
            frag_color = vec4(0f);
            return;
        }
    }
    let _e107 = wp_7;
    let _e108 = global.cam_pos_density;
    ray_1 = (_e107 - _e108.xyz);
    let _e112 = ray_1;
    dist = length(_e112);
    let _e115 = ray_1;
    let _e116 = dist;
    ray_dir_2 = (_e115 / vec3(max(_e116, 0.0001f)));
    let _e122 = d_1;
    if (_e122 >= 0.9999f) {
        let _e125 = global.cam_fwd_maxd;
        local_9 = _e125.w;
    } else {
        let _e127 = dist;
        let _e128 = global.cam_fwd_maxd;
        local_9 = min(_e127, _e128.w);
    }
    let _e132 = local_9;
    max_dist_1 = _e132;
    let _e134 = max_dist_1;
    if (_e134 < 0.1f) {
        {
            frag_color = vec4(0f);
            return;
        }
    }
    let _e139 = global.sun_dir_int;
    let _e141 = global.sun_dir_int;
    let _e143 = global.sun_dir_int;
    sun_dir = (_e139.xyz * inverseSqrt(max(dot(_e141.xyz, _e143.xyz), 0.000000000001f)));
    let _e151 = global.cam_fwd_maxd;
    let _e153 = global.cam_fwd_maxd;
    let _e155 = global.cam_fwd_maxd;
    cam_fwd = (_e151.xyz * inverseSqrt(max(dot(_e153.xyz, _e155.xyz), 0.000000000001f)));
    let _e163 = ray_dir_2;
    let _e164 = sun_dir;
    cos_theta_2 = dot(_e163, _e164);
    let _e167 = cos_theta_2;
    let _e168 = global.sun_col_aniso;
    let _e174 = henyeyGreenstein(_e167, clamp(_e168.w, -0.85f, 0.85f));
    hg_1 = _e174;
    let _e176 = global.cascade_info;
    if (_e176.w > 0.5f) {
        let _e180 = hg_1;
        local_10 = _e180;
    } else {
        let _e182 = hg_1;
        local_10 = mix(0.2f, _e182, 0.65f);
    }
    let _e186 = local_10;
    phase_3 = _e186;
    let _e188 = global.cascade_info;
    steps = clamp(i32((_e188.z + 0.5f)), 8i, 128i);
    let _e197 = max_dist_1;
    let _e198 = steps;
    step_len = (_e197 / f32(_e198));
    let _e202 = gl_FragCoord_1;
    let _e204 = ign(_e202.xy);
    let _e205 = global.cascade_info;
    jitter = fract((_e204 + _e205.y));
    let _e210 = global.cam_pos_density;
    ext_density = max(_e210.w, 0f);
    let _e215 = global.cascade_info;
    if (_e215.w > 0.5f) {
        let _e219 = ext_density;
        let _e220 = global.fog_col_scat;
        local_11 = (_e219 * clamp(_e220.w, 0f, 1f));
    } else {
        let _e226 = global.fog_col_scat;
        local_11 = (max(_e226.w, 0f) * 0.18f);
    }
    let _e233 = local_11;
    scat_coeff = _e233;
    let _e235 = ext_density;
    let _e237 = step_len;
    step_ext = exp((-(_e235) * _e237));
    let _e241 = ext_density;
    let _e242 = step_len;
    if ((_e241 * _e242) > 0.0001f) {
        let _e247 = step_ext;
        let _e249 = ext_density;
        local_12 = ((1f - _e247) / _e249);
    } else {
        let _e251 = step_len;
        local_12 = _e251;
    }
    let _e253 = local_12;
    step_integral = _e253;
    let _e260 = scat_coeff;
    if (_e260 <= 0f) {
        {
            let _e266 = max_dist_1;
            frag_color = vec4<f32>(0f, 0f, 0f, _e266);
            return;
        }
    }
    loop {
        let _e270 = i_1;
        let _e271 = steps;
        if !((_e270 < _e271)) {
            break;
        }
        {
            let _e277 = transmittance;
            if (_e277 < 0.005f) {
                break;
            }
            let _e280 = i_1;
            let _e282 = jitter;
            let _e284 = step_len;
            t = ((f32(_e280) + _e282) * _e284);
            let _e287 = global.cam_pos_density;
            let _e289 = ray_dir_2;
            let _e290 = t;
            p_5 = (_e287.xyz + (_e289 * _e290));
            let _e294 = p_5;
            let _e295 = global.cam_pos_density;
            let _e298 = cam_fwd;
            vd_2 = max(dot((_e294 - _e295.xyz), _e298), 0f);
            let _e303 = p_5;
            let _e304 = vd_2;
            let _e305 = phase_3;
            let _e306 = ray_dir_2;
            let _e307 = evaluateStepLight(_e303, _e304, _e305, _e306);
            step_light_1 = _e307;
            let _e309 = accum;
            let _e310 = transmittance;
            let _e311 = step_light_1;
            let _e313 = scat_coeff;
            let _e314 = step_integral;
            accum = (_e309 + ((_e310 * _e311) * (_e313 * _e314)));
            let _e318 = transmittance;
            let _e319 = step_ext;
            transmittance = (_e318 * _e319);
        }
        continuing {
            let _e274 = i_1;
            i_1 = (_e274 + 1i);
        }
    }
    let _e321 = accum;
    let _e326 = clamp(_e321, vec3(0f), vec3(65000f));
    let _e327 = max_dist_1;
    frag_color = vec4<f32>(_e326.x, _e326.y, _e326.z, _e327);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>, @builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e61 = frag_color;
    return FragmentOutput(_e61);
}
