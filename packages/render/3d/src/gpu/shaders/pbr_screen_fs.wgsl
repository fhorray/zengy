// Ported from pbr_screen.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct GpuPointLight {
    pos_range: vec4<f32>,
    col_radius: vec4<f32>,
    shadow_params: vec4<f32>,
}

struct GpuSpotLight {
    pos_range: vec4<f32>,
    dir_cos_inner: vec4<f32>,
    col_cos_outer: vec4<f32>,
    shadow_params: vec4<f32>,
}

struct GpuRectLight {
    pos_range: vec4<f32>,
    dir_two: vec4<f32>,
    right_hx: vec4<f32>,
    up_hy: vec4<f32>,
    col_pad: vec4<f32>,
}

struct GpuReflectionProbe {
    pos_int: vec4<f32>,
    half_blend: vec4<f32>,
    sky_box: vec4<f32>,
    ground_pad: vec4<f32>,
    environment_info: vec4<f32>,
}

struct DynamicGiProbe {
    lobes: array<vec4<f32>, 6>,
    moments: array<vec4<f32>, 6>,
    offset_validity: vec4<f32>,
}

struct ClusterLightsBuffer {
    c_points: array<GpuPointLight, 256>,
    c_spots: array<GpuSpotLight, 256>,
    c_rects: array<GpuRectLight, 64>,
    c_probes: array<GpuReflectionProbe, 32>,
    gi_origin_enabled: vec4<f32>,
    gi_spacing: vec4<f32>,
    c_gi: array<DynamicGiProbe, 64>,
}

struct ClusterGridBuffer {
    clusters: array<vec4<u32>>,
}

struct ClusterIndicesBuffer {
    cluster_indices: array<u32>,
}

struct LocalShadowBuffer {
    local_shadow_vp: array<mat4x4<f32>, 16>,
    local_atlas_rect: array<vec4<f32>, 16>,
    local_shadow_info: array<vec4<f32>, 16>,
}

struct PbrFragUniforms {
    camera_pos_fog: vec4<f32>,
    base_color: vec4<f32>,
    emissive_weight: vec4<f32>,
    mat_params: vec4<f32>,
    mat_flags: vec4<f32>,
    ambient_sky: vec4<f32>,
    fog_color_start: vec4<f32>,
    dir_light_dir: vec4<f32>,
    dir_light_col: vec4<f32>,
    point_pos: array<vec4<f32>, 4>,
    point_col: array<vec4<f32>, 4>,
    sky_zenith: vec4<f32>,
    sky_horizon: vec4<f32>,
    spot_pos: array<vec4<f32>, 2>,
    spot_dir: array<vec4<f32>, 2>,
    spot_col: array<vec4<f32>, 2>,
    sh_coeffs: array<vec4<f32>, 9>,
    camera_fwd_overlap: vec4<f32>,
    cascade_splits: vec4<f32>,
    cascade_depth_ranges: vec4<f32>,
    cluster_factors: vec4<f32>,
    probe_volumetric: vec4<f32>,
    layer_info: vec4<f32>,
    cascade_info: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
    @location(1) out_surface: vec4<f32>,
    @location(2) out_diffuse: vec4<f32>,
    @location(3) out_specular: vec4<f32>,
}

const PI: f32 = 3.1415927f;

var<private> v_world_pos_1: vec3<f32>;
var<private> v_world_normal_1: vec3<f32>;
var<private> v_uv_1: vec2<f32>;
var<private> v_light_pos_4: array<vec4<f32>, 4>;
@group(0) @binding(0) 
var zengy_u_base_color_tex_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_base_color_tex_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_normal_tex_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_normal_tex_sampler: sampler;
@group(0) @binding(2) 
var zengy_u_mr_tex_image: texture_2d<f32>;
@group(0) @binding(34) 
var zengy_u_mr_tex_sampler: sampler;
@group(2) @binding(3) 
var zengy_u_shadow_tex_image: texture_depth_2d;
@group(2) @binding(35) 
var zengy_u_shadow_tex_sampler: sampler_comparison;
@group(2) @binding(4) 
var zengy_u_prefilter_env_image: texture_2d<f32>;
@group(2) @binding(36) 
var zengy_u_prefilter_env_sampler: sampler;
@group(2) @binding(5) 
var zengy_u_brdf_lut_image: texture_2d<f32>;
@group(2) @binding(37) 
var zengy_u_brdf_lut_sampler: sampler;
@group(2) @binding(6) 
var zengy_u_ssao_tex_image: texture_2d<f32>;
@group(2) @binding(38) 
var zengy_u_ssao_tex_sampler: sampler;
@group(2) @binding(7) 
var zengy_u_local_shadow_tex_image: texture_depth_2d;
@group(2) @binding(39) 
var zengy_u_local_shadow_tex_sampler: sampler_comparison;
@group(0) @binding(8) 
var zengy_u_ao_tex_image: texture_2d<f32>;
@group(0) @binding(40) 
var zengy_u_ao_tex_sampler: sampler;
@group(0) @binding(9) 
var zengy_u_emissive_tex_image: texture_2d<f32>;
@group(0) @binding(41) 
var zengy_u_emissive_tex_sampler: sampler;
@group(2) @binding(10) 
var zengy_u_shadow_raw_image: texture_2d<f32>;
@group(2) @binding(42) 
var zengy_u_shadow_raw_sampler: sampler;
@group(2) @binding(11) 
var zengy_u_local_shadow_raw_image: texture_2d<f32>;
@group(2) @binding(43) 
var zengy_u_local_shadow_raw_sampler: sampler;
@group(2) @binding(12) 
var zengy_u_probe_environment_image: texture_2d<f32>;
@group(2) @binding(44) 
var zengy_u_probe_environment_sampler: sampler;
@group(2) @binding(13) 
var zengy_u_ltc_image: texture_2d<f32>;
@group(2) @binding(45) 
var zengy_u_ltc_sampler: sampler;
@group(2) @binding(14) 
var<storage> global: ClusterLightsBuffer;
@group(2) @binding(15) 
var<storage> global_1: ClusterGridBuffer;
@group(2) @binding(16) 
var<storage> global_2: ClusterIndicesBuffer;
@group(2) @binding(17) 
var<storage> global_3: LocalShadowBuffer;
@group(3) @binding(0) 
var<uniform> global_4: PbrFragUniforms;
var<private> frag_color: vec4<f32>;
var<private> out_surface: vec4<f32>;
var<private> out_diffuse: vec4<f32>;
var<private> out_specular: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;
var<private> gl_FrontFacing_1: bool;

fn zy_isnan(v: f32) -> bool {
    var v_1: f32;

    v_1 = v;
    let _e2 = v_1;
    return ((bitcast<u32>(_e2) & 2147483647u) > 2139095040u);
}

fn zy_isinf(v_2: f32) -> bool {
    var v_3: f32;

    v_3 = v_2;
    let _e2 = v_3;
    return ((bitcast<u32>(_e2) & 2147483647u) == 2139095040u);
}

fn zy_isnan_1(v_4: vec2<f32>) -> vec2<bool> {
    var v_5: vec2<f32>;

    v_5 = v_4;
    let _e2 = v_5;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_5;
    let _e7 = zy_isnan(_e5.y);
    return vec2<bool>(_e4, _e7);
}

fn zy_isinf_1(v_6: vec2<f32>) -> vec2<bool> {
    var v_7: vec2<f32>;

    v_7 = v_6;
    let _e2 = v_7;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_7;
    let _e7 = zy_isinf(_e5.y);
    return vec2<bool>(_e4, _e7);
}

fn zy_isnan_2(v_8: vec3<f32>) -> vec3<bool> {
    var v_9: vec3<f32>;

    v_9 = v_8;
    let _e2 = v_9;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_9;
    let _e7 = zy_isnan(_e5.y);
    let _e8 = v_9;
    let _e10 = zy_isnan(_e8.z);
    return vec3<bool>(_e4, _e7, _e10);
}

fn zy_isinf_2(v_10: vec3<f32>) -> vec3<bool> {
    var v_11: vec3<f32>;

    v_11 = v_10;
    let _e2 = v_11;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_11;
    let _e7 = zy_isinf(_e5.y);
    let _e8 = v_11;
    let _e10 = zy_isinf(_e8.z);
    return vec3<bool>(_e4, _e7, _e10);
}

fn zy_isnan_3(v_12: vec4<f32>) -> vec4<bool> {
    var v_13: vec4<f32>;

    v_13 = v_12;
    let _e2 = v_13;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_13;
    let _e7 = zy_isnan(_e5.y);
    let _e8 = v_13;
    let _e10 = zy_isnan(_e8.z);
    let _e11 = v_13;
    let _e13 = zy_isnan(_e11.w);
    return vec4<bool>(_e4, _e7, _e10, _e13);
}

fn zy_isinf_3(v_14: vec4<f32>) -> vec4<bool> {
    var v_15: vec4<f32>;

    v_15 = v_14;
    let _e2 = v_15;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_15;
    let _e7 = zy_isinf(_e5.y);
    let _e8 = v_15;
    let _e10 = zy_isinf(_e8.z);
    let _e11 = v_15;
    let _e13 = zy_isinf(_e11.w);
    return vec4<bool>(_e4, _e7, _e10, _e13);
}

fn encodeNormal(n: vec3<f32>) -> vec2<f32> {
    var n_1: vec3<f32>;
    var local: vec2<f32>;

    n_1 = n;
    let _e110 = n_1;
    let _e111 = n_1;
    let _e114 = n_1;
    let _e118 = n_1;
    n_1 = (_e110 / vec3(max(((abs(_e111.x) + abs(_e114.y)) + abs(_e118.z)), 0.000001f)));
    let _e126 = n_1;
    if (_e126.z >= 0f) {
        let _e130 = n_1;
        local = _e130.xy;
    } else {
        let _e133 = n_1;
        let _e145 = n_1;
        local = ((vec2(1f) - abs(_e133.yx)) * select(vec2(-1f), vec2(1f), (_e145.xy >= vec2(0f))));
    }
    let _e154 = local;
    return _e154;
}

fn packRgb(v_16: vec3<f32>) -> f32 {
    var v_17: vec3<f32>;
    var q: vec3<u32>;

    v_17 = v_16;
    let _e110 = v_17;
    q = vec3<u32>(round((clamp(_e110, vec3(0f), vec3(1f)) * 255f)));
    let _e121 = q;
    let _e123 = q;
    let _e129 = q;
    return f32(((_e121.x | (_e123.y << 8u)) | (_e129.z << 16u)));
}

fn distributionGGX(N: vec3<f32>, H: vec3<f32>, roughness: f32) -> f32 {
    var N_1: vec3<f32>;
    var H_1: vec3<f32>;
    var roughness_1: f32;
    var a: f32;
    var a2_: f32;
    var NdotH: f32;
    var denom: f32;

    N_1 = N;
    H_1 = H;
    roughness_1 = roughness;
    let _e115 = roughness_1;
    let _e116 = roughness_1;
    a = (_e115 * _e116);
    let _e119 = a;
    let _e120 = a;
    a2_ = (_e119 * _e120);
    let _e123 = N_1;
    let _e124 = H_1;
    NdotH = max(dot(_e123, _e124), 0f);
    let _e129 = NdotH;
    let _e130 = NdotH;
    let _e132 = a2_;
    denom = (((_e129 * _e130) * (_e132 - 1f)) + 1f);
    let _e139 = a2_;
    let _e140 = denom;
    let _e142 = denom;
    return (_e139 / max(((PI * _e140) * _e142), 0.0001f));
}

fn geometrySchlickGGX(NdotV: f32, roughness_2: f32) -> f32 {
    var NdotV_1: f32;
    var roughness_3: f32;
    var r: f32;
    var k: f32;

    NdotV_1 = NdotV;
    roughness_3 = roughness_2;
    let _e113 = roughness_3;
    r = (_e113 + 1f);
    let _e117 = r;
    let _e118 = r;
    k = ((_e117 * _e118) / 8f);
    let _e123 = NdotV_1;
    let _e124 = NdotV_1;
    let _e126 = k;
    let _e129 = k;
    return (_e123 / max(((_e124 * (1f - _e126)) + _e129), 0.0001f));
}

fn geometrySmith(N_2: vec3<f32>, V: vec3<f32>, L: vec3<f32>, roughness_4: f32) -> f32 {
    var N_3: vec3<f32>;
    var V_1: vec3<f32>;
    var L_1: vec3<f32>;
    var roughness_5: f32;

    N_3 = N_2;
    V_1 = V;
    L_1 = L;
    roughness_5 = roughness_4;
    let _e117 = N_3;
    let _e118 = V_1;
    let _e122 = roughness_5;
    let _e123 = geometrySchlickGGX(max(dot(_e117, _e118), 0f), _e122);
    let _e124 = N_3;
    let _e125 = L_1;
    let _e129 = roughness_5;
    let _e130 = geometrySchlickGGX(max(dot(_e124, _e125), 0f), _e129);
    return (_e123 * _e130);
}

fn fresnelSchlick(cosTheta: f32, F0_: vec3<f32>) -> vec3<f32> {
    var cosTheta_1: f32;
    var F0_1: vec3<f32>;

    cosTheta_1 = cosTheta;
    F0_1 = F0_;
    let _e113 = F0_1;
    let _e115 = F0_1;
    let _e119 = cosTheta_1;
    return (_e113 + ((vec3(1f) - _e115) * pow(clamp((1f - _e119), 0f, 1f), 5f)));
}

fn fresnelSchlickRoughness(cosTheta_2: f32, F0_2: vec3<f32>, roughness_6: f32) -> vec3<f32> {
    var cosTheta_3: f32;
    var F0_3: vec3<f32>;
    var roughness_7: f32;

    cosTheta_3 = cosTheta_2;
    F0_3 = F0_2;
    roughness_7 = roughness_6;
    let _e115 = F0_3;
    let _e117 = roughness_7;
    let _e120 = F0_3;
    let _e122 = F0_3;
    let _e125 = cosTheta_3;
    return (_e115 + ((max(vec3((1f - _e117)), _e120) - _e122) * pow(clamp((1f - _e125), 0f, 1f), 5f)));
}

fn evalSH9Diffuse(n_2: vec3<f32>) -> vec3<f32> {
    var n_3: vec3<f32>;
    var b: array<f32, 9>;
    var res: vec3<f32> = vec3(0f);
    var i: i32 = 0i;

    n_3 = n_2;
    b[0i] = 0.282095f;
    let _e118 = n_3;
    b[1i] = (0.488603f * _e118.y);
    let _e124 = n_3;
    b[2i] = (0.488603f * _e124.z);
    let _e130 = n_3;
    b[3i] = (0.488603f * _e130.x);
    let _e136 = n_3;
    let _e139 = n_3;
    b[4i] = ((1.092548f * _e136.x) * _e139.y);
    let _e145 = n_3;
    let _e148 = n_3;
    b[5i] = ((1.092548f * _e145.y) * _e148.z);
    let _e155 = n_3;
    let _e158 = n_3;
    b[6i] = (0.315392f * (((3f * _e155.z) * _e158.z) - 1f));
    let _e167 = n_3;
    let _e170 = n_3;
    b[7i] = ((1.092548f * _e167.x) * _e170.z);
    let _e176 = n_3;
    let _e178 = n_3;
    let _e181 = n_3;
    let _e183 = n_3;
    b[8i] = (0.546274f * ((_e176.x * _e178.x) - (_e181.y * _e183.y)));
    loop {
        let _e193 = i;
        if !((_e193 < 9i)) {
            break;
        }
        {
            let _e200 = res;
            let _e201 = i;
            let _e203 = global_4.sh_coeffs[_e201];
            let _e205 = i;
            let _e207 = b[_e205];
            res = (_e200 + (_e203.xyz * _e207));
        }
        continuing {
            let _e197 = i;
            i = (_e197 + 1i);
        }
    }
    let _e210 = res;
    return max(_e210, vec3(0f));
}

fn equirectUv(d: vec3<f32>) -> vec2<f32> {
    var d_1: vec3<f32>;
    var u: f32;
    var v_18: f32;

    d_1 = d;
    let _e111 = d_1;
    let _e113 = d_1;
    u = ((atan2(_e111.x, -(_e113.z)) / 6.2831855f) + 0.5f);
    let _e124 = d_1;
    v_18 = (acos(clamp(_e124.y, -1f, 1f)) / PI);
    let _e133 = u;
    let _e134 = v_18;
    return vec2<f32>(_e133, _e134);
}

fn perturbNormal(N_4: vec3<f32>, V_2: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    var N_5: vec3<f32>;
    var V_3: vec3<f32>;
    var uv_1: vec2<f32>;
    var map_n: vec3<f32>;
    var dp1_: vec3<f32>;
    var dp2_: vec3<f32>;
    var duv1_: vec2<f32>;
    var duv2_: vec2<f32>;
    var dp2perp: vec3<f32>;
    var dp1perp: vec3<f32>;
    var T: vec3<f32>;
    var B: vec3<f32>;
    var invmax: f32;
    var TBN: mat3x3<f32>;

    N_5 = N_4;
    V_3 = V_2;
    uv_1 = uv;
    let _e115 = uv_1;
    let _e116 = textureSample(zengy_u_normal_tex_image, zengy_u_normal_tex_sampler, _e115);
    map_n = ((_e116.xyz * 2f) - vec3(1f));
    let _e124 = map_n;
    if (length(_e124) < 0.01f) {
        let _e128 = N_5;
        return _e128;
    }
    let _e129 = map_n;
    let _e131 = map_n;
    let _e133 = global_4.mat_flags;
    let _e135 = (_e131.xy * _e133.y);
    map_n.x = _e135.x;
    map_n.y = _e135.y;
    let _e140 = v_world_pos_1;
    let _e141 = dpdx(_e140);
    dp1_ = _e141;
    let _e143 = v_world_pos_1;
    let _e144 = dpdy(_e143);
    dp2_ = _e144;
    let _e146 = uv_1;
    let _e147 = dpdx(_e146);
    duv1_ = _e147;
    let _e149 = uv_1;
    let _e150 = dpdy(_e149);
    duv2_ = _e150;
    let _e152 = dp2_;
    let _e153 = N_5;
    dp2perp = cross(_e152, _e153);
    let _e156 = N_5;
    let _e157 = dp1_;
    dp1perp = cross(_e156, _e157);
    let _e160 = dp2perp;
    let _e161 = duv1_;
    let _e164 = dp1perp;
    let _e165 = duv2_;
    T = ((_e160 * _e161.x) + (_e164 * _e165.x));
    let _e170 = dp2perp;
    let _e171 = duv1_;
    let _e174 = dp1perp;
    let _e175 = duv2_;
    B = ((_e170 * _e171.y) + (_e174 * _e175.y));
    let _e180 = T;
    let _e181 = T;
    let _e183 = B;
    let _e184 = B;
    invmax = inverseSqrt((max(dot(_e180, _e181), dot(_e183, _e184)) + 0.00000001f));
    let _e191 = T;
    let _e192 = invmax;
    let _e193 = (_e191 * _e192);
    let _e194 = B;
    let _e195 = invmax;
    let _e196 = (_e194 * _e195);
    let _e197 = N_5;
    TBN = mat3x3<f32>(vec3<f32>(_e193.x, _e193.y, _e193.z), vec3<f32>(_e196.x, _e196.y, _e196.z), vec3<f32>(_e197.x, _e197.y, _e197.z));
    let _e212 = TBN;
    let _e213 = map_n;
    return normalize((_e212 * _e213));
}

fn layersOverlap(light_mask: f32, mesh_mask: f32) -> bool {
    var light_mask_1: f32;
    var mesh_mask_1: f32;

    light_mask_1 = light_mask;
    mesh_mask_1 = mesh_mask;
    let _e113 = light_mask_1;
    let _e115 = mesh_mask_1;
    return ((u32(_e113) & u32(_e115)) != 0u);
}

fn ign(p: vec2<f32>) -> f32 {
    var p_1: vec2<f32>;

    p_1 = p;
    let _e112 = p_1;
    return fract((52.982918f * fract(dot(_e112, vec2<f32>(0.06711056f, 0.00583715f)))));
}

fn vogelDisk(idx: i32, count: i32, phi: f32) -> vec2<f32> {
    var idx_1: i32;
    var count_1: i32;
    var phi_1: f32;
    var r_1: f32;
    var theta: f32;

    idx_1 = idx;
    count_1 = count;
    phi_1 = phi;
    let _e115 = idx_1;
    let _e119 = count_1;
    r_1 = sqrt(((f32(_e115) + 0.5f) / f32(_e119)));
    let _e124 = idx_1;
    let _e128 = phi_1;
    theta = ((f32(_e124) * 2.3999631f) + _e128);
    let _e131 = theta;
    let _e133 = theta;
    let _e136 = r_1;
    return (vec2<f32>(cos(_e131), sin(_e133)) * _e136);
}

fn sampleCascadePCF(c_idx: i32, N_6: vec3<f32>, L_2: vec3<f32>, rot: f32, view_depth: f32) -> f32 {
    var c_idx_1: i32;
    var N_7: vec3<f32>;
    var L_3: vec3<f32>;
    var rot_1: f32;
    var view_depth_1: f32;
    var light_pos: vec4<f32>;
    var proj: vec3<f32>;
    var uv_2: vec2<f32>;
    var q_min: vec2<f32>;
    var q_max: vec2<f32>;
    var slope: f32;
    var depth_range: f32;
    var bias_m: f32;
    var bias: f32;
    var texel: vec2<f32>;
    var local_1: f32;
    var pcss_boost: f32;
    var radius_texels: f32;
    var local_2: i32;
    var taps: i32;
    var texel_world: f32;
    var blocker_sum: f32 = 0f;
    var blocker_n: f32 = 0f;
    var i_1: i32 = 0i;
    var o: vec2<f32>;
    var suv: vec2<f32>;
    var r_2: f32;
    var depth_gap_m: f32;
    var shadow: f32 = 0f;
    var i_2: i32 = 0i;
    var o_1: vec2<f32>;
    var suv_1: vec2<f32>;

    c_idx_1 = c_idx;
    N_7 = N_6;
    L_3 = L_2;
    rot_1 = rot;
    view_depth_1 = view_depth;
    let _e119 = c_idx_1;
    let _e121 = v_light_pos_4[_e119];
    light_pos = _e121;
    let _e123 = light_pos;
    let _e125 = light_pos;
    proj = (_e123.xyz / vec3(max(_e125.w, 0.0001f)));
    let _e132 = proj;
    let _e139 = proj;
    uv_2 = vec2<f32>(((_e132.x * 0.5f) + 0.5f), (0.5f - (_e139.y * 0.5f)));
    let _e146 = uv_2;
    let _e150 = uv_2;
    let _e155 = uv_2;
    let _e160 = uv_2;
    let _e165 = proj;
    let _e170 = proj;
    if ((((((_e146.x < 0.01f) || (_e150.x > 0.99f)) || (_e155.y < 0.01f)) || (_e160.y > 0.99f)) || (_e165.z > 1f)) || (_e170.z < 0f)) {
        {
            return -1f;
        }
    }
    let _e177 = c_idx_1;
    let _e183 = c_idx_1;
    q_min = vec2<f32>((f32((_e177 & 1i)) * 0.5f), (f32((_e183 >> 1u)) * 0.5f));
    let _e192 = q_min;
    q_max = (_e192 + vec2<f32>(0.5f, 0.5f));
    let _e198 = q_min;
    let _e199 = q_max;
    let _e200 = uv_2;
    uv_2 = mix(_e198, _e199, _e200);
    let _e203 = N_7;
    let _e204 = L_3;
    slope = (1f - max(dot(_e203, _e204), 0f));
    let _e210 = c_idx_1;
    let _e212 = global_4.cascade_depth_ranges[_e210];
    depth_range = max(_e212, 1f);
    let _e216 = global_4.cascade_info;
    let _e218 = global_4.mat_flags;
    let _e224 = slope;
    let _e230 = c_idx_1;
    bias_m = ((max(_e216.z, (_e218.z * 8f)) * (1f + (_e224 * 3.5f))) * (1f + (f32(_e230) * 0.65f)));
    let _e237 = bias_m;
    let _e238 = depth_range;
    bias = (_e237 / _e238);
    let _e243 = textureDimensions(zengy_u_shadow_tex_image, 0i);
    texel = (vec2(1f) / vec2<f32>(vec2<i32>(_e243)));
    let _e249 = global_4.probe_volumetric;
    if (_e249.y > 0.5f) {
        let _e254 = view_depth_1;
        local_1 = (1f + clamp((_e254 / 30f), 0f, 1.5f));
    } else {
        local_1 = 1f;
    }
    let _e263 = local_1;
    pcss_boost = _e263;
    let _e266 = c_idx_1;
    let _e271 = pcss_boost;
    radius_texels = ((2.2f - (f32(_e266) * 0.2f)) * _e271);
    let _e274 = c_idx_1;
    if (_e274 < 2i) {
        local_2 = 12i;
    } else {
        local_2 = 8i;
    }
    let _e280 = local_2;
    taps = _e280;
    let _e282 = global_4.probe_volumetric;
    if (_e282.y > 1.5f) {
        {
            let _e287 = c_idx_1;
            let _e289 = global_4.cascade_splits[_e287];
            texel_world = ((2f * max((_e289 * 1.25f), 12f)) / 1024f);
            loop {
                let _e304 = i_1;
                if !((_e304 < 12i)) {
                    break;
                }
                {
                    let _e311 = i_1;
                    let _e313 = rot_1;
                    let _e314 = vogelDisk(_e311, 12i, _e313);
                    let _e317 = texel;
                    o = ((_e314 * 6f) * _e317);
                    let _e320 = uv_2;
                    let _e321 = o;
                    let _e323 = q_min;
                    let _e324 = texel;
                    let _e326 = q_max;
                    let _e327 = texel;
                    suv = clamp((_e320 + _e321), (_e323 + _e324), (_e326 - _e327));
                    let _e331 = suv;
                    let _e333 = textureSampleLevel(zengy_u_shadow_raw_image, zengy_u_shadow_raw_sampler, _e331, 0f);
                    r_2 = _e333.x;
                    let _e336 = r_2;
                    let _e337 = proj;
                    let _e339 = bias;
                    if (_e336 < (_e337.z - _e339)) {
                        {
                            let _e342 = blocker_sum;
                            let _e343 = r_2;
                            blocker_sum = (_e342 + _e343);
                            let _e345 = blocker_n;
                            blocker_n = (_e345 + 1f);
                        }
                    }
                }
                continuing {
                    let _e308 = i_1;
                    i_1 = (_e308 + 1i);
                }
            }
            let _e348 = blocker_n;
            if (_e348 < 0.5f) {
                return 1f;
            }
            let _e352 = proj;
            let _e354 = blocker_sum;
            let _e355 = blocker_n;
            let _e358 = depth_range;
            depth_gap_m = ((_e352.z - (_e354 / _e355)) * _e358);
            let _e361 = depth_gap_m;
            let _e362 = global_4.cascade_info;
            let _e365 = texel_world;
            radius_texels = clamp(((_e361 * _e362.y) / _e365), 1f, 14f);
            taps = 16i;
        }
    }
    loop {
        let _e375 = i_2;
        let _e376 = taps;
        if !((_e375 < _e376)) {
            break;
        }
        {
            let _e382 = i_2;
            let _e383 = taps;
            let _e384 = rot_1;
            let _e385 = vogelDisk(_e382, _e383, _e384);
            let _e386 = radius_texels;
            let _e388 = texel;
            o_1 = ((_e385 * _e386) * _e388);
            let _e391 = uv_2;
            let _e392 = o_1;
            let _e394 = q_min;
            let _e395 = texel;
            let _e397 = q_max;
            let _e398 = texel;
            suv_1 = clamp((_e391 + _e392), (_e394 + _e395), (_e397 - _e398));
            let _e402 = shadow;
            let _e403 = suv_1;
            let _e404 = proj;
            let _e406 = bias;
            let _e410 = vec3<f32>(_e403.x, _e403.y, (_e404.z - _e406));
            let _e413 = textureSampleCompareLevel(zengy_u_shadow_tex_image, zengy_u_shadow_tex_sampler, _e410.xy, _e410.z);
            shadow = (_e402 + _e413);
        }
        continuing {
            let _e379 = i_2;
            i_2 = (_e379 + 1i);
        }
    }
    let _e415 = shadow;
    let _e416 = taps;
    return (_e415 / f32(_e416));
}

fn sampleShadowCSM(N_8: vec3<f32>, L_4: vec3<f32>, view_depth_2: f32) -> f32 {
    var N_9: vec3<f32>;
    var L_5: vec3<f32>;
    var view_depth_3: f32;
    var count_2: i32;
    var max_dist: f32;
    var idx_2: i32 = 0i;
    var i_3: i32 = 0i;
    var rot_2: f32;
    var lit: f32;
    var k_1: i32;
    var local_3: f32;
    var prev_b: f32;
    var split: f32;
    var band: f32;
    var t: f32;
    var next_lit: f32;
    var fade: f32;

    N_9 = N_8;
    L_5 = L_4;
    view_depth_3 = view_depth_2;
    let _e115 = global_4.cascade_info;
    count_2 = clamp(i32((_e115.x + 0.5f)), 0i, 4i);
    let _e124 = global_4.mat_flags;
    let _e128 = count_2;
    if ((_e124.w < 0.5f) || (_e128 == 0i)) {
        return 1f;
    }
    let _e133 = count_2;
    let _e137 = global_4.cascade_splits[(_e133 - 1i)];
    max_dist = max(_e137, 1f);
    let _e141 = view_depth_3;
    let _e142 = max_dist;
    if (_e141 > _e142) {
        return 1f;
    }
    loop {
        let _e149 = i_3;
        if !((_e149 < 3i)) {
            break;
        }
        {
            let _e156 = i_3;
            let _e157 = count_2;
            let _e161 = view_depth_3;
            let _e162 = i_3;
            let _e164 = global_4.cascade_splits[_e162];
            if ((_e156 < (_e157 - 1i)) && (_e161 > _e164)) {
                let _e167 = i_3;
                idx_2 = (_e167 + 1i);
            }
        }
        continuing {
            let _e153 = i_3;
            i_3 = (_e153 + 1i);
        }
    }
    let _e171 = gl_FragCoord_1;
    let _e173 = ign(_e171.xy);
    rot_2 = (_e173 * 6.2831855f);
    let _e177 = idx_2;
    let _e178 = N_9;
    let _e179 = L_5;
    let _e180 = rot_2;
    let _e181 = view_depth_3;
    let _e182 = sampleCascadePCF(_e177, _e178, _e179, _e180, _e181);
    lit = _e182;
    let _e184 = lit;
    if (_e184 < 0f) {
        {
            let _e187 = idx_2;
            k_1 = (_e187 + 1i);
            loop {
                let _e191 = k_1;
                let _e192 = count_2;
                if !((_e191 < _e192)) {
                    break;
                }
                {
                    let _e198 = k_1;
                    let _e199 = N_9;
                    let _e200 = L_5;
                    let _e201 = rot_2;
                    let _e202 = view_depth_3;
                    let _e203 = sampleCascadePCF(_e198, _e199, _e200, _e201, _e202);
                    lit = _e203;
                    let _e204 = lit;
                    if (_e204 >= 0f) {
                        break;
                    }
                }
                continuing {
                    let _e195 = k_1;
                    k_1 = (_e195 + 1i);
                }
            }
            let _e207 = lit;
            if (_e207 < 0f) {
                lit = 1f;
            }
        }
    } else {
        let _e211 = idx_2;
        let _e212 = count_2;
        if (_e211 < (_e212 - 1i)) {
            {
                let _e216 = idx_2;
                if (_e216 == 0i) {
                    local_3 = 0f;
                } else {
                    let _e220 = idx_2;
                    let _e224 = global_4.cascade_splits[(_e220 - 1i)];
                    local_3 = _e224;
                }
                let _e226 = local_3;
                prev_b = _e226;
                let _e228 = idx_2;
                let _e230 = global_4.cascade_splits[_e228];
                split = _e230;
                let _e232 = split;
                let _e233 = prev_b;
                let _e235 = global_4.camera_fwd_overlap;
                band = max(((_e232 - _e233) * clamp(_e235.w, 0.02f, 0.4f)), 0.5f);
                let _e244 = view_depth_3;
                let _e245 = split;
                let _e246 = band;
                let _e249 = band;
                t = clamp(((_e244 - (_e245 - _e246)) / _e249), 0f, 1f);
                let _e255 = t;
                if (_e255 > 0f) {
                    {
                        let _e258 = idx_2;
                        let _e261 = N_9;
                        let _e262 = L_5;
                        let _e263 = rot_2;
                        let _e264 = view_depth_3;
                        let _e265 = sampleCascadePCF((_e258 + 1i), _e261, _e262, _e263, _e264);
                        next_lit = _e265;
                        let _e267 = next_lit;
                        if (_e267 >= 0f) {
                            let _e270 = lit;
                            let _e271 = next_lit;
                            let _e272 = t;
                            lit = mix(_e270, _e271, _e272);
                        }
                    }
                }
            }
        }
    }
    let _e274 = view_depth_3;
    let _e275 = max_dist;
    let _e279 = max_dist;
    fade = clamp(((_e274 - (_e275 * 0.85f)) / (_e279 * 0.15f)), 0f, 1f);
    let _e287 = lit;
    let _e289 = fade;
    return mix(_e287, 1f, _e289);
}

fn localLinearDepth(z: f32, near_d: f32, far_d: f32) -> f32 {
    var z_1: f32;
    var near_d_1: f32;
    var far_d_1: f32;

    z_1 = z;
    near_d_1 = near_d;
    far_d_1 = far_d;
    let _e116 = near_d_1;
    let _e117 = far_d_1;
    let _e119 = far_d_1;
    let _e120 = z_1;
    let _e121 = far_d_1;
    let _e122 = near_d_1;
    return ((_e116 * _e117) / max((_e119 - (_e120 * (_e121 - _e122))), 0.0001f));
}

fn sampleLocalTile(tile_idx: i32, world_pos: vec3<f32>, bias_1: f32, rot_3: f32, light_size: f32) -> f32 {
    var tile_idx_1: i32;
    var world_pos_1: vec3<f32>;
    var bias_2: f32;
    var rot_4: f32;
    var light_size_1: f32;
    var lp: vec4<f32>;
    var proj_1: vec3<f32>;
    var uv_3: vec2<f32>;
    var rect: vec4<f32>;
    var suv_2: vec2<f32>;
    var texel_1: vec2<f32>;
    var radius_texels_1: f32;
    var taps_1: i32 = 6i;
    var info: vec4<f32>;
    var tile_px: f32;
    var d_r: f32;
    var texel_world_1: f32;
    var search: f32;
    var blocker_sum_1: f32 = 0f;
    var blocker_n_1: f32 = 0f;
    var i_4: i32 = 0i;
    var o_2: vec2<f32>;
    var cuv: vec2<f32>;
    var r_3: f32;
    var d_b: f32;
    var s: f32 = 0f;
    var i_5: i32 = 0i;
    var o_3: vec2<f32>;
    var cuv_1: vec2<f32>;

    tile_idx_1 = tile_idx;
    world_pos_1 = world_pos;
    bias_2 = bias_1;
    rot_4 = rot_3;
    light_size_1 = light_size;
    let _e120 = tile_idx_1;
    let _e123 = tile_idx_1;
    if ((_e120 < 0i) || (_e123 >= 16i)) {
        return 1f;
    }
    let _e128 = tile_idx_1;
    let _e130 = global_3.local_shadow_vp[_e128];
    let _e131 = world_pos_1;
    lp = (_e130 * vec4<f32>(_e131.x, _e131.y, _e131.z, 1f));
    let _e139 = lp;
    if (_e139.w <= 0.001f) {
        return 1f;
    }
    let _e144 = lp;
    let _e146 = lp;
    proj_1 = (_e144.xyz / vec3(_e146.w));
    let _e151 = proj_1;
    let _e158 = proj_1;
    uv_3 = vec2<f32>(((_e151.x * 0.5f) + 0.5f), (0.5f - (_e158.y * 0.5f)));
    let _e165 = uv_3;
    let _e169 = uv_3;
    let _e174 = uv_3;
    let _e179 = uv_3;
    let _e184 = proj_1;
    let _e189 = proj_1;
    if ((((((_e165.x < 0f) || (_e169.x > 1f)) || (_e174.y < 0f)) || (_e179.y > 1f)) || (_e184.z < 0f)) || (_e189.z > 1f)) {
        {
            return 1f;
        }
    }
    let _e195 = tile_idx_1;
    let _e197 = global_3.local_atlas_rect[_e195];
    rect = _e197;
    let _e199 = rect;
    let _e201 = uv_3;
    let _e202 = rect;
    suv_2 = (_e199.xy + (_e201 * _e202.zw));
    let _e209 = textureDimensions(zengy_u_local_shadow_tex_image, 0i);
    texel_1 = (vec2(1f) / vec2<f32>(vec2<i32>(_e209)));
    let _e216 = rect;
    radius_texels_1 = (1.6f * (_e216.z / 0.25f));
    let _e224 = global_4.cascade_info;
    let _e228 = light_size_1;
    if ((_e224.w > 0.5f) && (_e228 > 0f)) {
        {
            let _e232 = tile_idx_1;
            let _e234 = global_3.local_shadow_info[_e232];
            info = _e234;
            let _e236 = rect;
            let _e239 = textureDimensions(zengy_u_local_shadow_tex_image, 0i);
            tile_px = (_e236.z * f32(vec2<i32>(_e239).x));
            let _e245 = proj_1;
            let _e247 = info;
            let _e249 = info;
            let _e251 = localLinearDepth(_e245.z, _e247.y, _e249.z);
            d_r = _e251;
            let _e254 = d_r;
            let _e256 = info;
            let _e259 = tile_px;
            texel_world_1 = max((((2f * _e254) * _e256.x) / _e259), 0.00001f);
            let _e264 = light_size_1;
            let _e265 = d_r;
            let _e266 = info;
            let _e270 = d_r;
            let _e274 = texel_world_1;
            search = clamp((((_e264 * (_e265 - _e266.y)) / max(_e270, 0.01f)) / _e274), 2f, 10f);
            loop {
                let _e286 = i_4;
                if !((_e286 < 12i)) {
                    break;
                }
                {
                    let _e293 = i_4;
                    let _e295 = rot_4;
                    let _e296 = vogelDisk(_e293, 12i, _e295);
                    let _e297 = search;
                    let _e299 = texel_1;
                    o_2 = ((_e296 * _e297) * _e299);
                    let _e302 = suv_2;
                    let _e303 = o_2;
                    let _e305 = rect;
                    let _e307 = texel_1;
                    let _e309 = rect;
                    let _e311 = rect;
                    let _e314 = texel_1;
                    cuv = clamp((_e302 + _e303), (_e305.xy + _e307), ((_e309.xy + _e311.zw) - _e314));
                    let _e318 = cuv;
                    let _e320 = textureSampleLevel(zengy_u_local_shadow_raw_image, zengy_u_local_shadow_raw_sampler, _e318, 0f);
                    r_3 = _e320.x;
                    let _e323 = r_3;
                    let _e324 = proj_1;
                    let _e326 = bias_2;
                    if (_e323 < (_e324.z - _e326)) {
                        {
                            let _e329 = blocker_sum_1;
                            let _e330 = r_3;
                            let _e331 = info;
                            let _e333 = info;
                            let _e335 = localLinearDepth(_e330, _e331.y, _e333.z);
                            blocker_sum_1 = (_e329 + _e335);
                            let _e337 = blocker_n_1;
                            blocker_n_1 = (_e337 + 1f);
                        }
                    }
                }
                continuing {
                    let _e290 = i_4;
                    i_4 = (_e290 + 1i);
                }
            }
            let _e340 = blocker_n_1;
            if (_e340 < 0.5f) {
                return 1f;
            }
            let _e344 = blocker_sum_1;
            let _e345 = blocker_n_1;
            d_b = (_e344 / _e345);
            let _e348 = d_r;
            let _e349 = d_b;
            let _e351 = light_size_1;
            let _e353 = d_b;
            let _e357 = texel_world_1;
            radius_texels_1 = clamp(((((_e348 - _e349) * _e351) / max(_e353, 0.01f)) / _e357), 1f, 12f);
            taps_1 = 16i;
        }
    }
    loop {
        let _e367 = i_5;
        let _e368 = taps_1;
        if !((_e367 < _e368)) {
            break;
        }
        {
            let _e374 = i_5;
            let _e375 = taps_1;
            let _e376 = rot_4;
            let _e377 = vogelDisk(_e374, _e375, _e376);
            let _e378 = radius_texels_1;
            let _e380 = texel_1;
            o_3 = ((_e377 * _e378) * _e380);
            let _e383 = suv_2;
            let _e384 = o_3;
            let _e386 = rect;
            let _e388 = texel_1;
            let _e390 = rect;
            let _e392 = rect;
            let _e395 = texel_1;
            cuv_1 = clamp((_e383 + _e384), (_e386.xy + _e388), ((_e390.xy + _e392.zw) - _e395));
            let _e399 = s;
            let _e400 = cuv_1;
            let _e401 = proj_1;
            let _e403 = bias_2;
            let _e407 = vec3<f32>(_e400.x, _e400.y, (_e401.z - _e403));
            let _e410 = textureSampleCompareLevel(zengy_u_local_shadow_tex_image, zengy_u_local_shadow_tex_sampler, _e407.xy, _e407.z);
            s = (_e399 + _e410);
        }
        continuing {
            let _e371 = i_5;
            i_5 = (_e371 + 1i);
        }
    }
    let _e412 = s;
    let _e413 = taps_1;
    return (_e412 / f32(_e413));
}

fn samplePointShadow(base_tile: i32, light_pos_1: vec3<f32>, N_10: vec3<f32>, L_6: vec3<f32>, rot_5: f32, light_size_2: f32) -> f32 {
    var base_tile_1: i32;
    var light_pos_2: vec3<f32>;
    var N_11: vec3<f32>;
    var L_7: vec3<f32>;
    var rot_6: f32;
    var light_size_3: f32;
    var d_2: vec3<f32>;
    var ad: vec3<f32>;
    var face: i32 = 0i;
    var local_4: i32;
    var local_5: i32;
    var local_6: i32;
    var slope_1: f32;
    var bias_3: f32;

    base_tile_1 = base_tile;
    light_pos_2 = light_pos_1;
    N_11 = N_10;
    L_7 = L_6;
    rot_6 = rot_5;
    light_size_3 = light_size_2;
    let _e122 = base_tile_1;
    let _e125 = base_tile_1;
    if ((_e122 < 0i) || (_e125 > 10i)) {
        return 1f;
    }
    let _e130 = v_world_pos_1;
    let _e131 = light_pos_2;
    d_2 = (_e130 - _e131);
    let _e134 = d_2;
    ad = abs(_e134);
    let _e139 = ad;
    let _e141 = ad;
    let _e144 = ad;
    let _e146 = ad;
    if ((_e139.x >= _e141.y) && (_e144.x >= _e146.z)) {
        {
            let _e150 = d_2;
            if (_e150.x > 0f) {
                local_4 = 0i;
            } else {
                local_4 = 1i;
            }
            let _e157 = local_4;
            face = _e157;
        }
    } else {
        let _e158 = ad;
        let _e160 = ad;
        let _e163 = ad;
        let _e165 = ad;
        if ((_e158.y >= _e160.x) && (_e163.y >= _e165.z)) {
            {
                let _e169 = d_2;
                if (_e169.y > 0f) {
                    local_5 = 2i;
                } else {
                    local_5 = 3i;
                }
                let _e176 = local_5;
                face = _e176;
            }
        } else {
            {
                let _e177 = d_2;
                if (_e177.z > 0f) {
                    local_6 = 4i;
                } else {
                    local_6 = 5i;
                }
                let _e184 = local_6;
                face = _e184;
            }
        }
    }
    let _e186 = N_11;
    let _e187 = L_7;
    slope_1 = (1f - max(dot(_e186, _e187), 0f));
    let _e194 = slope_1;
    bias_3 = (0.0015f + (_e194 * 0.0045f));
    let _e199 = base_tile_1;
    let _e200 = face;
    let _e202 = v_world_pos_1;
    let _e203 = bias_3;
    let _e204 = rot_6;
    let _e205 = light_size_3;
    let _e206 = sampleLocalTile((_e199 + _e200), _e202, _e203, _e204, _e205);
    return _e206;
}

fn evalLight(N_12: vec3<f32>, V_4: vec3<f32>, F0_4: vec3<f32>, albedo: vec3<f32>, metallic: f32, roughness_8: f32, L_8: vec3<f32>, radiance: vec3<f32>, spec_scale: f32) -> vec3<f32> {
    var N_13: vec3<f32>;
    var V_5: vec3<f32>;
    var F0_5: vec3<f32>;
    var albedo_1: vec3<f32>;
    var metallic_1: f32;
    var roughness_9: f32;
    var L_9: vec3<f32>;
    var radiance_1: vec3<f32>;
    var spec_scale_1: f32;
    var NdotL: f32;
    var half_vector: vec3<f32>;
    var H_2: vec3<f32>;
    var F: vec3<f32>;
    var kD: vec3<f32>;
    var NDF: f32;
    var G: f32;
    var spec: vec3<f32>;

    N_13 = N_12;
    V_5 = V_4;
    F0_5 = F0_4;
    albedo_1 = albedo;
    metallic_1 = metallic;
    roughness_9 = roughness_8;
    L_9 = L_8;
    radiance_1 = radiance;
    spec_scale_1 = spec_scale;
    let _e128 = N_13;
    let _e129 = L_9;
    NdotL = max(dot(_e128, _e129), 0f);
    let _e134 = NdotL;
    if (_e134 <= 0f) {
        return vec3(0f);
    }
    let _e139 = V_5;
    let _e140 = L_9;
    half_vector = (_e139 + _e140);
    let _e143 = half_vector;
    let _e144 = half_vector;
    let _e145 = half_vector;
    H_2 = (_e143 * inverseSqrt(max(dot(_e144, _e145), 0.000000000001f)));
    let _e152 = H_2;
    let _e153 = V_5;
    let _e157 = F0_5;
    let _e158 = fresnelSchlick(max(dot(_e152, _e153), 0f), _e157);
    F = _e158;
    let _e162 = F;
    let _e165 = metallic_1;
    kD = ((vec3(1f) - _e162) * (1f - _e165));
    let _e169 = spec_scale_1;
    if (_e169 <= 0f) {
        let _e172 = kD;
        let _e173 = albedo_1;
        let _e178 = radiance_1;
        let _e180 = NdotL;
        return ((((_e172 * _e173) / vec3(3.1415927f)) * _e178) * _e180);
    }
    let _e182 = N_13;
    let _e183 = H_2;
    let _e184 = roughness_9;
    let _e185 = distributionGGX(_e182, _e183, _e184);
    NDF = _e185;
    let _e187 = N_13;
    let _e188 = V_5;
    let _e189 = L_9;
    let _e190 = roughness_9;
    let _e191 = geometrySmith(_e187, _e188, _e189, _e190);
    G = _e191;
    let _e193 = NDF;
    let _e194 = G;
    let _e196 = F;
    let _e199 = N_13;
    let _e200 = V_5;
    let _e205 = NdotL;
    spec = (((_e193 * _e194) * _e196) / vec3(max(((4f * max(dot(_e199, _e200), 0f)) * _e205), 0.0001f)));
    let _e212 = kD;
    let _e213 = albedo_1;
    let _e218 = spec;
    let _e219 = spec_scale_1;
    let _e222 = radiance_1;
    let _e224 = NdotL;
    return (((((_e212 * _e213) / vec3(3.1415927f)) + (_e218 * _e219)) * _e222) * _e224);
}

fn giSector(d_3: vec3<f32>) -> i32 {
    var d_4: vec3<f32>;
    var a_1: vec3<f32>;
    var local_7: i32;
    var local_8: i32;
    var local_9: i32;

    d_4 = d_3;
    let _e112 = d_4;
    a_1 = abs(_e112);
    let _e115 = a_1;
    let _e117 = a_1;
    let _e120 = a_1;
    let _e122 = a_1;
    if ((_e115.x >= _e117.y) && (_e120.x >= _e122.z)) {
        let _e126 = d_4;
        if (_e126.x >= 0f) {
            local_7 = 0i;
        } else {
            local_7 = 1i;
        }
        let _e133 = local_7;
        return _e133;
    }
    let _e134 = a_1;
    let _e136 = a_1;
    if (_e134.y >= _e136.z) {
        let _e139 = d_4;
        if (_e139.y >= 0f) {
            local_8 = 2i;
        } else {
            local_8 = 3i;
        }
        let _e146 = local_8;
        return _e146;
    }
    let _e147 = d_4;
    if (_e147.z >= 0f) {
        local_9 = 4i;
    } else {
        local_9 = 5i;
    }
    let _e154 = local_9;
    return _e154;
}

fn sampleDynamicGi(p_2: vec3<f32>, n_4: vec3<f32>) -> vec4<f32> {
    var p_3: vec3<f32>;
    var n_5: vec3<f32>;
    var nlen2_: f32;
    var n2_: vec3<f32>;
    var q_1: vec3<f32>;
    var base: vec3<i32>;
    var f: vec3<f32>;
    var sum_rgb: vec3<f32> = vec3(0f);
    var sum_w: f32 = 0f;
    var i_6: i32 = 0i;
    var o_4: vec3<i32>;
    var c: vec3<i32>;
    var idx_3: i32;
    var w3_: vec3<f32>;
    var w: f32;
    var pos: vec3<f32>;
    var delta: vec3<f32>;
    var dist: f32;
    var s_1: i32;
    var moment: vec4<f32>;
    var mean: f32;
    var variance: f32;
    var excess: f32;
    var vis: f32;
    var local_10: i32;
    var local_11: i32;
    var local_12: i32;
    var radiance_2: vec3<f32>;

    p_3 = p_2;
    n_5 = n_4;
    let _e114 = global.gi_origin_enabled;
    let _e118 = global.gi_origin_enabled;
    let _e119 = zy_isnan_3(_e118);
    let _e122 = global.gi_origin_enabled;
    let _e123 = zy_isinf_3(_e122);
    if (((_e114.w <= 0f) || any(_e119)) || any(_e123)) {
        return vec4(0f);
    }
    let _e128 = global.gi_spacing;
    let _e132 = global.gi_spacing;
    let _e134 = global_4.layer_info;
    let _e136 = layersOverlap(_e132.w, _e134.x);
    if ((_e128.w > 0f) && !(_e136)) {
        return vec4(0f);
    }
    let _e141 = p_3;
    let _e142 = zy_isnan_2(_e141);
    let _e144 = p_3;
    let _e145 = zy_isinf_2(_e144);
    let _e148 = n_5;
    let _e149 = zy_isnan_2(_e148);
    let _e152 = n_5;
    let _e153 = zy_isinf_2(_e152);
    let _e156 = global.gi_spacing;
    let _e163 = global.gi_spacing;
    let _e165 = zy_isnan_2(_e163.xyz);
    let _e168 = global.gi_spacing;
    let _e170 = zy_isinf_2(_e168.xyz);
    if ((((((any(_e142) || any(_e145)) || any(_e149)) || any(_e153)) || any((_e156.xyz <= vec3(0.01f)))) || any(_e165)) || any(_e170)) {
        return vec4(0f);
    }
    let _e175 = n_5;
    let _e176 = n_5;
    nlen2_ = dot(_e175, _e176);
    let _e179 = nlen2_;
    if (_e179 <= 0.000000000001f) {
        return vec4(0f);
    }
    let _e184 = n_5;
    let _e185 = n_5;
    let _e187 = nlen2_;
    n2_ = ((_e184 * _e185) / vec3(_e187));
    let _e191 = p_3;
    let _e192 = global.gi_origin_enabled;
    let _e195 = global.gi_spacing;
    q_1 = ((_e191 - _e192.xyz) / _e195.xyz);
    let _e199 = q_1;
    let _e205 = q_1;
    if (any((_e199 < vec3(-0.05f))) || any((_e205 > vec3(3.05f)))) {
        return vec4(0f);
    }
    let _e213 = q_1;
    q_1 = clamp(_e213, vec3(0f), vec3(3f));
    let _e219 = q_1;
    base = min(vec3<i32>(floor(_e219)), vec3(2i));
    let _e226 = q_1;
    let _e227 = base;
    f = (_e226 - vec3<f32>(_e227));
    loop {
        let _e238 = i_6;
        if !((_e238 < 8i)) {
            break;
        }
        {
            let _e245 = i_6;
            let _e248 = i_6;
            let _e254 = i_6;
            o_4 = vec3<i32>((_e245 & 1i), ((_e248 >> 1u) & 1i), ((_e254 >> 2u) & 1i));
            let _e262 = base;
            let _e263 = o_4;
            c = (_e262 + _e263);
            let _e266 = c;
            let _e269 = c;
            let _e274 = c;
            idx_3 = ((_e266.x + (4i * _e269.y)) + (16i * _e274.z));
            let _e280 = f;
            let _e283 = f;
            let _e284 = o_4;
            w3_ = mix((vec3(1f) - _e280), _e283, vec3<f32>(_e284));
            let _e288 = w3_;
            let _e290 = w3_;
            let _e293 = w3_;
            let _e296 = idx_3;
            let _e298 = global.c_gi[_e296];
            w = (((_e288.x * _e290.y) * _e293.z) * _e298.offset_validity.w);
            let _e303 = w;
            if (_e303 <= 0.00001f) {
                continue;
            }
            let _e306 = global.gi_origin_enabled;
            let _e308 = c;
            let _e310 = global.gi_spacing;
            let _e314 = idx_3;
            let _e316 = global.c_gi[_e314];
            pos = ((_e306.xyz + (vec3<f32>(_e308) * _e310.xyz)) + _e316.offset_validity.xyz);
            let _e321 = p_3;
            let _e322 = pos;
            delta = (_e321 - _e322);
            let _e325 = delta;
            dist = length(_e325);
            let _e328 = delta;
            let _e329 = giSector(_e328);
            s_1 = _e329;
            let _e331 = s_1;
            let _e332 = idx_3;
            let _e336 = global.c_gi[_e332].moments[_e331];
            moment = _e336;
            let _e338 = s_1;
            let _e339 = idx_3;
            let _e343 = global.c_gi[_e339].lobes[_e338];
            mean = _e343.w;
            let _e346 = moment;
            let _e348 = mean;
            let _e349 = mean;
            variance = max((_e346.x - (_e348 * _e349)), 0.0025f);
            let _e355 = dist;
            let _e356 = mean;
            excess = max(((_e355 - _e356) - 0.05f), 0f);
            let _e363 = variance;
            let _e364 = variance;
            let _e365 = excess;
            let _e366 = excess;
            vis = (_e363 / (_e364 + (_e365 * _e366)));
            let _e371 = moment;
            if (_e371.y <= 0f) {
                continue;
            }
            let _e375 = vis;
            let _e376 = vis;
            let _e378 = vis;
            vis = ((_e375 * _e376) * _e378);
            let _e380 = n_5;
            if (_e380.x >= 0f) {
                local_10 = 0i;
            } else {
                local_10 = 1i;
            }
            let _e387 = local_10;
            let _e388 = idx_3;
            let _e392 = global.c_gi[_e388].lobes[_e387];
            let _e394 = n2_;
            let _e397 = n_5;
            if (_e397.y >= 0f) {
                local_11 = 2i;
            } else {
                local_11 = 3i;
            }
            let _e404 = local_11;
            let _e405 = idx_3;
            let _e409 = global.c_gi[_e405].lobes[_e404];
            let _e411 = n2_;
            let _e415 = n_5;
            if (_e415.z >= 0f) {
                local_12 = 4i;
            } else {
                local_12 = 5i;
            }
            let _e422 = local_12;
            let _e423 = idx_3;
            let _e427 = global.c_gi[_e423].lobes[_e422];
            let _e429 = n2_;
            radiance_2 = (((_e392.xyz * _e394.x) + (_e409.xyz * _e411.y)) + (_e427.xyz * _e429.z));
            let _e434 = sum_rgb;
            let _e435 = radiance_2;
            let _e436 = w;
            let _e438 = vis;
            sum_rgb = (_e434 + ((_e435 * _e436) * _e438));
            let _e441 = sum_w;
            let _e442 = w;
            sum_w = (_e441 + _e442);
        }
        continuing {
            let _e242 = i_6;
            i_6 = (_e242 + 1i);
        }
    }
    let _e444 = sum_rgb;
    let _e445 = sum_w;
    let _e449 = (_e444 / vec3(max(_e445, 0.00001f)));
    let _e450 = sum_w;
    return vec4<f32>(_e449.x, _e449.y, _e449.z, clamp(_e450, 0f, 1f));
}

fn evalRectLightLegacy(rl: GpuRectLight, N_14: vec3<f32>, V_6: vec3<f32>, F0_6: vec3<f32>, albedo_2: vec3<f32>, metallic_2: f32, roughness_10: f32) -> vec3<f32> {
    var rl_1: GpuRectLight;
    var N_15: vec3<f32>;
    var V_7: vec3<f32>;
    var F0_7: vec3<f32>;
    var albedo_3: vec3<f32>;
    var metallic_3: f32;
    var roughness_11: f32;
    var to_p: vec3<f32>;
    var plane_d: f32;
    var p_on_plane: vec3<f32>;
    var d_plane: vec3<f32>;
    var cx: f32;
    var cy: f32;
    var closest: vec3<f32>;
    var to_l: vec3<f32>;
    var dist_1: f32;
    var range: f32;
    var L_10: vec3<f32>;
    var att: f32;
    var local_13: f32;
    var facing: f32;

    rl_1 = rl;
    N_15 = N_14;
    V_7 = V_6;
    F0_7 = F0_6;
    albedo_3 = albedo_2;
    metallic_3 = metallic_2;
    roughness_11 = roughness_10;
    let _e124 = v_world_pos_1;
    let _e125 = rl_1;
    to_p = (_e124 - _e125.pos_range.xyz);
    let _e130 = to_p;
    let _e131 = rl_1;
    plane_d = dot(_e130, _e131.dir_two.xyz);
    let _e136 = plane_d;
    let _e139 = rl_1;
    if ((_e136 <= 0f) && (_e139.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e147 = v_world_pos_1;
    let _e148 = rl_1;
    let _e151 = plane_d;
    p_on_plane = (_e147 - (_e148.dir_two.xyz * _e151));
    let _e155 = p_on_plane;
    let _e156 = rl_1;
    d_plane = (_e155 - _e156.pos_range.xyz);
    let _e161 = d_plane;
    let _e162 = rl_1;
    let _e166 = rl_1;
    let _e170 = rl_1;
    cx = clamp(dot(_e161, _e162.right_hx.xyz), -(_e166.right_hx.w), _e170.right_hx.w);
    let _e175 = d_plane;
    let _e176 = rl_1;
    let _e180 = rl_1;
    let _e184 = rl_1;
    cy = clamp(dot(_e175, _e176.up_hy.xyz), -(_e180.up_hy.w), _e184.up_hy.w);
    let _e189 = rl_1;
    let _e192 = rl_1;
    let _e195 = cx;
    let _e198 = rl_1;
    let _e201 = cy;
    closest = ((_e189.pos_range.xyz + (_e192.right_hx.xyz * _e195)) + (_e198.up_hy.xyz * _e201));
    let _e205 = closest;
    let _e206 = v_world_pos_1;
    to_l = (_e205 - _e206);
    let _e209 = to_l;
    dist_1 = length(_e209);
    let _e212 = rl_1;
    range = max(_e212.pos_range.w, 0.001f);
    let _e218 = dist_1;
    let _e219 = range;
    if (_e218 >= _e219) {
        return vec3(0f);
    }
    let _e223 = to_l;
    let _e224 = dist_1;
    L_10 = (_e223 / vec3(max(_e224, 0.0001f)));
    let _e231 = dist_1;
    let _e232 = range;
    att = clamp((1f - pow((_e231 / _e232), 4f)), 0f, 1f);
    let _e241 = att;
    let _e242 = att;
    let _e244 = dist_1;
    let _e245 = dist_1;
    att = ((_e241 * _e242) / ((_e244 * _e245) + 1f));
    let _e250 = rl_1;
    if (_e250.dir_two.w > 0.5f) {
        let _e255 = L_10;
        let _e257 = rl_1;
        local_13 = abs(dot(-(_e255), _e257.dir_two.xyz));
    } else {
        let _e262 = L_10;
        let _e264 = rl_1;
        local_13 = max(dot(-(_e262), _e264.dir_two.xyz), 0f);
    }
    let _e271 = local_13;
    facing = _e271;
    let _e273 = N_15;
    let _e274 = V_7;
    let _e275 = F0_7;
    let _e276 = albedo_3;
    let _e277 = metallic_3;
    let _e278 = roughness_11;
    let _e279 = L_10;
    let _e280 = rl_1;
    let _e283 = att;
    let _e285 = facing;
    let _e288 = evalLight(_e273, _e274, _e275, _e276, _e277, _e278, _e279, ((_e280.col_pad.xyz * _e283) * _e285), 1f);
    return _e288;
}

fn evalRectLightQuadrature(rl_2: GpuRectLight, N_16: vec3<f32>, V_8: vec3<f32>, F0_8: vec3<f32>, albedo_4: vec3<f32>, metallic_4: f32, roughness_12: f32) -> vec3<f32> {
    var rl_3: GpuRectLight;
    var N_17: vec3<f32>;
    var V_9: vec3<f32>;
    var F0_9: vec3<f32>;
    var albedo_5: vec3<f32>;
    var metallic_5: f32;
    var roughness_13: f32;
    var to_p_1: vec3<f32>;
    var plane_d_1: f32;
    var sum_rgb_1: vec3<f32> = vec3(0f);
    var node: f32 = 0.57735026f;
    var range_1: f32;
    var i_7: i32 = 0i;
    var local_14: f32;
    var sx: f32;
    var local_15: f32;
    var sy: f32;
    var sample_pos: vec3<f32>;
    var delta_1: vec3<f32>;
    var dist_2: f32;
    var L_11: vec3<f32>;
    var r_4: f32;
    var att_1: f32;
    var facing_1: f32;
    var local_16: f32;

    rl_3 = rl_2;
    N_17 = N_16;
    V_9 = V_8;
    F0_9 = F0_8;
    albedo_5 = albedo_4;
    metallic_5 = metallic_4;
    roughness_13 = roughness_12;
    let _e124 = v_world_pos_1;
    let _e125 = rl_3;
    to_p_1 = (_e124 - _e125.pos_range.xyz);
    let _e130 = to_p_1;
    let _e131 = rl_3;
    plane_d_1 = dot(_e130, _e131.dir_two.xyz);
    let _e136 = plane_d_1;
    let _e139 = rl_3;
    if ((_e136 <= 0f) && (_e139.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e152 = rl_3;
    range_1 = max(_e152.pos_range.w, 0.001f);
    loop {
        let _e160 = i_7;
        if !((_e160 < 4i)) {
            break;
        }
        {
            let _e167 = i_7;
            if ((_e167 & 1i) == 0i) {
                let _e172 = node;
                local_14 = -(_e172);
            } else {
                let _e174 = node;
                local_14 = _e174;
            }
            let _e176 = local_14;
            sx = _e176;
            let _e178 = i_7;
            if ((_e178 & 2i) == 0i) {
                let _e183 = node;
                local_15 = -(_e183);
            } else {
                let _e185 = node;
                local_15 = _e185;
            }
            let _e187 = local_15;
            sy = _e187;
            let _e189 = rl_3;
            let _e192 = rl_3;
            let _e195 = sx;
            let _e196 = rl_3;
            let _e202 = rl_3;
            let _e205 = sy;
            let _e206 = rl_3;
            sample_pos = ((_e189.pos_range.xyz + (_e192.right_hx.xyz * (_e195 * _e196.right_hx.w))) + (_e202.up_hy.xyz * (_e205 * _e206.up_hy.w)));
            let _e213 = sample_pos;
            let _e214 = v_world_pos_1;
            delta_1 = (_e213 - _e214);
            let _e217 = delta_1;
            dist_2 = length(_e217);
            let _e220 = dist_2;
            let _e221 = range_1;
            let _e223 = dist_2;
            if ((_e220 >= _e221) || (_e223 < 0.0001f)) {
                continue;
            }
            let _e227 = delta_1;
            let _e228 = dist_2;
            L_11 = (_e227 / vec3(_e228));
            let _e232 = dist_2;
            let _e233 = range_1;
            r_4 = (_e232 / _e233);
            let _e237 = r_4;
            let _e238 = r_4;
            let _e240 = r_4;
            let _e242 = r_4;
            att_1 = (1f - (((_e237 * _e238) * _e240) * _e242));
            let _e246 = att_1;
            let _e247 = att_1;
            let _e249 = dist_2;
            let _e250 = dist_2;
            att_1 = ((_e246 * _e247) / ((_e249 * _e250) + 1f));
            let _e255 = L_11;
            let _e257 = rl_3;
            facing_1 = dot(-(_e255), _e257.dir_two.xyz);
            let _e262 = rl_3;
            if (_e262.dir_two.w > 0.5f) {
                let _e267 = facing_1;
                local_16 = abs(_e267);
            } else {
                let _e269 = facing_1;
                local_16 = max(_e269, 0f);
            }
            let _e273 = local_16;
            facing_1 = _e273;
            let _e274 = sum_rgb_1;
            let _e275 = N_17;
            let _e276 = V_9;
            let _e277 = F0_9;
            let _e278 = albedo_5;
            let _e279 = metallic_5;
            let _e280 = roughness_13;
            let _e281 = L_11;
            let _e282 = rl_3;
            let _e285 = att_1;
            let _e286 = facing_1;
            let _e292 = evalLight(_e275, _e276, _e277, _e278, _e279, _e280, _e281, (_e282.col_pad.xyz * ((_e285 * _e286) * 0.25f)), 1f);
            sum_rgb_1 = (_e274 + _e292);
        }
        continuing {
            let _e164 = i_7;
            i_7 = (_e164 + 1i);
        }
    }
    let _e294 = sum_rgb_1;
    return _e294;
}

fn ltcLookup(uv_4: vec2<f32>, amplitude: bool) -> vec4<f32> {
    var uv_5: vec2<f32>;
    var amplitude_1: bool;
    var p_4: vec2<f32>;
    var i_8: vec2<i32>;
    var f_1: vec2<f32>;
    var local_17: i32;
    var base_1: vec2<i32>;
    var a_2: vec4<f32>;
    var b_1: vec4<f32>;
    var c_1: vec4<f32>;
    var d_5: vec4<f32>;

    uv_5 = uv_4;
    amplitude_1 = amplitude;
    let _e114 = uv_5;
    p_4 = (clamp(_e114, vec2(0f), vec2(1f)) * 15f);
    let _e125 = p_4;
    i_8 = min(vec2<i32>(floor(_e125)), vec2(14i));
    let _e132 = p_4;
    let _e133 = i_8;
    f_1 = (_e132 - vec2<f32>(_e133));
    let _e137 = i_8;
    let _e139 = amplitude_1;
    if _e139 {
        local_17 = 16i;
    } else {
        local_17 = 0i;
    }
    let _e143 = local_17;
    base_1 = (_e137 + vec2<i32>(0i, _e143));
    let _e147 = base_1;
    let _e149 = textureLoad(zengy_u_ltc_image, _e147, 0i);
    a_2 = _e149;
    let _e151 = base_1;
    let _e157 = textureLoad(zengy_u_ltc_image, (_e151 + vec2<i32>(1i, 0i)), 0i);
    b_1 = _e157;
    let _e159 = base_1;
    let _e165 = textureLoad(zengy_u_ltc_image, (_e159 + vec2<i32>(0i, 1i)), 0i);
    c_1 = _e165;
    let _e167 = base_1;
    let _e173 = textureLoad(zengy_u_ltc_image, (_e167 + vec2<i32>(1i, 1i)), 0i);
    d_5 = _e173;
    let _e175 = a_2;
    let _e176 = b_1;
    let _e177 = f_1;
    let _e181 = c_1;
    let _e182 = d_5;
    let _e183 = f_1;
    let _e187 = f_1;
    return mix(mix(_e175, _e176, vec4(_e177.x)), mix(_e181, _e182, vec4(_e183.x)), vec4(_e187.y));
}

fn ltcPolygon(corners: array<vec3<f32>, 4>, invM: mat3x3<f32>) -> f32 {
    var corners_1: array<vec3<f32>, 4>;
    var invM_1: mat3x3<f32>;
    var v_19: array<vec3<f32>, 4>;
    var i_9: i32 = 0i;
    var clipped: array<vec3<f32>, 8>;
    var count_3: i32 = 0i;
    var i_10: i32 = 0i;
    var a_3: vec3<f32>;
    var b_2: vec3<f32>;
    var ia: bool;
    var ib: bool;
    var integral: f32 = 0f;
    var i_11: i32 = 0i;
    var a_4: vec3<f32>;
    var b_3: vec3<f32>;
    var la: f32;
    var lb: f32;
    var crossAB: vec3<f32>;
    var s_2: f32;

    corners_1 = corners;
    invM_1 = invM;
    loop {
        let _e117 = i_9;
        if !((_e117 < 4i)) {
            break;
        }
        let _e124 = i_9;
        let _e126 = invM_1;
        let _e127 = i_9;
        let _e129 = corners_1[_e127];
        v_19[_e124] = (_e126 * _e129);
        continuing {
            let _e121 = i_9;
            i_9 = (_e121 + 1i);
        }
    }
    loop {
        let _e136 = i_10;
        if !((_e136 < 4i)) {
            break;
        }
        {
            let _e143 = i_10;
            let _e145 = v_19[_e143];
            a_3 = _e145;
            let _e147 = i_10;
            let _e153 = v_19[((_e147 + 1i) % 4i)];
            b_2 = _e153;
            let _e155 = a_3;
            ia = (_e155.z > 0f);
            let _e160 = b_2;
            ib = (_e160.z > 0f);
            let _e165 = ia;
            if _e165 {
                let _e166 = count_3;
                count_3 = (_e166 + 1i);
                let _e170 = a_3;
                clipped[_e166] = _e170;
            }
            let _e171 = ia;
            let _e172 = ib;
            if (_e171 != _e172) {
                let _e174 = count_3;
                count_3 = (_e174 + 1i);
                let _e178 = a_3;
                let _e179 = b_2;
                let _e180 = a_3;
                let _e182 = a_3;
                let _e184 = b_2;
                clipped[_e174] = mix(_e178, _e179, vec3(clamp((_e180.z / (_e182.z - _e184.z)), 0f, 1f)));
            }
        }
        continuing {
            let _e140 = i_10;
            i_10 = (_e140 + 1i);
        }
    }
    let _e193 = count_3;
    if (_e193 < 3i) {
        return 0f;
    }
    loop {
        let _e201 = i_11;
        let _e202 = count_3;
        if !((_e201 < _e202)) {
            break;
        }
        {
            let _e208 = i_11;
            let _e210 = clipped[_e208];
            a_4 = _e210;
            let _e212 = i_11;
            let _e215 = count_3;
            let _e218 = clipped[((_e212 + 1i) % _e215)];
            b_3 = _e218;
            let _e220 = a_4;
            la = length(_e220);
            let _e223 = b_3;
            lb = length(_e223);
            let _e226 = la;
            let _e229 = lb;
            if ((_e226 < 0.000001f) || (_e229 < 0.000001f)) {
                continue;
            }
            let _e233 = a_4;
            let _e234 = la;
            a_4 = (_e233 / vec3(_e234));
            let _e237 = b_3;
            let _e238 = lb;
            b_3 = (_e237 / vec3(_e238));
            let _e241 = a_4;
            let _e242 = b_3;
            crossAB = cross(_e241, _e242);
            let _e245 = crossAB;
            s_2 = length(_e245);
            let _e248 = s_2;
            if (_e248 > 0.000001f) {
                let _e251 = integral;
                let _e252 = crossAB;
                let _e254 = s_2;
                let _e255 = a_4;
                let _e256 = b_3;
                let _e264 = s_2;
                integral = (_e251 + ((_e252.z * atan2(_e254, clamp(dot(_e255, _e256), -1f, 1f))) / _e264));
            }
        }
        continuing {
            let _e205 = i_11;
            i_11 = (_e205 + 1i);
        }
    }
    let _e267 = integral;
    return clamp((abs(_e267) / 6.2831855f), 0f, 1f);
}

fn evalRectLightLtc(rl_4: GpuRectLight, N_18: vec3<f32>, V_10: vec3<f32>, F0_10: vec3<f32>, albedo_6: vec3<f32>, metallic_6: f32, roughness_14: f32) -> vec3<f32> {
    var rl_5: GpuRectLight;
    var N_19: vec3<f32>;
    var V_11: vec3<f32>;
    var F0_11: vec3<f32>;
    var albedo_7: vec3<f32>;
    var metallic_7: f32;
    var roughness_15: f32;
    var nv: f32;
    var uv_6: vec2<f32>;
    var fit: vec4<f32>;
    var amp: vec4<f32>;
    var delta_2: vec3<f32>;
    var distance: f32;
    var range_2: f32;
    var area: f32;
    var T_1: vec3<f32>;
    var local_18: vec3<f32>;
    var B_1: vec3<f32>;
    var basis: mat3x3<f32>;
    var right: vec3<f32>;
    var up: vec3<f32>;
    var corners_2: array<vec3<f32>, 4>;
    var invM_2: mat3x3<f32>;
    var diffuse: f32;
    var specular: f32;
    var fresnel: vec3<f32>;
    var kd: vec3<f32>;
    var amplitude_2: vec3<f32>;
    var nearDistance: f32;
    var r_5: f32;
    var window: f32;

    rl_5 = rl_4;
    N_19 = N_18;
    V_11 = V_10;
    F0_11 = F0_10;
    albedo_7 = albedo_6;
    metallic_7 = metallic_6;
    roughness_15 = roughness_14;
    let _e124 = N_19;
    let _e125 = V_11;
    nv = max(dot(_e124, _e125), 0f);
    let _e130 = roughness_15;
    let _e133 = nv;
    if ((_e130 < 0.18f) || (_e133 < 0.1f)) {
        let _e137 = rl_5;
        let _e138 = N_19;
        let _e139 = V_11;
        let _e140 = F0_11;
        let _e141 = albedo_7;
        let _e142 = metallic_7;
        let _e143 = roughness_15;
        let _e144 = evalRectLightQuadrature(_e137, _e138, _e139, _e140, _e141, _e142, _e143);
        return _e144;
    }
    let _e145 = roughness_15;
    let _e151 = nv;
    uv_6 = vec2<f32>(((_e145 - 0.18f) / 0.82f), ((1f - _e151) / 0.9f));
    let _e157 = uv_6;
    let _e159 = ltcLookup(_e157, false);
    fit = _e159;
    let _e161 = uv_6;
    let _e163 = ltcLookup(_e161, true);
    amp = _e163;
    let _e165 = fit;
    if (_e165.w > 0.45f) {
        let _e169 = rl_5;
        let _e170 = N_19;
        let _e171 = V_11;
        let _e172 = F0_11;
        let _e173 = albedo_7;
        let _e174 = metallic_7;
        let _e175 = roughness_15;
        let _e176 = evalRectLightQuadrature(_e169, _e170, _e171, _e172, _e173, _e174, _e175);
        return _e176;
    }
    let _e177 = rl_5;
    let _e180 = v_world_pos_1;
    delta_2 = (_e177.pos_range.xyz - _e180);
    let _e183 = delta_2;
    distance = length(_e183);
    let _e186 = rl_5;
    range_2 = max(_e186.pos_range.w, 0.001f);
    let _e192 = delta_2;
    let _e194 = rl_5;
    let _e200 = rl_5;
    if ((dot(-(_e192), _e194.dir_two.xyz) <= 0f) && (_e200.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e210 = rl_5;
    let _e214 = rl_5;
    area = ((4f * _e210.right_hx.w) * _e214.up_hy.w);
    let _e219 = area;
    let _e222 = distance;
    if ((_e219 <= 0.00001f) || (_e222 < 0.0001f)) {
        let _e226 = rl_5;
        let _e227 = N_19;
        let _e228 = V_11;
        let _e229 = F0_11;
        let _e230 = albedo_7;
        let _e231 = metallic_7;
        let _e232 = roughness_15;
        let _e233 = evalRectLightQuadrature(_e226, _e227, _e228, _e229, _e230, _e231, _e232);
        return _e233;
    }
    let _e234 = V_11;
    let _e235 = N_19;
    let _e236 = nv;
    T_1 = (_e234 - (_e235 * _e236));
    let _e240 = T_1;
    let _e241 = T_1;
    if (dot(_e240, _e241) < 0.000001f) {
        let _e245 = N_19;
        if (abs(_e245.y) < 0.99f) {
            local_18 = vec3<f32>(0f, 1f, 0f);
        } else {
            local_18 = vec3<f32>(1f, 0f, 0f);
        }
        let _e265 = local_18;
        let _e266 = N_19;
        T_1 = cross(_e265, _e266);
    }
    let _e268 = T_1;
    T_1 = normalize(_e268);
    let _e270 = N_19;
    let _e271 = T_1;
    B_1 = cross(_e270, _e271);
    let _e274 = T_1;
    let _e275 = B_1;
    let _e276 = N_19;
    basis = transpose(mat3x3<f32>(vec3<f32>(_e274.x, _e274.y, _e274.z), vec3<f32>(_e275.x, _e275.y, _e275.z), vec3<f32>(_e276.x, _e276.y, _e276.z)));
    let _e292 = rl_5;
    let _e295 = rl_5;
    right = (_e292.right_hx.xyz * _e295.right_hx.w);
    let _e300 = rl_5;
    let _e303 = rl_5;
    up = (_e300.up_hy.xyz * _e303.up_hy.w);
    let _e308 = basis;
    let _e309 = delta_2;
    let _e310 = right;
    let _e312 = up;
    let _e315 = basis;
    let _e316 = delta_2;
    let _e317 = right;
    let _e319 = up;
    let _e322 = basis;
    let _e323 = delta_2;
    let _e324 = right;
    let _e326 = up;
    let _e329 = basis;
    let _e330 = delta_2;
    let _e331 = right;
    let _e333 = up;
    corners_2 = array<vec3<f32>, 4>((_e308 * ((_e309 - _e310) - _e312)), (_e315 * ((_e316 + _e317) - _e319)), (_e322 * ((_e323 + _e324) + _e326)), (_e329 * ((_e330 - _e331) + _e333)));
    let _e338 = fit;
    let _e344 = vec3<f32>(_e338.x, 0f, 0f);
    let _e346 = fit;
    let _e351 = vec3<f32>(0f, _e346.y, 0f);
    let _e352 = fit;
    let _e358 = vec3<f32>(_e352.z, 0f, 1f);
    invM_2 = mat3x3<f32>(vec3<f32>(_e344.x, _e344.y, _e344.z), vec3<f32>(_e351.x, _e351.y, _e351.z), vec3<f32>(_e358.x, _e358.y, _e358.z));
    let _e373 = corners_2;
    let _e381 = ltcPolygon(_e373, mat3x3<f32>(vec3<f32>(1f, 0f, 0f), vec3<f32>(0f, 1f, 0f), vec3<f32>(0f, 0f, 1f)));
    diffuse = _e381;
    let _e383 = corners_2;
    let _e384 = invM_2;
    let _e385 = ltcPolygon(_e383, _e384);
    specular = _e385;
    let _e387 = F0_11;
    let _e389 = F0_11;
    let _e393 = nv;
    fresnel = (_e387 + ((vec3(1f) - _e389) * pow((1f - _e393), 5f)));
    let _e401 = fresnel;
    let _e405 = metallic_7;
    kd = ((vec3(1f) - _e401) * (1f - _e405));
    let _e409 = F0_11;
    let _e410 = amp;
    let _e414 = F0_11;
    let _e417 = amp;
    amplitude_2 = ((_e409 * _e410.x) + ((vec3(1f) - _e414) * _e417.y));
    let _e422 = distance;
    let _e423 = right;
    let _e426 = up;
    nearDistance = max(((_e422 - length(_e423)) - length(_e426)), 0f);
    let _e432 = nearDistance;
    let _e433 = range_2;
    r_5 = clamp((_e432 / _e433), 0f, 1f);
    let _e440 = r_5;
    let _e441 = r_5;
    let _e443 = r_5;
    let _e445 = r_5;
    window = (1f - (((_e440 * _e441) * _e443) * _e445));
    let _e449 = kd;
    let _e450 = albedo_7;
    let _e452 = diffuse;
    let _e454 = amplitude_2;
    let _e455 = specular;
    let _e458 = rl_5;
    let _e462 = window;
    let _e463 = window;
    let _e465 = area;
    return (((((_e449 * _e450) * _e452) + (_e454 * _e455)) * _e458.col_pad.xyz) * ((_e462 * _e463) / _e465));
}

fn evalRectLight(rl_6: GpuRectLight, N_20: vec3<f32>, V_12: vec3<f32>, F0_12: vec3<f32>, albedo_8: vec3<f32>, metallic_8: f32, roughness_16: f32) -> vec3<f32> {
    var rl_7: GpuRectLight;
    var N_21: vec3<f32>;
    var V_13: vec3<f32>;
    var F0_13: vec3<f32>;
    var albedo_9: vec3<f32>;
    var metallic_9: f32;
    var roughness_17: f32;

    rl_7 = rl_6;
    N_21 = N_20;
    V_13 = V_12;
    F0_13 = F0_12;
    albedo_9 = albedo_8;
    metallic_9 = metallic_8;
    roughness_17 = roughness_16;
    let _e124 = global_4.layer_info;
    if (_e124.w > 1.5f) {
        let _e128 = rl_7;
        let _e129 = N_21;
        let _e130 = V_13;
        let _e131 = F0_13;
        let _e132 = albedo_9;
        let _e133 = metallic_9;
        let _e134 = roughness_17;
        let _e135 = evalRectLightLtc(_e128, _e129, _e130, _e131, _e132, _e133, _e134);
        return _e135;
    }
    let _e136 = global_4.layer_info;
    if (_e136.w > 0.5f) {
        let _e140 = rl_7;
        let _e141 = N_21;
        let _e142 = V_13;
        let _e143 = F0_13;
        let _e144 = albedo_9;
        let _e145 = metallic_9;
        let _e146 = roughness_17;
        let _e147 = evalRectLightQuadrature(_e140, _e141, _e142, _e143, _e144, _e145, _e146);
        return _e147;
    }
    let _e148 = rl_7;
    let _e149 = N_21;
    let _e150 = V_13;
    let _e151 = F0_13;
    let _e152 = albedo_9;
    let _e153 = metallic_9;
    let _e154 = roughness_17;
    let _e155 = evalRectLightLegacy(_e148, _e149, _e150, _e151, _e152, _e153, _e154);
    return _e155;
}

fn main_1() {
    var tex_albedo: vec4<f32>;
    var albedo_a: vec4<f32>;
    var emissive_rgb: vec3<f32>;
    var mr: vec4<f32>;
    var metallic_10: f32;
    var roughness_18: f32;
    var N_22: vec3<f32>;
    var V_14: vec3<f32>;
    var nx: vec3<f32>;
    var ny: vec3<f32>;
    var variance_1: f32;
    var r2_: f32;
    var F0_14: vec3<f32>;
    var view_depth_4: f32;
    var suv_3: vec2<f32>;
    var ssao_sample: vec4<f32>;
    var local_19: f32;
    var ssao: f32;
    var local_20: f32;
    var contact_shadow: f32;
    var rot_7: f32;
    var Lo: vec3<f32> = vec3(0f);
    var L_12: vec3<f32>;
    var vis_1: f32;
    var cx_1: i32;
    var cy_1: i32;
    var cz: i32;
    var cl: vec4<u32>;
    var p_off: u32;
    var p_cnt: u32;
    var i_12: u32 = 0u;
    var pl: GpuPointLight;
    var to_l_1: vec3<f32>;
    var dist_3: f32;
    var range_3: f32;
    var att_2: f32;
    var L_13: vec3<f32>;
    var local_21: f32;
    var vis_2: f32;
    var s_off: u32;
    var s_cnt: u32;
    var i_13: u32 = 0u;
    var sl: GpuSpotLight;
    var to_l_2: vec3<f32>;
    var dist_4: f32;
    var range_4: f32;
    var L_14: vec3<f32>;
    var theta_1: f32;
    var eps: f32;
    var cone: f32;
    var att_3: f32;
    var spot_bias: f32;
    var local_22: f32;
    var vis_3: f32;
    var r_off: u32;
    var r_cnt: u32;
    var i_14: u32 = 0u;
    var rl_8: GpuRectLight;
    var NdotV_2: f32;
    var F_env: vec3<f32>;
    var kD_env: vec3<f32>;
    var irradiance: vec3<f32>;
    var diffuse_ibl: vec3<f32>;
    var R: vec3<f32>;
    var prefiltered: vec3<f32>;
    var probe_cnt: i32;
    var probe_irr: vec3<f32> = vec3(0f);
    var probe_spec: vec3<f32> = vec3(0f);
    var probe_w: f32 = 0f;
    var i_15: i32 = 0i;
    var pr: GpuReflectionProbe;
    var d_6: vec3<f32>;
    var edge_d: vec3<f32>;
    var f3_: vec3<f32>;
    var w_1: f32;
    var hemi: f32;
    var r_hemi: f32;
    var local_spec: vec3<f32>;
    var local_R: vec3<f32>;
    var relative: vec3<f32>;
    var side: vec3<f32>;
    var t_1: vec3<f32>;
    var axis: i32;
    var travel: f32;
    var corrected: vec3<f32>;
    var pw: f32;
    var dynamic_gi: vec4<f32>;
    var brdf: vec2<f32>;
    var FssEss: vec3<f32>;
    var Ess: f32;
    var Ems: f32;
    var Favg: vec3<f32>;
    var Fms: vec3<f32>;
    var specular_ibl: vec3<f32>;
    var ao_tex_val: f32;
    var diff_ao: f32;
    var spec_ao: f32;
    var ambient: vec3<f32>;
    var color: vec3<f32>;
    var d_7: f32;
    var fog_f: f32;

    let _e110 = v_uv_1;
    let _e111 = textureSample(zengy_u_base_color_tex_image, zengy_u_base_color_tex_sampler, _e110);
    tex_albedo = _e111;
    let _e113 = tex_albedo;
    let _e115 = global_4.base_color;
    let _e117 = (_e113.xyz * _e115.xyz);
    let _e118 = tex_albedo;
    let _e120 = global_4.base_color;
    albedo_a = vec4<f32>(_e117.x, _e117.y, _e117.z, (_e118.w * _e120.w));
    let _e128 = global_4.cluster_factors;
    let _e132 = albedo_a;
    let _e134 = global_4.cluster_factors;
    if ((_e128.w >= 0f) && (_e132.w < _e134.w)) {
        {
            discard;
        }
    }
    out_surface = vec4<f32>(0f, 0f, -1f, 0f);
    out_diffuse = vec4(0f);
    out_specular = vec4(0f);
    let _e154 = global_4.emissive_weight;
    let _e156 = v_uv_1;
    let _e157 = textureSample(zengy_u_emissive_tex_image, zengy_u_emissive_tex_sampler, _e156);
    emissive_rgb = (_e154.xyz * _e157.xyz);
    let _e161 = global_4.mat_flags;
    if (_e161.x > 0.5f) {
        {
            let _e165 = albedo_a;
            let _e167 = emissive_rgb;
            let _e169 = global_4.layer_info;
            let _e171 = ((_e165.xyz + _e167) * _e169.z);
            let _e172 = albedo_a;
            frag_color = vec4<f32>(_e171.x, _e171.y, _e171.z, _e172.w);
            return;
        }
    }
    let _e178 = v_uv_1;
    let _e179 = textureSample(zengy_u_mr_tex_image, zengy_u_mr_tex_sampler, _e178);
    mr = _e179;
    let _e181 = global_4.mat_params;
    let _e183 = mr;
    metallic_10 = clamp((_e181.x * _e183.z), 0f, 1f);
    let _e190 = global_4.mat_params;
    let _e192 = mr;
    roughness_18 = clamp((_e190.y * _e192.y), 0.045f, 1f);
    let _e199 = v_world_normal_1;
    N_22 = normalize(_e199);
    let _e203 = gl_FrontFacing_1;
    if !(_e203) {
        {
            let _e205 = N_22;
            N_22 = -(_e205);
        }
    }
    let _e207 = global_4.camera_pos_fog;
    let _e209 = v_world_pos_1;
    V_14 = normalize((_e207.xyz - _e209));
    let _e213 = global_4.mat_flags;
    if (_e213.y > 0f) {
        {
            let _e217 = N_22;
            let _e218 = V_14;
            let _e219 = v_uv_1;
            let _e220 = perturbNormal(_e217, _e218, _e219);
            N_22 = _e220;
        }
    }
    let _e223 = global_4.sh_coeffs[4];
    if (_e223.w > 0.5f) {
        {
            let _e227 = N_22;
            let _e228 = dpdx(_e227);
            nx = _e228;
            let _e230 = N_22;
            let _e231 = dpdy(_e230);
            ny = _e231;
            let _e235 = nx;
            let _e236 = nx;
            let _e238 = ny;
            let _e239 = ny;
            variance_1 = min(0.15f, (0.5f * (dot(_e235, _e236) + dot(_e238, _e239))));
            let _e245 = roughness_18;
            let _e246 = roughness_18;
            r2_ = (_e245 * _e246);
            let _e249 = r2_;
            let _e250 = r2_;
            let _e252 = variance_1;
            roughness_18 = pow(clamp(((_e249 * _e250) + _e252), 0.0000041f, 1f), 0.25f);
        }
    }
    let _e260 = global_4.mat_params;
    let _e263 = global_4.mat_params;
    let _e267 = albedo_a;
    let _e269 = metallic_10;
    F0_14 = mix(vec3(((0.16f * _e260.z) * _e263.z)), _e267.xyz, vec3(_e269));
    let _e273 = v_world_pos_1;
    let _e274 = global_4.camera_pos_fog;
    let _e277 = global_4.camera_fwd_overlap;
    view_depth_4 = max(dot((_e273 - _e274.xyz), normalize(_e277.xyz)), 0f);
    let _e284 = gl_FragCoord_1;
    let _e288 = global_4.sh_coeffs[1];
    let _e292 = global_4.sh_coeffs[2];
    suv_3 = (_e284.xy * vec2<f32>(_e288.w, _e292.w));
    let _e297 = suv_3;
    let _e298 = textureSample(zengy_u_ssao_tex_image, zengy_u_ssao_tex_sampler, _e297);
    ssao_sample = _e298;
    let _e302 = global_4.sh_coeffs[0];
    if (_e302.w > 0.5f) {
        let _e306 = ssao_sample;
        local_19 = _e306.x;
    } else {
        local_19 = 1f;
    }
    let _e310 = local_19;
    ssao = _e310;
    let _e314 = global_4.sh_coeffs[3];
    if (_e314.w > 0.5f) {
        let _e318 = ssao_sample;
        local_20 = _e318.y;
    } else {
        local_20 = 1f;
    }
    let _e322 = local_20;
    contact_shadow = _e322;
    let _e324 = gl_FragCoord_1;
    let _e326 = ign(_e324.xy);
    rot_7 = (_e326 * 6.2831855f);
    let _e333 = global_4.dir_light_dir;
    let _e337 = global_4.layer_info;
    let _e339 = global_4.layer_info;
    let _e341 = layersOverlap(_e337.y, _e339.x);
    if ((_e333.w > 0f) && _e341) {
        {
            let _e343 = global_4.dir_light_dir;
            L_12 = normalize(_e343.xyz);
            let _e347 = N_22;
            let _e348 = L_12;
            let _e349 = view_depth_4;
            let _e350 = sampleShadowCSM(_e347, _e348, _e349);
            let _e351 = contact_shadow;
            vis_1 = (_e350 * _e351);
            let _e354 = Lo;
            let _e355 = N_22;
            let _e356 = V_14;
            let _e357 = F0_14;
            let _e358 = albedo_a;
            let _e360 = metallic_10;
            let _e361 = roughness_18;
            let _e362 = L_12;
            let _e363 = global_4.dir_light_col;
            let _e365 = global_4.dir_light_dir;
            let _e369 = evalLight(_e355, _e356, _e357, _e358.xyz, _e360, _e361, _e362, (_e363.xyz * _e365.w), 1f);
            let _e370 = vis_1;
            Lo = (_e354 + (_e369 * _e370));
        }
    }
    let _e373 = global_4.cluster_factors;
    if (_e373.z > 0.5f) {
        {
            let _e377 = suv_3;
            cx_1 = clamp(i32((_e377.x * 16f)), 0i, 15i);
            let _e386 = suv_3;
            cy_1 = clamp(i32((_e386.y * 9f)), 0i, 8i);
            let _e395 = view_depth_4;
            let _e399 = global_4.cluster_factors;
            let _e402 = global_4.cluster_factors;
            cz = clamp(i32(floor(((log(max(_e395, 0.05f)) * _e399.x) - _e402.y))), 0i, 23i);
            let _e411 = cy_1;
            let _e414 = cx_1;
            let _e418 = cz;
            let _e421 = global_1.clusters[((((_e411 * 16i) + _e414) * 24i) + _e418)];
            cl = _e421;
            let _e423 = cl;
            p_off = (_e423.x >> 8u);
            let _e428 = cl;
            p_cnt = (_e428.x & 255u);
            loop {
                let _e435 = i_12;
                let _e436 = p_cnt;
                if !((_e435 < _e436)) {
                    break;
                }
                {
                    let _e442 = p_off;
                    let _e443 = i_12;
                    let _e446 = global_2.cluster_indices[(_e442 + _e443)];
                    let _e448 = global.c_points[_e446];
                    pl = _e448;
                    let _e450 = pl;
                    let _e453 = global_4.layer_info;
                    let _e455 = layersOverlap(_e450.shadow_params.y, _e453.x);
                    if !(_e455) {
                        continue;
                    }
                    let _e457 = pl;
                    let _e460 = v_world_pos_1;
                    to_l_1 = (_e457.pos_range.xyz - _e460);
                    let _e463 = to_l_1;
                    dist_3 = length(_e463);
                    let _e466 = pl;
                    range_3 = max(_e466.pos_range.w, 0.001f);
                    let _e472 = dist_3;
                    let _e473 = range_3;
                    if (_e472 < _e473) {
                        {
                            let _e476 = dist_3;
                            let _e477 = range_3;
                            att_2 = clamp((1f - pow((_e476 / _e477), 4f)), 0f, 1f);
                            let _e486 = att_2;
                            let _e487 = att_2;
                            let _e489 = dist_3;
                            let _e490 = dist_3;
                            let _e494 = pl;
                            let _e497 = pl;
                            att_2 = ((_e486 * _e487) / (((_e489 * _e490) + 1f) + (_e494.shadow_params.x * _e497.shadow_params.x)));
                            let _e503 = to_l_1;
                            let _e504 = dist_3;
                            L_13 = (_e503 / vec3(max(_e504, 0.0001f)));
                            let _e510 = N_22;
                            let _e511 = L_13;
                            if (dot(_e510, _e511) <= 0f) {
                                continue;
                            }
                            let _e515 = pl;
                            if (_e515.col_radius.w >= 0f) {
                                let _e520 = pl;
                                let _e526 = pl;
                                let _e529 = N_22;
                                let _e530 = L_13;
                                let _e531 = rot_7;
                                let _e532 = pl;
                                let _e535 = samplePointShadow(i32((_e520.col_radius.w + 0.5f)), _e526.pos_range.xyz, _e529, _e530, _e531, _e532.shadow_params.x);
                                local_21 = _e535;
                            } else {
                                local_21 = 1f;
                            }
                            let _e538 = local_21;
                            vis_2 = _e538;
                            let _e540 = Lo;
                            let _e541 = N_22;
                            let _e542 = V_14;
                            let _e543 = F0_14;
                            let _e544 = albedo_a;
                            let _e546 = metallic_10;
                            let _e547 = roughness_18;
                            let _e548 = L_13;
                            let _e549 = pl;
                            let _e552 = att_2;
                            let _e554 = pl;
                            let _e557 = evalLight(_e541, _e542, _e543, _e544.xyz, _e546, _e547, _e548, (_e549.col_radius.xyz * _e552), _e554.shadow_params.z);
                            let _e558 = vis_2;
                            Lo = (_e540 + (_e557 * _e558));
                        }
                    }
                }
                continuing {
                    let _e439 = i_12;
                    i_12 = (_e439 + 1u);
                }
            }
            let _e561 = cl;
            s_off = (_e561.y >> 8u);
            let _e566 = cl;
            s_cnt = (_e566.y & 255u);
            loop {
                let _e573 = i_13;
                let _e574 = s_cnt;
                if !((_e573 < _e574)) {
                    break;
                }
                {
                    let _e580 = s_off;
                    let _e581 = i_13;
                    let _e584 = global_2.cluster_indices[(_e580 + _e581)];
                    let _e586 = global.c_spots[_e584];
                    sl = _e586;
                    let _e588 = sl;
                    let _e591 = global_4.layer_info;
                    let _e593 = layersOverlap(_e588.shadow_params.w, _e591.x);
                    if !(_e593) {
                        continue;
                    }
                    let _e595 = sl;
                    let _e598 = v_world_pos_1;
                    to_l_2 = (_e595.pos_range.xyz - _e598);
                    let _e601 = to_l_2;
                    dist_4 = length(_e601);
                    let _e604 = sl;
                    range_4 = max(_e604.pos_range.w, 0.001f);
                    let _e610 = dist_4;
                    let _e611 = range_4;
                    if (_e610 < _e611) {
                        {
                            let _e613 = to_l_2;
                            let _e614 = dist_4;
                            L_14 = (_e613 / vec3(max(_e614, 0.0001f)));
                            let _e620 = L_14;
                            let _e621 = sl;
                            theta_1 = dot(_e620, normalize(-(_e621.dir_cos_inner.xyz)));
                            let _e628 = sl;
                            let _e631 = sl;
                            eps = max((_e628.dir_cos_inner.w - _e631.col_cos_outer.w), 0.001f);
                            let _e638 = theta_1;
                            let _e639 = sl;
                            let _e643 = eps;
                            cone = clamp(((_e638 - _e639.col_cos_outer.w) / _e643), 0f, 1f);
                            let _e650 = dist_4;
                            let _e651 = range_4;
                            att_3 = clamp((1f - pow((_e650 / _e651), 4f)), 0f, 1f);
                            let _e660 = att_3;
                            let _e661 = att_3;
                            let _e663 = dist_4;
                            let _e664 = dist_4;
                            att_3 = ((_e660 * _e661) / ((_e663 * _e664) + 1f));
                            let _e669 = cone;
                            let _e672 = N_22;
                            let _e673 = L_14;
                            if ((_e669 <= 0f) || (dot(_e672, _e673) <= 0f)) {
                                continue;
                            }
                            let _e680 = N_22;
                            let _e681 = L_14;
                            spot_bias = (0.0012f + ((1f - max(dot(_e680, _e681), 0f)) * 0.004f));
                            let _e690 = sl;
                            if (_e690.shadow_params.x >= 0f) {
                                let _e695 = sl;
                                let _e701 = v_world_pos_1;
                                let _e702 = spot_bias;
                                let _e703 = rot_7;
                                let _e704 = sl;
                                let _e707 = sampleLocalTile(i32((_e695.shadow_params.x + 0.5f)), _e701, _e702, _e703, _e704.shadow_params.z);
                                local_22 = _e707;
                            } else {
                                local_22 = 1f;
                            }
                            let _e710 = local_22;
                            vis_3 = _e710;
                            let _e712 = Lo;
                            let _e713 = N_22;
                            let _e714 = V_14;
                            let _e715 = F0_14;
                            let _e716 = albedo_a;
                            let _e718 = metallic_10;
                            let _e719 = roughness_18;
                            let _e720 = L_14;
                            let _e721 = sl;
                            let _e724 = att_3;
                            let _e726 = cone;
                            let _e729 = evalLight(_e713, _e714, _e715, _e716.xyz, _e718, _e719, _e720, ((_e721.col_cos_outer.xyz * _e724) * _e726), 1f);
                            let _e730 = vis_3;
                            Lo = (_e712 + (_e729 * _e730));
                        }
                    }
                }
                continuing {
                    let _e577 = i_13;
                    i_13 = (_e577 + 1u);
                }
            }
            let _e733 = cl;
            r_off = (_e733.z >> 8u);
            let _e738 = cl;
            r_cnt = (_e738.z & 255u);
            loop {
                let _e745 = i_14;
                let _e746 = r_cnt;
                if !((_e745 < _e746)) {
                    break;
                }
                {
                    let _e752 = r_off;
                    let _e753 = i_14;
                    let _e756 = global_2.cluster_indices[(_e752 + _e753)];
                    let _e758 = global.c_rects[_e756];
                    rl_8 = _e758;
                    let _e760 = rl_8;
                    let _e763 = global_4.layer_info;
                    let _e765 = layersOverlap(_e760.col_pad.w, _e763.x);
                    if !(_e765) {
                        continue;
                    }
                    let _e767 = Lo;
                    let _e768 = rl_8;
                    let _e769 = N_22;
                    let _e770 = V_14;
                    let _e771 = F0_14;
                    let _e772 = albedo_a;
                    let _e774 = metallic_10;
                    let _e775 = roughness_18;
                    let _e776 = evalRectLight(_e768, _e769, _e770, _e771, _e772.xyz, _e774, _e775);
                    Lo = (_e767 + _e776);
                }
                continuing {
                    let _e749 = i_14;
                    i_14 = (_e749 + 1u);
                }
            }
        }
    }
    let _e778 = N_22;
    let _e779 = V_14;
    NdotV_2 = max(dot(_e778, _e779), 0f);
    let _e784 = NdotV_2;
    let _e785 = F0_14;
    let _e786 = roughness_18;
    let _e787 = fresnelSchlickRoughness(_e784, _e785, _e786);
    F_env = _e787;
    let _e791 = F_env;
    let _e794 = metallic_10;
    kD_env = ((vec3(1f) - _e791) * (1f - _e794));
    let _e798 = N_22;
    let _e799 = evalSH9Diffuse(_e798);
    let _e800 = global_4.ambient_sky;
    irradiance = (_e799 + _e800.xyz);
    let _e804 = irradiance;
    let _e805 = albedo_a;
    diffuse_ibl = (_e804 * _e805.xyz);
    let _e809 = V_14;
    let _e811 = N_22;
    R = reflect(-(_e809), _e811);
    let _e814 = R;
    let _e815 = equirectUv(_e814);
    let _e816 = roughness_18;
    let _e817 = global_4.sky_horizon;
    let _e820 = textureSampleLevel(zengy_u_prefilter_env_image, zengy_u_prefilter_env_sampler, _e815, (_e816 * _e817.w));
    prefiltered = _e820.xyz;
    let _e823 = global_4.probe_volumetric;
    probe_cnt = i32((_e823.x + 0.5f));
    let _e829 = probe_cnt;
    if (_e829 > 0i) {
        {
            loop {
                let _e842 = i_15;
                if !((_e842 < 32i)) {
                    break;
                }
                {
                    let _e849 = i_15;
                    let _e850 = probe_cnt;
                    if (_e849 >= _e850) {
                        break;
                    }
                    let _e852 = i_15;
                    let _e854 = global.c_probes[_e852];
                    pr = _e854;
                    let _e856 = v_world_pos_1;
                    let _e857 = pr;
                    d_6 = abs((_e856 - _e857.pos_int.xyz));
                    let _e863 = pr;
                    let _e866 = d_6;
                    edge_d = (_e863.half_blend.xyz - _e866);
                    let _e869 = edge_d;
                    let _e873 = edge_d;
                    let _e878 = edge_d;
                    if (((_e869.x > 0f) && (_e873.y > 0f)) && (_e878.z > 0f)) {
                        {
                            let _e885 = pr;
                            let _e891 = edge_d;
                            f3_ = smoothstep(vec3(0f), vec3(max(_e885.half_blend.w, 0.05f)), _e891);
                            let _e894 = f3_;
                            let _e896 = f3_;
                            let _e899 = f3_;
                            let _e902 = pr;
                            w_1 = (((_e894.x * _e896.y) * _e899.z) * _e902.pos_int.w);
                            let _e907 = N_22;
                            hemi = ((_e907.y * 0.5f) + 0.5f);
                            let _e914 = probe_irr;
                            let _e915 = pr;
                            let _e918 = pr;
                            let _e921 = hemi;
                            let _e924 = w_1;
                            let _e925 = pr;
                            probe_irr = (_e914 + (mix(_e915.ground_pad.xyz, _e918.sky_box.xyz, vec3(_e921)) * (_e924 * _e925.ground_pad.w)));
                            let _e931 = R;
                            r_hemi = ((_e931.y * 0.5f) + 0.5f);
                            let _e938 = pr;
                            let _e941 = pr;
                            let _e944 = r_hemi;
                            local_spec = mix(_e938.ground_pad.xyz, _e941.sky_box.xyz, vec3(_e944));
                            let _e948 = pr;
                            if (_e948.environment_info.x > 0.5f) {
                                {
                                    let _e953 = R;
                                    local_R = _e953;
                                    let _e955 = pr;
                                    if (_e955.sky_box.w > 0.5f) {
                                        {
                                            let _e960 = v_world_pos_1;
                                            let _e961 = pr;
                                            relative = (_e960 - _e961.pos_int.xyz);
                                            let _e966 = pr;
                                            let _e970 = pr;
                                            let _e973 = R;
                                            side = select(-(_e966.half_blend.xyz), _e970.half_blend.xyz, (_e973 >= vec3(0f)));
                                            t_1 = vec3(100000000000000000000f);
                                            axis = 0i;
                                            loop {
                                                let _e985 = axis;
                                                if !((_e985 < 3i)) {
                                                    break;
                                                }
                                                let _e992 = axis;
                                                let _e994 = R[_e992];
                                                if (abs(_e994) > 0.000001f) {
                                                    let _e998 = axis;
                                                    let _e1000 = axis;
                                                    let _e1002 = side[_e1000];
                                                    let _e1003 = axis;
                                                    let _e1005 = relative[_e1003];
                                                    let _e1007 = axis;
                                                    let _e1009 = R[_e1007];
                                                    t_1[_e998] = ((_e1002 - _e1005) / _e1009);
                                                }
                                                continuing {
                                                    let _e989 = axis;
                                                    axis = (_e989 + 1i);
                                                }
                                            }
                                            let _e1011 = t_1;
                                            let _e1013 = t_1;
                                            let _e1016 = t_1;
                                            travel = max(min(min(_e1011.x, _e1013.y), _e1016.z), 0f);
                                            let _e1022 = relative;
                                            let _e1023 = R;
                                            let _e1024 = travel;
                                            corrected = (_e1022 + (_e1023 * _e1024));
                                            let _e1028 = corrected;
                                            let _e1029 = corrected;
                                            if (dot(_e1028, _e1029) > 0.00000001f) {
                                                let _e1033 = corrected;
                                                local_R = normalize(_e1033);
                                            }
                                        }
                                    }
                                    let _e1035 = local_R;
                                    let _e1036 = equirectUv(_e1035);
                                    let _e1037 = roughness_18;
                                    let _e1038 = pr;
                                    let _e1042 = textureSampleLevel(zengy_u_probe_environment_image, zengy_u_probe_environment_sampler, _e1036, (_e1037 * _e1038.environment_info.y));
                                    local_spec = _e1042.xyz;
                                }
                            }
                            let _e1044 = probe_spec;
                            let _e1045 = local_spec;
                            let _e1046 = w_1;
                            probe_spec = (_e1044 + (_e1045 * _e1046));
                            let _e1049 = probe_w;
                            let _e1050 = w_1;
                            probe_w = (_e1049 + _e1050);
                        }
                    }
                }
                continuing {
                    let _e846 = i_15;
                    i_15 = (_e846 + 1i);
                }
            }
            let _e1052 = probe_w;
            pw = clamp(_e1052, 0f, 1f);
            let _e1057 = pw;
            if (_e1057 > 0f) {
                {
                    let _e1060 = diffuse_ibl;
                    let _e1061 = probe_irr;
                    let _e1062 = probe_w;
                    let _e1067 = albedo_a;
                    let _e1070 = pw;
                    diffuse_ibl = mix(_e1060, ((_e1061 / vec3(max(_e1062, 0.0001f))) * _e1067.xyz), vec3(_e1070));
                    let _e1073 = prefiltered;
                    let _e1074 = probe_spec;
                    let _e1075 = probe_w;
                    let _e1080 = pw;
                    prefiltered = mix(_e1073, (_e1074 / vec3(max(_e1075, 0.0001f))), vec3(_e1080));
                }
            }
        }
    }
    let _e1083 = v_world_pos_1;
    let _e1084 = N_22;
    let _e1088 = N_22;
    let _e1089 = sampleDynamicGi((_e1083 + (_e1084 * 0.03f)), _e1088);
    dynamic_gi = _e1089;
    let _e1091 = diffuse_ibl;
    let _e1092 = dynamic_gi;
    let _e1094 = albedo_a;
    let _e1097 = dynamic_gi;
    diffuse_ibl = mix(_e1091, (_e1092.xyz * _e1094.xyz), vec3(_e1097.w));
    let _e1101 = NdotV_2;
    let _e1102 = roughness_18;
    let _e1104 = textureSample(zengy_u_brdf_lut_image, zengy_u_brdf_lut_sampler, vec2<f32>(_e1101, _e1102));
    brdf = _e1104.xy;
    let _e1107 = F0_14;
    let _e1108 = brdf;
    let _e1111 = brdf;
    FssEss = ((_e1107 * _e1108.x) + vec3(_e1111.y));
    let _e1116 = brdf;
    let _e1118 = brdf;
    Ess = (_e1116.x + _e1118.y);
    let _e1123 = Ess;
    Ems = (1f - _e1123);
    let _e1126 = F0_14;
    let _e1128 = F0_14;
    Favg = (_e1126 + ((vec3(1f) - _e1128) / vec3(21f)));
    let _e1136 = FssEss;
    let _e1137 = Favg;
    let _e1141 = Ems;
    let _e1142 = Favg;
    Fms = ((_e1136 * _e1137) / max((vec3(1f) - (_e1141 * _e1142)), vec3(0.0001f)));
    let _e1150 = prefiltered;
    let _e1151 = FssEss;
    let _e1152 = Fms;
    let _e1153 = Ems;
    specular_ibl = (_e1150 * (_e1151 + (_e1152 * _e1153)));
    let _e1158 = v_uv_1;
    let _e1159 = textureSample(zengy_u_ao_tex_image, zengy_u_ao_tex_sampler, _e1158);
    ao_tex_val = _e1159.x;
    let _e1163 = ao_tex_val;
    let _e1164 = global_4.mat_params;
    let _e1167 = ssao;
    diff_ao = (mix(1f, _e1163, _e1164.w) * _e1167);
    let _e1170 = NdotV_2;
    let _e1171 = diff_ao;
    let _e1175 = roughness_18;
    let _e1183 = diff_ao;
    spec_ao = clamp(((pow((_e1170 + _e1171), exp2(((-16f * _e1175) - 1f))) - 1f) + _e1183), 0f, 1f);
    let _e1189 = kD_env;
    let _e1190 = diffuse_ibl;
    let _e1192 = diff_ao;
    let _e1194 = specular_ibl;
    let _e1195 = spec_ao;
    ambient = (((_e1189 * _e1190) * _e1192) + (_e1194 * _e1195));
    let _e1201 = global_4.sh_coeffs[5];
    let _e1205 = N_22;
    let _e1206 = zy_isnan_2(_e1205);
    let _e1210 = N_22;
    let _e1211 = zy_isinf_2(_e1210);
    let _e1215 = N_22;
    let _e1216 = N_22;
    let _e1221 = albedo_a;
    let _e1223 = zy_isnan_2(_e1221.xyz);
    let _e1227 = albedo_a;
    let _e1229 = zy_isinf_2(_e1227.xyz);
    if ((((((_e1201.w < 0.5f) && !(any(_e1206))) && !(any(_e1211))) && (dot(_e1215, _e1216) > 0.000001f)) && !(any(_e1223))) && !(any(_e1229))) {
        {
            let _e1233 = N_22;
            let _e1234 = encodeNormal(_e1233);
            let _e1235 = roughness_18;
            let _e1236 = metallic_10;
            let _e1237 = global_4.mat_params;
            let _e1240 = packRgb(vec3<f32>(_e1235, _e1236, _e1237.z));
            let _e1241 = albedo_a;
            let _e1243 = packRgb(_e1241.xyz);
            out_surface = vec4<f32>(_e1234.x, _e1234.y, _e1240, _e1243);
            let _e1247 = kD_env;
            let _e1248 = diffuse_ibl;
            let _e1250 = diff_ao;
            let _e1252 = global_4.layer_info;
            let _e1254 = (((_e1247 * _e1248) * _e1250) * _e1252.z);
            let _e1255 = diff_ao;
            out_diffuse = vec4<f32>(_e1254.x, _e1254.y, _e1254.z, _e1255);
            let _e1260 = specular_ibl;
            let _e1261 = spec_ao;
            let _e1263 = global_4.layer_info;
            let _e1265 = ((_e1260 * _e1261) * _e1263.z);
            let _e1266 = spec_ao;
            out_specular = vec4<f32>(_e1265.x, _e1265.y, _e1265.z, _e1266);
        }
    }
    let _e1271 = ambient;
    let _e1272 = Lo;
    let _e1274 = emissive_rgb;
    color = ((_e1271 + _e1272) + _e1274);
    let _e1277 = global_4.camera_pos_fog;
    let _e1281 = global_4.probe_volumetric;
    if ((_e1277.w > 0.5f) && (_e1281.z < 0.5f)) {
        {
            let _e1286 = global_4.camera_pos_fog;
            let _e1288 = v_world_pos_1;
            let _e1291 = global_4.fog_color_start;
            d_7 = max((length((_e1286.xyz - _e1288)) - _e1291.w), 0f);
            let _e1298 = d_7;
            let _e1300 = global_4.ambient_sky;
            fog_f = (1f - exp((-(_e1298) * _e1300.w)));
            let _e1306 = color;
            let _e1307 = global_4.fog_color_start;
            let _e1309 = fog_f;
            color = mix(_e1306, _e1307.xyz, vec3(clamp(_e1309, 0f, 1f)));
        }
    }
    let _e1315 = color;
    let _e1316 = global_4.layer_info;
    let _e1318 = (_e1315 * _e1316.z);
    let _e1319 = albedo_a;
    frag_color = vec4<f32>(_e1318.x, _e1318.y, _e1318.z, _e1319.w);
    return;
}

@fragment 
fn main(@location(0) v_world_pos: vec3<f32>, @location(1) v_world_normal: vec3<f32>, @location(2) v_uv: vec2<f32>, @location(3) v_light_pos: vec4<f32>, @location(4) v_light_pos_1: vec4<f32>, @location(5) v_light_pos_2: vec4<f32>, @location(6) v_light_pos_3: vec4<f32>, @builtin(position) gl_FragCoord: vec4<f32>, @builtin(front_facing) gl_FrontFacing: bool) -> FragmentOutput {
    v_world_pos_1 = v_world_pos;
    v_world_normal_1 = v_world_normal;
    v_uv_1 = v_uv;
    v_light_pos_4[0] = v_light_pos;
    v_light_pos_4[1] = v_light_pos_1;
    v_light_pos_4[2] = v_light_pos_2;
    v_light_pos_4[3] = v_light_pos_3;
    gl_FragCoord_1 = gl_FragCoord;
    gl_FrontFacing_1 = gl_FrontFacing;
    main_1();
    let _e166 = frag_color;
    let _e168 = out_surface;
    let _e170 = out_diffuse;
    let _e172 = out_specular;
    return FragmentOutput(_e166, _e168, _e170, _e172);
}
