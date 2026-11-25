// Ported from pbr.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
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
    let _e112 = roughness_1;
    let _e113 = roughness_1;
    a = (_e112 * _e113);
    let _e116 = a;
    let _e117 = a;
    a2_ = (_e116 * _e117);
    let _e120 = N_1;
    let _e121 = H_1;
    NdotH = max(dot(_e120, _e121), 0f);
    let _e126 = NdotH;
    let _e127 = NdotH;
    let _e129 = a2_;
    denom = (((_e126 * _e127) * (_e129 - 1f)) + 1f);
    let _e136 = a2_;
    let _e137 = denom;
    let _e139 = denom;
    return (_e136 / max(((PI * _e137) * _e139), 0.0001f));
}

fn geometrySchlickGGX(NdotV: f32, roughness_2: f32) -> f32 {
    var NdotV_1: f32;
    var roughness_3: f32;
    var r: f32;
    var k: f32;

    NdotV_1 = NdotV;
    roughness_3 = roughness_2;
    let _e110 = roughness_3;
    r = (_e110 + 1f);
    let _e114 = r;
    let _e115 = r;
    k = ((_e114 * _e115) / 8f);
    let _e120 = NdotV_1;
    let _e121 = NdotV_1;
    let _e123 = k;
    let _e126 = k;
    return (_e120 / max(((_e121 * (1f - _e123)) + _e126), 0.0001f));
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
    let _e114 = N_3;
    let _e115 = V_1;
    let _e119 = roughness_5;
    let _e120 = geometrySchlickGGX(max(dot(_e114, _e115), 0f), _e119);
    let _e121 = N_3;
    let _e122 = L_1;
    let _e126 = roughness_5;
    let _e127 = geometrySchlickGGX(max(dot(_e121, _e122), 0f), _e126);
    return (_e120 * _e127);
}

fn fresnelSchlick(cosTheta: f32, F0_: vec3<f32>) -> vec3<f32> {
    var cosTheta_1: f32;
    var F0_1: vec3<f32>;

    cosTheta_1 = cosTheta;
    F0_1 = F0_;
    let _e110 = F0_1;
    let _e112 = F0_1;
    let _e116 = cosTheta_1;
    return (_e110 + ((vec3(1f) - _e112) * pow(clamp((1f - _e116), 0f, 1f), 5f)));
}

fn fresnelSchlickRoughness(cosTheta_2: f32, F0_2: vec3<f32>, roughness_6: f32) -> vec3<f32> {
    var cosTheta_3: f32;
    var F0_3: vec3<f32>;
    var roughness_7: f32;

    cosTheta_3 = cosTheta_2;
    F0_3 = F0_2;
    roughness_7 = roughness_6;
    let _e112 = F0_3;
    let _e114 = roughness_7;
    let _e117 = F0_3;
    let _e119 = F0_3;
    let _e122 = cosTheta_3;
    return (_e112 + ((max(vec3((1f - _e114)), _e117) - _e119) * pow(clamp((1f - _e122), 0f, 1f), 5f)));
}

fn evalSH9Diffuse(n: vec3<f32>) -> vec3<f32> {
    var n_1: vec3<f32>;
    var b: array<f32, 9>;
    var res: vec3<f32> = vec3(0f);
    var i: i32 = 0i;

    n_1 = n;
    b[0i] = 0.282095f;
    let _e115 = n_1;
    b[1i] = (0.488603f * _e115.y);
    let _e121 = n_1;
    b[2i] = (0.488603f * _e121.z);
    let _e127 = n_1;
    b[3i] = (0.488603f * _e127.x);
    let _e133 = n_1;
    let _e136 = n_1;
    b[4i] = ((1.092548f * _e133.x) * _e136.y);
    let _e142 = n_1;
    let _e145 = n_1;
    b[5i] = ((1.092548f * _e142.y) * _e145.z);
    let _e152 = n_1;
    let _e155 = n_1;
    b[6i] = (0.315392f * (((3f * _e152.z) * _e155.z) - 1f));
    let _e164 = n_1;
    let _e167 = n_1;
    b[7i] = ((1.092548f * _e164.x) * _e167.z);
    let _e173 = n_1;
    let _e175 = n_1;
    let _e178 = n_1;
    let _e180 = n_1;
    b[8i] = (0.546274f * ((_e173.x * _e175.x) - (_e178.y * _e180.y)));
    loop {
        let _e190 = i;
        if !((_e190 < 9i)) {
            break;
        }
        {
            let _e197 = res;
            let _e198 = i;
            let _e200 = global_4.sh_coeffs[_e198];
            let _e202 = i;
            let _e204 = b[_e202];
            res = (_e197 + (_e200.xyz * _e204));
        }
        continuing {
            let _e194 = i;
            i = (_e194 + 1i);
        }
    }
    let _e207 = res;
    return max(_e207, vec3(0f));
}

fn equirectUv(d: vec3<f32>) -> vec2<f32> {
    var d_1: vec3<f32>;
    var u: f32;
    var v_16: f32;

    d_1 = d;
    let _e108 = d_1;
    let _e110 = d_1;
    u = ((atan2(_e108.x, -(_e110.z)) / 6.2831855f) + 0.5f);
    let _e121 = d_1;
    v_16 = (acos(clamp(_e121.y, -1f, 1f)) / PI);
    let _e130 = u;
    let _e131 = v_16;
    return vec2<f32>(_e130, _e131);
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
    let _e112 = uv_1;
    let _e113 = textureSample(zengy_u_normal_tex_image, zengy_u_normal_tex_sampler, _e112);
    map_n = ((_e113.xyz * 2f) - vec3(1f));
    let _e121 = map_n;
    if (length(_e121) < 0.01f) {
        let _e125 = N_5;
        return _e125;
    }
    let _e126 = map_n;
    let _e128 = map_n;
    let _e130 = global_4.mat_flags;
    let _e132 = (_e128.xy * _e130.y);
    map_n.x = _e132.x;
    map_n.y = _e132.y;
    let _e137 = v_world_pos_1;
    let _e138 = dpdx(_e137);
    dp1_ = _e138;
    let _e140 = v_world_pos_1;
    let _e141 = dpdy(_e140);
    dp2_ = _e141;
    let _e143 = uv_1;
    let _e144 = dpdx(_e143);
    duv1_ = _e144;
    let _e146 = uv_1;
    let _e147 = dpdy(_e146);
    duv2_ = _e147;
    let _e149 = dp2_;
    let _e150 = N_5;
    dp2perp = cross(_e149, _e150);
    let _e153 = N_5;
    let _e154 = dp1_;
    dp1perp = cross(_e153, _e154);
    let _e157 = dp2perp;
    let _e158 = duv1_;
    let _e161 = dp1perp;
    let _e162 = duv2_;
    T = ((_e157 * _e158.x) + (_e161 * _e162.x));
    let _e167 = dp2perp;
    let _e168 = duv1_;
    let _e171 = dp1perp;
    let _e172 = duv2_;
    B = ((_e167 * _e168.y) + (_e171 * _e172.y));
    let _e177 = T;
    let _e178 = T;
    let _e180 = B;
    let _e181 = B;
    invmax = inverseSqrt((max(dot(_e177, _e178), dot(_e180, _e181)) + 0.00000001f));
    let _e188 = T;
    let _e189 = invmax;
    let _e190 = (_e188 * _e189);
    let _e191 = B;
    let _e192 = invmax;
    let _e193 = (_e191 * _e192);
    let _e194 = N_5;
    TBN = mat3x3<f32>(vec3<f32>(_e190.x, _e190.y, _e190.z), vec3<f32>(_e193.x, _e193.y, _e193.z), vec3<f32>(_e194.x, _e194.y, _e194.z));
    let _e209 = TBN;
    let _e210 = map_n;
    return normalize((_e209 * _e210));
}

fn layersOverlap(light_mask: f32, mesh_mask: f32) -> bool {
    var light_mask_1: f32;
    var mesh_mask_1: f32;

    light_mask_1 = light_mask;
    mesh_mask_1 = mesh_mask;
    let _e110 = light_mask_1;
    let _e112 = mesh_mask_1;
    return ((u32(_e110) & u32(_e112)) != 0u);
}

fn ign(p: vec2<f32>) -> f32 {
    var p_1: vec2<f32>;

    p_1 = p;
    let _e109 = p_1;
    return fract((52.982918f * fract(dot(_e109, vec2<f32>(0.06711056f, 0.00583715f)))));
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
    let _e112 = idx_1;
    let _e116 = count_1;
    r_1 = sqrt(((f32(_e112) + 0.5f) / f32(_e116)));
    let _e121 = idx_1;
    let _e125 = phi_1;
    theta = ((f32(_e121) * 2.3999631f) + _e125);
    let _e128 = theta;
    let _e130 = theta;
    let _e133 = r_1;
    return (vec2<f32>(cos(_e128), sin(_e130)) * _e133);
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
    var local: f32;
    var pcss_boost: f32;
    var radius_texels: f32;
    var local_1: i32;
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
    let _e116 = c_idx_1;
    let _e118 = v_light_pos_4[_e116];
    light_pos = _e118;
    let _e120 = light_pos;
    let _e122 = light_pos;
    proj = (_e120.xyz / vec3(max(_e122.w, 0.0001f)));
    let _e129 = proj;
    let _e136 = proj;
    uv_2 = vec2<f32>(((_e129.x * 0.5f) + 0.5f), (0.5f - (_e136.y * 0.5f)));
    let _e143 = uv_2;
    let _e147 = uv_2;
    let _e152 = uv_2;
    let _e157 = uv_2;
    let _e162 = proj;
    let _e167 = proj;
    if ((((((_e143.x < 0.01f) || (_e147.x > 0.99f)) || (_e152.y < 0.01f)) || (_e157.y > 0.99f)) || (_e162.z > 1f)) || (_e167.z < 0f)) {
        {
            return -1f;
        }
    }
    let _e174 = c_idx_1;
    let _e180 = c_idx_1;
    q_min = vec2<f32>((f32((_e174 & 1i)) * 0.5f), (f32((_e180 >> 1u)) * 0.5f));
    let _e189 = q_min;
    q_max = (_e189 + vec2<f32>(0.5f, 0.5f));
    let _e195 = q_min;
    let _e196 = q_max;
    let _e197 = uv_2;
    uv_2 = mix(_e195, _e196, _e197);
    let _e200 = N_7;
    let _e201 = L_3;
    slope = (1f - max(dot(_e200, _e201), 0f));
    let _e207 = c_idx_1;
    let _e209 = global_4.cascade_depth_ranges[_e207];
    depth_range = max(_e209, 1f);
    let _e213 = global_4.cascade_info;
    let _e215 = global_4.mat_flags;
    let _e221 = slope;
    let _e227 = c_idx_1;
    bias_m = ((max(_e213.z, (_e215.z * 8f)) * (1f + (_e221 * 3.5f))) * (1f + (f32(_e227) * 0.65f)));
    let _e234 = bias_m;
    let _e235 = depth_range;
    bias = (_e234 / _e235);
    let _e240 = textureDimensions(zengy_u_shadow_tex_image, 0i);
    texel = (vec2(1f) / vec2<f32>(vec2<i32>(_e240)));
    let _e246 = global_4.probe_volumetric;
    if (_e246.y > 0.5f) {
        let _e251 = view_depth_1;
        local = (1f + clamp((_e251 / 30f), 0f, 1.5f));
    } else {
        local = 1f;
    }
    let _e260 = local;
    pcss_boost = _e260;
    let _e263 = c_idx_1;
    let _e268 = pcss_boost;
    radius_texels = ((2.2f - (f32(_e263) * 0.2f)) * _e268);
    let _e271 = c_idx_1;
    if (_e271 < 2i) {
        local_1 = 12i;
    } else {
        local_1 = 8i;
    }
    let _e277 = local_1;
    taps = _e277;
    let _e279 = global_4.probe_volumetric;
    if (_e279.y > 1.5f) {
        {
            let _e284 = c_idx_1;
            let _e286 = global_4.cascade_splits[_e284];
            texel_world = ((2f * max((_e286 * 1.25f), 12f)) / 1024f);
            loop {
                let _e301 = i_1;
                if !((_e301 < 12i)) {
                    break;
                }
                {
                    let _e308 = i_1;
                    let _e310 = rot_1;
                    let _e311 = vogelDisk(_e308, 12i, _e310);
                    let _e314 = texel;
                    o = ((_e311 * 6f) * _e314);
                    let _e317 = uv_2;
                    let _e318 = o;
                    let _e320 = q_min;
                    let _e321 = texel;
                    let _e323 = q_max;
                    let _e324 = texel;
                    suv = clamp((_e317 + _e318), (_e320 + _e321), (_e323 - _e324));
                    let _e328 = suv;
                    let _e330 = textureSampleLevel(zengy_u_shadow_raw_image, zengy_u_shadow_raw_sampler, _e328, 0f);
                    r_2 = _e330.x;
                    let _e333 = r_2;
                    let _e334 = proj;
                    let _e336 = bias;
                    if (_e333 < (_e334.z - _e336)) {
                        {
                            let _e339 = blocker_sum;
                            let _e340 = r_2;
                            blocker_sum = (_e339 + _e340);
                            let _e342 = blocker_n;
                            blocker_n = (_e342 + 1f);
                        }
                    }
                }
                continuing {
                    let _e305 = i_1;
                    i_1 = (_e305 + 1i);
                }
            }
            let _e345 = blocker_n;
            if (_e345 < 0.5f) {
                return 1f;
            }
            let _e349 = proj;
            let _e351 = blocker_sum;
            let _e352 = blocker_n;
            let _e355 = depth_range;
            depth_gap_m = ((_e349.z - (_e351 / _e352)) * _e355);
            let _e358 = depth_gap_m;
            let _e359 = global_4.cascade_info;
            let _e362 = texel_world;
            radius_texels = clamp(((_e358 * _e359.y) / _e362), 1f, 14f);
            taps = 16i;
        }
    }
    loop {
        let _e372 = i_2;
        let _e373 = taps;
        if !((_e372 < _e373)) {
            break;
        }
        {
            let _e379 = i_2;
            let _e380 = taps;
            let _e381 = rot_1;
            let _e382 = vogelDisk(_e379, _e380, _e381);
            let _e383 = radius_texels;
            let _e385 = texel;
            o_1 = ((_e382 * _e383) * _e385);
            let _e388 = uv_2;
            let _e389 = o_1;
            let _e391 = q_min;
            let _e392 = texel;
            let _e394 = q_max;
            let _e395 = texel;
            suv_1 = clamp((_e388 + _e389), (_e391 + _e392), (_e394 - _e395));
            let _e399 = shadow;
            let _e400 = suv_1;
            let _e401 = proj;
            let _e403 = bias;
            let _e407 = vec3<f32>(_e400.x, _e400.y, (_e401.z - _e403));
            let _e410 = textureSampleCompareLevel(zengy_u_shadow_tex_image, zengy_u_shadow_tex_sampler, _e407.xy, _e407.z);
            shadow = (_e399 + _e410);
        }
        continuing {
            let _e376 = i_2;
            i_2 = (_e376 + 1i);
        }
    }
    let _e412 = shadow;
    let _e413 = taps;
    return (_e412 / f32(_e413));
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
    var local_2: f32;
    var prev_b: f32;
    var split: f32;
    var band: f32;
    var t: f32;
    var next_lit: f32;
    var fade: f32;

    N_9 = N_8;
    L_5 = L_4;
    view_depth_3 = view_depth_2;
    let _e112 = global_4.cascade_info;
    count_2 = clamp(i32((_e112.x + 0.5f)), 0i, 4i);
    let _e121 = global_4.mat_flags;
    let _e125 = count_2;
    if ((_e121.w < 0.5f) || (_e125 == 0i)) {
        return 1f;
    }
    let _e130 = count_2;
    let _e134 = global_4.cascade_splits[(_e130 - 1i)];
    max_dist = max(_e134, 1f);
    let _e138 = view_depth_3;
    let _e139 = max_dist;
    if (_e138 > _e139) {
        return 1f;
    }
    loop {
        let _e146 = i_3;
        if !((_e146 < 3i)) {
            break;
        }
        {
            let _e153 = i_3;
            let _e154 = count_2;
            let _e158 = view_depth_3;
            let _e159 = i_3;
            let _e161 = global_4.cascade_splits[_e159];
            if ((_e153 < (_e154 - 1i)) && (_e158 > _e161)) {
                let _e164 = i_3;
                idx_2 = (_e164 + 1i);
            }
        }
        continuing {
            let _e150 = i_3;
            i_3 = (_e150 + 1i);
        }
    }
    let _e168 = gl_FragCoord_1;
    let _e170 = ign(_e168.xy);
    rot_2 = (_e170 * 6.2831855f);
    let _e174 = idx_2;
    let _e175 = N_9;
    let _e176 = L_5;
    let _e177 = rot_2;
    let _e178 = view_depth_3;
    let _e179 = sampleCascadePCF(_e174, _e175, _e176, _e177, _e178);
    lit = _e179;
    let _e181 = lit;
    if (_e181 < 0f) {
        {
            let _e184 = idx_2;
            k_1 = (_e184 + 1i);
            loop {
                let _e188 = k_1;
                let _e189 = count_2;
                if !((_e188 < _e189)) {
                    break;
                }
                {
                    let _e195 = k_1;
                    let _e196 = N_9;
                    let _e197 = L_5;
                    let _e198 = rot_2;
                    let _e199 = view_depth_3;
                    let _e200 = sampleCascadePCF(_e195, _e196, _e197, _e198, _e199);
                    lit = _e200;
                    let _e201 = lit;
                    if (_e201 >= 0f) {
                        break;
                    }
                }
                continuing {
                    let _e192 = k_1;
                    k_1 = (_e192 + 1i);
                }
            }
            let _e204 = lit;
            if (_e204 < 0f) {
                lit = 1f;
            }
        }
    } else {
        let _e208 = idx_2;
        let _e209 = count_2;
        if (_e208 < (_e209 - 1i)) {
            {
                let _e213 = idx_2;
                if (_e213 == 0i) {
                    local_2 = 0f;
                } else {
                    let _e217 = idx_2;
                    let _e221 = global_4.cascade_splits[(_e217 - 1i)];
                    local_2 = _e221;
                }
                let _e223 = local_2;
                prev_b = _e223;
                let _e225 = idx_2;
                let _e227 = global_4.cascade_splits[_e225];
                split = _e227;
                let _e229 = split;
                let _e230 = prev_b;
                let _e232 = global_4.camera_fwd_overlap;
                band = max(((_e229 - _e230) * clamp(_e232.w, 0.02f, 0.4f)), 0.5f);
                let _e241 = view_depth_3;
                let _e242 = split;
                let _e243 = band;
                let _e246 = band;
                t = clamp(((_e241 - (_e242 - _e243)) / _e246), 0f, 1f);
                let _e252 = t;
                if (_e252 > 0f) {
                    {
                        let _e255 = idx_2;
                        let _e258 = N_9;
                        let _e259 = L_5;
                        let _e260 = rot_2;
                        let _e261 = view_depth_3;
                        let _e262 = sampleCascadePCF((_e255 + 1i), _e258, _e259, _e260, _e261);
                        next_lit = _e262;
                        let _e264 = next_lit;
                        if (_e264 >= 0f) {
                            let _e267 = lit;
                            let _e268 = next_lit;
                            let _e269 = t;
                            lit = mix(_e267, _e268, _e269);
                        }
                    }
                }
            }
        }
    }
    let _e271 = view_depth_3;
    let _e272 = max_dist;
    let _e276 = max_dist;
    fade = clamp(((_e271 - (_e272 * 0.85f)) / (_e276 * 0.15f)), 0f, 1f);
    let _e284 = lit;
    let _e286 = fade;
    return mix(_e284, 1f, _e286);
}

fn localLinearDepth(z: f32, near_d: f32, far_d: f32) -> f32 {
    var z_1: f32;
    var near_d_1: f32;
    var far_d_1: f32;

    z_1 = z;
    near_d_1 = near_d;
    far_d_1 = far_d;
    let _e113 = near_d_1;
    let _e114 = far_d_1;
    let _e116 = far_d_1;
    let _e117 = z_1;
    let _e118 = far_d_1;
    let _e119 = near_d_1;
    return ((_e113 * _e114) / max((_e116 - (_e117 * (_e118 - _e119))), 0.0001f));
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
    let _e117 = tile_idx_1;
    let _e120 = tile_idx_1;
    if ((_e117 < 0i) || (_e120 >= 16i)) {
        return 1f;
    }
    let _e125 = tile_idx_1;
    let _e127 = global_3.local_shadow_vp[_e125];
    let _e128 = world_pos_1;
    lp = (_e127 * vec4<f32>(_e128.x, _e128.y, _e128.z, 1f));
    let _e136 = lp;
    if (_e136.w <= 0.001f) {
        return 1f;
    }
    let _e141 = lp;
    let _e143 = lp;
    proj_1 = (_e141.xyz / vec3(_e143.w));
    let _e148 = proj_1;
    let _e155 = proj_1;
    uv_3 = vec2<f32>(((_e148.x * 0.5f) + 0.5f), (0.5f - (_e155.y * 0.5f)));
    let _e162 = uv_3;
    let _e166 = uv_3;
    let _e171 = uv_3;
    let _e176 = uv_3;
    let _e181 = proj_1;
    let _e186 = proj_1;
    if ((((((_e162.x < 0f) || (_e166.x > 1f)) || (_e171.y < 0f)) || (_e176.y > 1f)) || (_e181.z < 0f)) || (_e186.z > 1f)) {
        {
            return 1f;
        }
    }
    let _e192 = tile_idx_1;
    let _e194 = global_3.local_atlas_rect[_e192];
    rect = _e194;
    let _e196 = rect;
    let _e198 = uv_3;
    let _e199 = rect;
    suv_2 = (_e196.xy + (_e198 * _e199.zw));
    let _e206 = textureDimensions(zengy_u_local_shadow_tex_image, 0i);
    texel_1 = (vec2(1f) / vec2<f32>(vec2<i32>(_e206)));
    let _e213 = rect;
    radius_texels_1 = (1.6f * (_e213.z / 0.25f));
    let _e221 = global_4.cascade_info;
    let _e225 = light_size_1;
    if ((_e221.w > 0.5f) && (_e225 > 0f)) {
        {
            let _e229 = tile_idx_1;
            let _e231 = global_3.local_shadow_info[_e229];
            info = _e231;
            let _e233 = rect;
            let _e236 = textureDimensions(zengy_u_local_shadow_tex_image, 0i);
            tile_px = (_e233.z * f32(vec2<i32>(_e236).x));
            let _e242 = proj_1;
            let _e244 = info;
            let _e246 = info;
            let _e248 = localLinearDepth(_e242.z, _e244.y, _e246.z);
            d_r = _e248;
            let _e251 = d_r;
            let _e253 = info;
            let _e256 = tile_px;
            texel_world_1 = max((((2f * _e251) * _e253.x) / _e256), 0.00001f);
            let _e261 = light_size_1;
            let _e262 = d_r;
            let _e263 = info;
            let _e267 = d_r;
            let _e271 = texel_world_1;
            search = clamp((((_e261 * (_e262 - _e263.y)) / max(_e267, 0.01f)) / _e271), 2f, 10f);
            loop {
                let _e283 = i_4;
                if !((_e283 < 12i)) {
                    break;
                }
                {
                    let _e290 = i_4;
                    let _e292 = rot_4;
                    let _e293 = vogelDisk(_e290, 12i, _e292);
                    let _e294 = search;
                    let _e296 = texel_1;
                    o_2 = ((_e293 * _e294) * _e296);
                    let _e299 = suv_2;
                    let _e300 = o_2;
                    let _e302 = rect;
                    let _e304 = texel_1;
                    let _e306 = rect;
                    let _e308 = rect;
                    let _e311 = texel_1;
                    cuv = clamp((_e299 + _e300), (_e302.xy + _e304), ((_e306.xy + _e308.zw) - _e311));
                    let _e315 = cuv;
                    let _e317 = textureSampleLevel(zengy_u_local_shadow_raw_image, zengy_u_local_shadow_raw_sampler, _e315, 0f);
                    r_3 = _e317.x;
                    let _e320 = r_3;
                    let _e321 = proj_1;
                    let _e323 = bias_2;
                    if (_e320 < (_e321.z - _e323)) {
                        {
                            let _e326 = blocker_sum_1;
                            let _e327 = r_3;
                            let _e328 = info;
                            let _e330 = info;
                            let _e332 = localLinearDepth(_e327, _e328.y, _e330.z);
                            blocker_sum_1 = (_e326 + _e332);
                            let _e334 = blocker_n_1;
                            blocker_n_1 = (_e334 + 1f);
                        }
                    }
                }
                continuing {
                    let _e287 = i_4;
                    i_4 = (_e287 + 1i);
                }
            }
            let _e337 = blocker_n_1;
            if (_e337 < 0.5f) {
                return 1f;
            }
            let _e341 = blocker_sum_1;
            let _e342 = blocker_n_1;
            d_b = (_e341 / _e342);
            let _e345 = d_r;
            let _e346 = d_b;
            let _e348 = light_size_1;
            let _e350 = d_b;
            let _e354 = texel_world_1;
            radius_texels_1 = clamp(((((_e345 - _e346) * _e348) / max(_e350, 0.01f)) / _e354), 1f, 12f);
            taps_1 = 16i;
        }
    }
    loop {
        let _e364 = i_5;
        let _e365 = taps_1;
        if !((_e364 < _e365)) {
            break;
        }
        {
            let _e371 = i_5;
            let _e372 = taps_1;
            let _e373 = rot_4;
            let _e374 = vogelDisk(_e371, _e372, _e373);
            let _e375 = radius_texels_1;
            let _e377 = texel_1;
            o_3 = ((_e374 * _e375) * _e377);
            let _e380 = suv_2;
            let _e381 = o_3;
            let _e383 = rect;
            let _e385 = texel_1;
            let _e387 = rect;
            let _e389 = rect;
            let _e392 = texel_1;
            cuv_1 = clamp((_e380 + _e381), (_e383.xy + _e385), ((_e387.xy + _e389.zw) - _e392));
            let _e396 = s;
            let _e397 = cuv_1;
            let _e398 = proj_1;
            let _e400 = bias_2;
            let _e404 = vec3<f32>(_e397.x, _e397.y, (_e398.z - _e400));
            let _e407 = textureSampleCompareLevel(zengy_u_local_shadow_tex_image, zengy_u_local_shadow_tex_sampler, _e404.xy, _e404.z);
            s = (_e396 + _e407);
        }
        continuing {
            let _e368 = i_5;
            i_5 = (_e368 + 1i);
        }
    }
    let _e409 = s;
    let _e410 = taps_1;
    return (_e409 / f32(_e410));
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
    var local_3: i32;
    var local_4: i32;
    var local_5: i32;
    var slope_1: f32;
    var bias_3: f32;

    base_tile_1 = base_tile;
    light_pos_2 = light_pos_1;
    N_11 = N_10;
    L_7 = L_6;
    rot_6 = rot_5;
    light_size_3 = light_size_2;
    let _e119 = base_tile_1;
    let _e122 = base_tile_1;
    if ((_e119 < 0i) || (_e122 > 10i)) {
        return 1f;
    }
    let _e127 = v_world_pos_1;
    let _e128 = light_pos_2;
    d_2 = (_e127 - _e128);
    let _e131 = d_2;
    ad = abs(_e131);
    let _e136 = ad;
    let _e138 = ad;
    let _e141 = ad;
    let _e143 = ad;
    if ((_e136.x >= _e138.y) && (_e141.x >= _e143.z)) {
        {
            let _e147 = d_2;
            if (_e147.x > 0f) {
                local_3 = 0i;
            } else {
                local_3 = 1i;
            }
            let _e154 = local_3;
            face = _e154;
        }
    } else {
        let _e155 = ad;
        let _e157 = ad;
        let _e160 = ad;
        let _e162 = ad;
        if ((_e155.y >= _e157.x) && (_e160.y >= _e162.z)) {
            {
                let _e166 = d_2;
                if (_e166.y > 0f) {
                    local_4 = 2i;
                } else {
                    local_4 = 3i;
                }
                let _e173 = local_4;
                face = _e173;
            }
        } else {
            {
                let _e174 = d_2;
                if (_e174.z > 0f) {
                    local_5 = 4i;
                } else {
                    local_5 = 5i;
                }
                let _e181 = local_5;
                face = _e181;
            }
        }
    }
    let _e183 = N_11;
    let _e184 = L_7;
    slope_1 = (1f - max(dot(_e183, _e184), 0f));
    let _e191 = slope_1;
    bias_3 = (0.0015f + (_e191 * 0.0045f));
    let _e196 = base_tile_1;
    let _e197 = face;
    let _e199 = v_world_pos_1;
    let _e200 = bias_3;
    let _e201 = rot_6;
    let _e202 = light_size_3;
    let _e203 = sampleLocalTile((_e196 + _e197), _e199, _e200, _e201, _e202);
    return _e203;
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
    let _e125 = N_13;
    let _e126 = L_9;
    NdotL = max(dot(_e125, _e126), 0f);
    let _e131 = NdotL;
    if (_e131 <= 0f) {
        return vec3(0f);
    }
    let _e136 = V_5;
    let _e137 = L_9;
    half_vector = (_e136 + _e137);
    let _e140 = half_vector;
    let _e141 = half_vector;
    let _e142 = half_vector;
    H_2 = (_e140 * inverseSqrt(max(dot(_e141, _e142), 0.000000000001f)));
    let _e149 = H_2;
    let _e150 = V_5;
    let _e154 = F0_5;
    let _e155 = fresnelSchlick(max(dot(_e149, _e150), 0f), _e154);
    F = _e155;
    let _e159 = F;
    let _e162 = metallic_1;
    kD = ((vec3(1f) - _e159) * (1f - _e162));
    let _e166 = spec_scale_1;
    if (_e166 <= 0f) {
        let _e169 = kD;
        let _e170 = albedo_1;
        let _e175 = radiance_1;
        let _e177 = NdotL;
        return ((((_e169 * _e170) / vec3(3.1415927f)) * _e175) * _e177);
    }
    let _e179 = N_13;
    let _e180 = H_2;
    let _e181 = roughness_9;
    let _e182 = distributionGGX(_e179, _e180, _e181);
    NDF = _e182;
    let _e184 = N_13;
    let _e185 = V_5;
    let _e186 = L_9;
    let _e187 = roughness_9;
    let _e188 = geometrySmith(_e184, _e185, _e186, _e187);
    G = _e188;
    let _e190 = NDF;
    let _e191 = G;
    let _e193 = F;
    let _e196 = N_13;
    let _e197 = V_5;
    let _e202 = NdotL;
    spec = (((_e190 * _e191) * _e193) / vec3(max(((4f * max(dot(_e196, _e197), 0f)) * _e202), 0.0001f)));
    let _e209 = kD;
    let _e210 = albedo_1;
    let _e215 = spec;
    let _e216 = spec_scale_1;
    let _e219 = radiance_1;
    let _e221 = NdotL;
    return (((((_e209 * _e210) / vec3(3.1415927f)) + (_e215 * _e216)) * _e219) * _e221);
}

fn giSector(d_3: vec3<f32>) -> i32 {
    var d_4: vec3<f32>;
    var a_1: vec3<f32>;
    var local_6: i32;
    var local_7: i32;
    var local_8: i32;

    d_4 = d_3;
    let _e109 = d_4;
    a_1 = abs(_e109);
    let _e112 = a_1;
    let _e114 = a_1;
    let _e117 = a_1;
    let _e119 = a_1;
    if ((_e112.x >= _e114.y) && (_e117.x >= _e119.z)) {
        let _e123 = d_4;
        if (_e123.x >= 0f) {
            local_6 = 0i;
        } else {
            local_6 = 1i;
        }
        let _e130 = local_6;
        return _e130;
    }
    let _e131 = a_1;
    let _e133 = a_1;
    if (_e131.y >= _e133.z) {
        let _e136 = d_4;
        if (_e136.y >= 0f) {
            local_7 = 2i;
        } else {
            local_7 = 3i;
        }
        let _e143 = local_7;
        return _e143;
    }
    let _e144 = d_4;
    if (_e144.z >= 0f) {
        local_8 = 4i;
    } else {
        local_8 = 5i;
    }
    let _e151 = local_8;
    return _e151;
}

fn sampleDynamicGi(p_2: vec3<f32>, n_2: vec3<f32>) -> vec4<f32> {
    var p_3: vec3<f32>;
    var n_3: vec3<f32>;
    var nlen2_: f32;
    var n2_: vec3<f32>;
    var q: vec3<f32>;
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
    var local_9: i32;
    var local_10: i32;
    var local_11: i32;
    var radiance_2: vec3<f32>;

    p_3 = p_2;
    n_3 = n_2;
    let _e111 = global.gi_origin_enabled;
    let _e115 = global.gi_origin_enabled;
    let _e116 = zy_isnan_3(_e115);
    let _e119 = global.gi_origin_enabled;
    let _e120 = zy_isinf_3(_e119);
    if (((_e111.w <= 0f) || any(_e116)) || any(_e120)) {
        return vec4(0f);
    }
    let _e125 = global.gi_spacing;
    let _e129 = global.gi_spacing;
    let _e131 = global_4.layer_info;
    let _e133 = layersOverlap(_e129.w, _e131.x);
    if ((_e125.w > 0f) && !(_e133)) {
        return vec4(0f);
    }
    let _e138 = p_3;
    let _e139 = zy_isnan_2(_e138);
    let _e141 = p_3;
    let _e142 = zy_isinf_2(_e141);
    let _e145 = n_3;
    let _e146 = zy_isnan_2(_e145);
    let _e149 = n_3;
    let _e150 = zy_isinf_2(_e149);
    let _e153 = global.gi_spacing;
    let _e160 = global.gi_spacing;
    let _e162 = zy_isnan_2(_e160.xyz);
    let _e165 = global.gi_spacing;
    let _e167 = zy_isinf_2(_e165.xyz);
    if ((((((any(_e139) || any(_e142)) || any(_e146)) || any(_e150)) || any((_e153.xyz <= vec3(0.01f)))) || any(_e162)) || any(_e167)) {
        return vec4(0f);
    }
    let _e172 = n_3;
    let _e173 = n_3;
    nlen2_ = dot(_e172, _e173);
    let _e176 = nlen2_;
    if (_e176 <= 0.000000000001f) {
        return vec4(0f);
    }
    let _e181 = n_3;
    let _e182 = n_3;
    let _e184 = nlen2_;
    n2_ = ((_e181 * _e182) / vec3(_e184));
    let _e188 = p_3;
    let _e189 = global.gi_origin_enabled;
    let _e192 = global.gi_spacing;
    q = ((_e188 - _e189.xyz) / _e192.xyz);
    let _e196 = q;
    let _e202 = q;
    if (any((_e196 < vec3(-0.05f))) || any((_e202 > vec3(3.05f)))) {
        return vec4(0f);
    }
    let _e210 = q;
    q = clamp(_e210, vec3(0f), vec3(3f));
    let _e216 = q;
    base = min(vec3<i32>(floor(_e216)), vec3(2i));
    let _e223 = q;
    let _e224 = base;
    f = (_e223 - vec3<f32>(_e224));
    loop {
        let _e235 = i_6;
        if !((_e235 < 8i)) {
            break;
        }
        {
            let _e242 = i_6;
            let _e245 = i_6;
            let _e251 = i_6;
            o_4 = vec3<i32>((_e242 & 1i), ((_e245 >> 1u) & 1i), ((_e251 >> 2u) & 1i));
            let _e259 = base;
            let _e260 = o_4;
            c = (_e259 + _e260);
            let _e263 = c;
            let _e266 = c;
            let _e271 = c;
            idx_3 = ((_e263.x + (4i * _e266.y)) + (16i * _e271.z));
            let _e277 = f;
            let _e280 = f;
            let _e281 = o_4;
            w3_ = mix((vec3(1f) - _e277), _e280, vec3<f32>(_e281));
            let _e285 = w3_;
            let _e287 = w3_;
            let _e290 = w3_;
            let _e293 = idx_3;
            let _e295 = global.c_gi[_e293];
            w = (((_e285.x * _e287.y) * _e290.z) * _e295.offset_validity.w);
            let _e300 = w;
            if (_e300 <= 0.00001f) {
                continue;
            }
            let _e303 = global.gi_origin_enabled;
            let _e305 = c;
            let _e307 = global.gi_spacing;
            let _e311 = idx_3;
            let _e313 = global.c_gi[_e311];
            pos = ((_e303.xyz + (vec3<f32>(_e305) * _e307.xyz)) + _e313.offset_validity.xyz);
            let _e318 = p_3;
            let _e319 = pos;
            delta = (_e318 - _e319);
            let _e322 = delta;
            dist = length(_e322);
            let _e325 = delta;
            let _e326 = giSector(_e325);
            s_1 = _e326;
            let _e328 = s_1;
            let _e329 = idx_3;
            let _e333 = global.c_gi[_e329].moments[_e328];
            moment = _e333;
            let _e335 = s_1;
            let _e336 = idx_3;
            let _e340 = global.c_gi[_e336].lobes[_e335];
            mean = _e340.w;
            let _e343 = moment;
            let _e345 = mean;
            let _e346 = mean;
            variance = max((_e343.x - (_e345 * _e346)), 0.0025f);
            let _e352 = dist;
            let _e353 = mean;
            excess = max(((_e352 - _e353) - 0.05f), 0f);
            let _e360 = variance;
            let _e361 = variance;
            let _e362 = excess;
            let _e363 = excess;
            vis = (_e360 / (_e361 + (_e362 * _e363)));
            let _e368 = moment;
            if (_e368.y <= 0f) {
                continue;
            }
            let _e372 = vis;
            let _e373 = vis;
            let _e375 = vis;
            vis = ((_e372 * _e373) * _e375);
            let _e377 = n_3;
            if (_e377.x >= 0f) {
                local_9 = 0i;
            } else {
                local_9 = 1i;
            }
            let _e384 = local_9;
            let _e385 = idx_3;
            let _e389 = global.c_gi[_e385].lobes[_e384];
            let _e391 = n2_;
            let _e394 = n_3;
            if (_e394.y >= 0f) {
                local_10 = 2i;
            } else {
                local_10 = 3i;
            }
            let _e401 = local_10;
            let _e402 = idx_3;
            let _e406 = global.c_gi[_e402].lobes[_e401];
            let _e408 = n2_;
            let _e412 = n_3;
            if (_e412.z >= 0f) {
                local_11 = 4i;
            } else {
                local_11 = 5i;
            }
            let _e419 = local_11;
            let _e420 = idx_3;
            let _e424 = global.c_gi[_e420].lobes[_e419];
            let _e426 = n2_;
            radiance_2 = (((_e389.xyz * _e391.x) + (_e406.xyz * _e408.y)) + (_e424.xyz * _e426.z));
            let _e431 = sum_rgb;
            let _e432 = radiance_2;
            let _e433 = w;
            let _e435 = vis;
            sum_rgb = (_e431 + ((_e432 * _e433) * _e435));
            let _e438 = sum_w;
            let _e439 = w;
            sum_w = (_e438 + _e439);
        }
        continuing {
            let _e239 = i_6;
            i_6 = (_e239 + 1i);
        }
    }
    let _e441 = sum_rgb;
    let _e442 = sum_w;
    let _e446 = (_e441 / vec3(max(_e442, 0.00001f)));
    let _e447 = sum_w;
    return vec4<f32>(_e446.x, _e446.y, _e446.z, clamp(_e447, 0f, 1f));
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
    var local_12: f32;
    var facing: f32;

    rl_1 = rl;
    N_15 = N_14;
    V_7 = V_6;
    F0_7 = F0_6;
    albedo_3 = albedo_2;
    metallic_3 = metallic_2;
    roughness_11 = roughness_10;
    let _e121 = v_world_pos_1;
    let _e122 = rl_1;
    to_p = (_e121 - _e122.pos_range.xyz);
    let _e127 = to_p;
    let _e128 = rl_1;
    plane_d = dot(_e127, _e128.dir_two.xyz);
    let _e133 = plane_d;
    let _e136 = rl_1;
    if ((_e133 <= 0f) && (_e136.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e144 = v_world_pos_1;
    let _e145 = rl_1;
    let _e148 = plane_d;
    p_on_plane = (_e144 - (_e145.dir_two.xyz * _e148));
    let _e152 = p_on_plane;
    let _e153 = rl_1;
    d_plane = (_e152 - _e153.pos_range.xyz);
    let _e158 = d_plane;
    let _e159 = rl_1;
    let _e163 = rl_1;
    let _e167 = rl_1;
    cx = clamp(dot(_e158, _e159.right_hx.xyz), -(_e163.right_hx.w), _e167.right_hx.w);
    let _e172 = d_plane;
    let _e173 = rl_1;
    let _e177 = rl_1;
    let _e181 = rl_1;
    cy = clamp(dot(_e172, _e173.up_hy.xyz), -(_e177.up_hy.w), _e181.up_hy.w);
    let _e186 = rl_1;
    let _e189 = rl_1;
    let _e192 = cx;
    let _e195 = rl_1;
    let _e198 = cy;
    closest = ((_e186.pos_range.xyz + (_e189.right_hx.xyz * _e192)) + (_e195.up_hy.xyz * _e198));
    let _e202 = closest;
    let _e203 = v_world_pos_1;
    to_l = (_e202 - _e203);
    let _e206 = to_l;
    dist_1 = length(_e206);
    let _e209 = rl_1;
    range = max(_e209.pos_range.w, 0.001f);
    let _e215 = dist_1;
    let _e216 = range;
    if (_e215 >= _e216) {
        return vec3(0f);
    }
    let _e220 = to_l;
    let _e221 = dist_1;
    L_10 = (_e220 / vec3(max(_e221, 0.0001f)));
    let _e228 = dist_1;
    let _e229 = range;
    att = clamp((1f - pow((_e228 / _e229), 4f)), 0f, 1f);
    let _e238 = att;
    let _e239 = att;
    let _e241 = dist_1;
    let _e242 = dist_1;
    att = ((_e238 * _e239) / ((_e241 * _e242) + 1f));
    let _e247 = rl_1;
    if (_e247.dir_two.w > 0.5f) {
        let _e252 = L_10;
        let _e254 = rl_1;
        local_12 = abs(dot(-(_e252), _e254.dir_two.xyz));
    } else {
        let _e259 = L_10;
        let _e261 = rl_1;
        local_12 = max(dot(-(_e259), _e261.dir_two.xyz), 0f);
    }
    let _e268 = local_12;
    facing = _e268;
    let _e270 = N_15;
    let _e271 = V_7;
    let _e272 = F0_7;
    let _e273 = albedo_3;
    let _e274 = metallic_3;
    let _e275 = roughness_11;
    let _e276 = L_10;
    let _e277 = rl_1;
    let _e280 = att;
    let _e282 = facing;
    let _e285 = evalLight(_e270, _e271, _e272, _e273, _e274, _e275, _e276, ((_e277.col_pad.xyz * _e280) * _e282), 1f);
    return _e285;
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
    var local_13: f32;
    var sx: f32;
    var local_14: f32;
    var sy: f32;
    var sample_pos: vec3<f32>;
    var delta_1: vec3<f32>;
    var dist_2: f32;
    var L_11: vec3<f32>;
    var r_4: f32;
    var att_1: f32;
    var facing_1: f32;
    var local_15: f32;

    rl_3 = rl_2;
    N_17 = N_16;
    V_9 = V_8;
    F0_9 = F0_8;
    albedo_5 = albedo_4;
    metallic_5 = metallic_4;
    roughness_13 = roughness_12;
    let _e121 = v_world_pos_1;
    let _e122 = rl_3;
    to_p_1 = (_e121 - _e122.pos_range.xyz);
    let _e127 = to_p_1;
    let _e128 = rl_3;
    plane_d_1 = dot(_e127, _e128.dir_two.xyz);
    let _e133 = plane_d_1;
    let _e136 = rl_3;
    if ((_e133 <= 0f) && (_e136.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e149 = rl_3;
    range_1 = max(_e149.pos_range.w, 0.001f);
    loop {
        let _e157 = i_7;
        if !((_e157 < 4i)) {
            break;
        }
        {
            let _e164 = i_7;
            if ((_e164 & 1i) == 0i) {
                let _e169 = node;
                local_13 = -(_e169);
            } else {
                let _e171 = node;
                local_13 = _e171;
            }
            let _e173 = local_13;
            sx = _e173;
            let _e175 = i_7;
            if ((_e175 & 2i) == 0i) {
                let _e180 = node;
                local_14 = -(_e180);
            } else {
                let _e182 = node;
                local_14 = _e182;
            }
            let _e184 = local_14;
            sy = _e184;
            let _e186 = rl_3;
            let _e189 = rl_3;
            let _e192 = sx;
            let _e193 = rl_3;
            let _e199 = rl_3;
            let _e202 = sy;
            let _e203 = rl_3;
            sample_pos = ((_e186.pos_range.xyz + (_e189.right_hx.xyz * (_e192 * _e193.right_hx.w))) + (_e199.up_hy.xyz * (_e202 * _e203.up_hy.w)));
            let _e210 = sample_pos;
            let _e211 = v_world_pos_1;
            delta_1 = (_e210 - _e211);
            let _e214 = delta_1;
            dist_2 = length(_e214);
            let _e217 = dist_2;
            let _e218 = range_1;
            let _e220 = dist_2;
            if ((_e217 >= _e218) || (_e220 < 0.0001f)) {
                continue;
            }
            let _e224 = delta_1;
            let _e225 = dist_2;
            L_11 = (_e224 / vec3(_e225));
            let _e229 = dist_2;
            let _e230 = range_1;
            r_4 = (_e229 / _e230);
            let _e234 = r_4;
            let _e235 = r_4;
            let _e237 = r_4;
            let _e239 = r_4;
            att_1 = (1f - (((_e234 * _e235) * _e237) * _e239));
            let _e243 = att_1;
            let _e244 = att_1;
            let _e246 = dist_2;
            let _e247 = dist_2;
            att_1 = ((_e243 * _e244) / ((_e246 * _e247) + 1f));
            let _e252 = L_11;
            let _e254 = rl_3;
            facing_1 = dot(-(_e252), _e254.dir_two.xyz);
            let _e259 = rl_3;
            if (_e259.dir_two.w > 0.5f) {
                let _e264 = facing_1;
                local_15 = abs(_e264);
            } else {
                let _e266 = facing_1;
                local_15 = max(_e266, 0f);
            }
            let _e270 = local_15;
            facing_1 = _e270;
            let _e271 = sum_rgb_1;
            let _e272 = N_17;
            let _e273 = V_9;
            let _e274 = F0_9;
            let _e275 = albedo_5;
            let _e276 = metallic_5;
            let _e277 = roughness_13;
            let _e278 = L_11;
            let _e279 = rl_3;
            let _e282 = att_1;
            let _e283 = facing_1;
            let _e289 = evalLight(_e272, _e273, _e274, _e275, _e276, _e277, _e278, (_e279.col_pad.xyz * ((_e282 * _e283) * 0.25f)), 1f);
            sum_rgb_1 = (_e271 + _e289);
        }
        continuing {
            let _e161 = i_7;
            i_7 = (_e161 + 1i);
        }
    }
    let _e291 = sum_rgb_1;
    return _e291;
}

fn ltcLookup(uv_4: vec2<f32>, amplitude: bool) -> vec4<f32> {
    var uv_5: vec2<f32>;
    var amplitude_1: bool;
    var p_4: vec2<f32>;
    var i_8: vec2<i32>;
    var f_1: vec2<f32>;
    var local_16: i32;
    var base_1: vec2<i32>;
    var a_2: vec4<f32>;
    var b_1: vec4<f32>;
    var c_1: vec4<f32>;
    var d_5: vec4<f32>;

    uv_5 = uv_4;
    amplitude_1 = amplitude;
    let _e111 = uv_5;
    p_4 = (clamp(_e111, vec2(0f), vec2(1f)) * 15f);
    let _e122 = p_4;
    i_8 = min(vec2<i32>(floor(_e122)), vec2(14i));
    let _e129 = p_4;
    let _e130 = i_8;
    f_1 = (_e129 - vec2<f32>(_e130));
    let _e134 = i_8;
    let _e136 = amplitude_1;
    if _e136 {
        local_16 = 16i;
    } else {
        local_16 = 0i;
    }
    let _e140 = local_16;
    base_1 = (_e134 + vec2<i32>(0i, _e140));
    let _e144 = base_1;
    let _e146 = textureLoad(zengy_u_ltc_image, _e144, 0i);
    a_2 = _e146;
    let _e148 = base_1;
    let _e154 = textureLoad(zengy_u_ltc_image, (_e148 + vec2<i32>(1i, 0i)), 0i);
    b_1 = _e154;
    let _e156 = base_1;
    let _e162 = textureLoad(zengy_u_ltc_image, (_e156 + vec2<i32>(0i, 1i)), 0i);
    c_1 = _e162;
    let _e164 = base_1;
    let _e170 = textureLoad(zengy_u_ltc_image, (_e164 + vec2<i32>(1i, 1i)), 0i);
    d_5 = _e170;
    let _e172 = a_2;
    let _e173 = b_1;
    let _e174 = f_1;
    let _e178 = c_1;
    let _e179 = d_5;
    let _e180 = f_1;
    let _e184 = f_1;
    return mix(mix(_e172, _e173, vec4(_e174.x)), mix(_e178, _e179, vec4(_e180.x)), vec4(_e184.y));
}

fn ltcPolygon(corners: array<vec3<f32>, 4>, invM: mat3x3<f32>) -> f32 {
    var corners_1: array<vec3<f32>, 4>;
    var invM_1: mat3x3<f32>;
    var v_17: array<vec3<f32>, 4>;
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
        let _e114 = i_9;
        if !((_e114 < 4i)) {
            break;
        }
        let _e121 = i_9;
        let _e123 = invM_1;
        let _e124 = i_9;
        let _e126 = corners_1[_e124];
        v_17[_e121] = (_e123 * _e126);
        continuing {
            let _e118 = i_9;
            i_9 = (_e118 + 1i);
        }
    }
    loop {
        let _e133 = i_10;
        if !((_e133 < 4i)) {
            break;
        }
        {
            let _e140 = i_10;
            let _e142 = v_17[_e140];
            a_3 = _e142;
            let _e144 = i_10;
            let _e150 = v_17[((_e144 + 1i) % 4i)];
            b_2 = _e150;
            let _e152 = a_3;
            ia = (_e152.z > 0f);
            let _e157 = b_2;
            ib = (_e157.z > 0f);
            let _e162 = ia;
            if _e162 {
                let _e163 = count_3;
                count_3 = (_e163 + 1i);
                let _e167 = a_3;
                clipped[_e163] = _e167;
            }
            let _e168 = ia;
            let _e169 = ib;
            if (_e168 != _e169) {
                let _e171 = count_3;
                count_3 = (_e171 + 1i);
                let _e175 = a_3;
                let _e176 = b_2;
                let _e177 = a_3;
                let _e179 = a_3;
                let _e181 = b_2;
                clipped[_e171] = mix(_e175, _e176, vec3(clamp((_e177.z / (_e179.z - _e181.z)), 0f, 1f)));
            }
        }
        continuing {
            let _e137 = i_10;
            i_10 = (_e137 + 1i);
        }
    }
    let _e190 = count_3;
    if (_e190 < 3i) {
        return 0f;
    }
    loop {
        let _e198 = i_11;
        let _e199 = count_3;
        if !((_e198 < _e199)) {
            break;
        }
        {
            let _e205 = i_11;
            let _e207 = clipped[_e205];
            a_4 = _e207;
            let _e209 = i_11;
            let _e212 = count_3;
            let _e215 = clipped[((_e209 + 1i) % _e212)];
            b_3 = _e215;
            let _e217 = a_4;
            la = length(_e217);
            let _e220 = b_3;
            lb = length(_e220);
            let _e223 = la;
            let _e226 = lb;
            if ((_e223 < 0.000001f) || (_e226 < 0.000001f)) {
                continue;
            }
            let _e230 = a_4;
            let _e231 = la;
            a_4 = (_e230 / vec3(_e231));
            let _e234 = b_3;
            let _e235 = lb;
            b_3 = (_e234 / vec3(_e235));
            let _e238 = a_4;
            let _e239 = b_3;
            crossAB = cross(_e238, _e239);
            let _e242 = crossAB;
            s_2 = length(_e242);
            let _e245 = s_2;
            if (_e245 > 0.000001f) {
                let _e248 = integral;
                let _e249 = crossAB;
                let _e251 = s_2;
                let _e252 = a_4;
                let _e253 = b_3;
                let _e261 = s_2;
                integral = (_e248 + ((_e249.z * atan2(_e251, clamp(dot(_e252, _e253), -1f, 1f))) / _e261));
            }
        }
        continuing {
            let _e202 = i_11;
            i_11 = (_e202 + 1i);
        }
    }
    let _e264 = integral;
    return clamp((abs(_e264) / 6.2831855f), 0f, 1f);
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
    var local_17: vec3<f32>;
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
    let _e121 = N_19;
    let _e122 = V_11;
    nv = max(dot(_e121, _e122), 0f);
    let _e127 = roughness_15;
    let _e130 = nv;
    if ((_e127 < 0.18f) || (_e130 < 0.1f)) {
        let _e134 = rl_5;
        let _e135 = N_19;
        let _e136 = V_11;
        let _e137 = F0_11;
        let _e138 = albedo_7;
        let _e139 = metallic_7;
        let _e140 = roughness_15;
        let _e141 = evalRectLightQuadrature(_e134, _e135, _e136, _e137, _e138, _e139, _e140);
        return _e141;
    }
    let _e142 = roughness_15;
    let _e148 = nv;
    uv_6 = vec2<f32>(((_e142 - 0.18f) / 0.82f), ((1f - _e148) / 0.9f));
    let _e154 = uv_6;
    let _e156 = ltcLookup(_e154, false);
    fit = _e156;
    let _e158 = uv_6;
    let _e160 = ltcLookup(_e158, true);
    amp = _e160;
    let _e162 = fit;
    if (_e162.w > 0.45f) {
        let _e166 = rl_5;
        let _e167 = N_19;
        let _e168 = V_11;
        let _e169 = F0_11;
        let _e170 = albedo_7;
        let _e171 = metallic_7;
        let _e172 = roughness_15;
        let _e173 = evalRectLightQuadrature(_e166, _e167, _e168, _e169, _e170, _e171, _e172);
        return _e173;
    }
    let _e174 = rl_5;
    let _e177 = v_world_pos_1;
    delta_2 = (_e174.pos_range.xyz - _e177);
    let _e180 = delta_2;
    distance = length(_e180);
    let _e183 = rl_5;
    range_2 = max(_e183.pos_range.w, 0.001f);
    let _e189 = delta_2;
    let _e191 = rl_5;
    let _e197 = rl_5;
    if ((dot(-(_e189), _e191.dir_two.xyz) <= 0f) && (_e197.dir_two.w < 0.5f)) {
        return vec3(0f);
    }
    let _e207 = rl_5;
    let _e211 = rl_5;
    area = ((4f * _e207.right_hx.w) * _e211.up_hy.w);
    let _e216 = area;
    let _e219 = distance;
    if ((_e216 <= 0.00001f) || (_e219 < 0.0001f)) {
        let _e223 = rl_5;
        let _e224 = N_19;
        let _e225 = V_11;
        let _e226 = F0_11;
        let _e227 = albedo_7;
        let _e228 = metallic_7;
        let _e229 = roughness_15;
        let _e230 = evalRectLightQuadrature(_e223, _e224, _e225, _e226, _e227, _e228, _e229);
        return _e230;
    }
    let _e231 = V_11;
    let _e232 = N_19;
    let _e233 = nv;
    T_1 = (_e231 - (_e232 * _e233));
    let _e237 = T_1;
    let _e238 = T_1;
    if (dot(_e237, _e238) < 0.000001f) {
        let _e242 = N_19;
        if (abs(_e242.y) < 0.99f) {
            local_17 = vec3<f32>(0f, 1f, 0f);
        } else {
            local_17 = vec3<f32>(1f, 0f, 0f);
        }
        let _e262 = local_17;
        let _e263 = N_19;
        T_1 = cross(_e262, _e263);
    }
    let _e265 = T_1;
    T_1 = normalize(_e265);
    let _e267 = N_19;
    let _e268 = T_1;
    B_1 = cross(_e267, _e268);
    let _e271 = T_1;
    let _e272 = B_1;
    let _e273 = N_19;
    basis = transpose(mat3x3<f32>(vec3<f32>(_e271.x, _e271.y, _e271.z), vec3<f32>(_e272.x, _e272.y, _e272.z), vec3<f32>(_e273.x, _e273.y, _e273.z)));
    let _e289 = rl_5;
    let _e292 = rl_5;
    right = (_e289.right_hx.xyz * _e292.right_hx.w);
    let _e297 = rl_5;
    let _e300 = rl_5;
    up = (_e297.up_hy.xyz * _e300.up_hy.w);
    let _e305 = basis;
    let _e306 = delta_2;
    let _e307 = right;
    let _e309 = up;
    let _e312 = basis;
    let _e313 = delta_2;
    let _e314 = right;
    let _e316 = up;
    let _e319 = basis;
    let _e320 = delta_2;
    let _e321 = right;
    let _e323 = up;
    let _e326 = basis;
    let _e327 = delta_2;
    let _e328 = right;
    let _e330 = up;
    corners_2 = array<vec3<f32>, 4>((_e305 * ((_e306 - _e307) - _e309)), (_e312 * ((_e313 + _e314) - _e316)), (_e319 * ((_e320 + _e321) + _e323)), (_e326 * ((_e327 - _e328) + _e330)));
    let _e335 = fit;
    let _e341 = vec3<f32>(_e335.x, 0f, 0f);
    let _e343 = fit;
    let _e348 = vec3<f32>(0f, _e343.y, 0f);
    let _e349 = fit;
    let _e355 = vec3<f32>(_e349.z, 0f, 1f);
    invM_2 = mat3x3<f32>(vec3<f32>(_e341.x, _e341.y, _e341.z), vec3<f32>(_e348.x, _e348.y, _e348.z), vec3<f32>(_e355.x, _e355.y, _e355.z));
    let _e370 = corners_2;
    let _e378 = ltcPolygon(_e370, mat3x3<f32>(vec3<f32>(1f, 0f, 0f), vec3<f32>(0f, 1f, 0f), vec3<f32>(0f, 0f, 1f)));
    diffuse = _e378;
    let _e380 = corners_2;
    let _e381 = invM_2;
    let _e382 = ltcPolygon(_e380, _e381);
    specular = _e382;
    let _e384 = F0_11;
    let _e386 = F0_11;
    let _e390 = nv;
    fresnel = (_e384 + ((vec3(1f) - _e386) * pow((1f - _e390), 5f)));
    let _e398 = fresnel;
    let _e402 = metallic_7;
    kd = ((vec3(1f) - _e398) * (1f - _e402));
    let _e406 = F0_11;
    let _e407 = amp;
    let _e411 = F0_11;
    let _e414 = amp;
    amplitude_2 = ((_e406 * _e407.x) + ((vec3(1f) - _e411) * _e414.y));
    let _e419 = distance;
    let _e420 = right;
    let _e423 = up;
    nearDistance = max(((_e419 - length(_e420)) - length(_e423)), 0f);
    let _e429 = nearDistance;
    let _e430 = range_2;
    r_5 = clamp((_e429 / _e430), 0f, 1f);
    let _e437 = r_5;
    let _e438 = r_5;
    let _e440 = r_5;
    let _e442 = r_5;
    window = (1f - (((_e437 * _e438) * _e440) * _e442));
    let _e446 = kd;
    let _e447 = albedo_7;
    let _e449 = diffuse;
    let _e451 = amplitude_2;
    let _e452 = specular;
    let _e455 = rl_5;
    let _e459 = window;
    let _e460 = window;
    let _e462 = area;
    return (((((_e446 * _e447) * _e449) + (_e451 * _e452)) * _e455.col_pad.xyz) * ((_e459 * _e460) / _e462));
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
    let _e121 = global_4.layer_info;
    if (_e121.w > 1.5f) {
        let _e125 = rl_7;
        let _e126 = N_21;
        let _e127 = V_13;
        let _e128 = F0_13;
        let _e129 = albedo_9;
        let _e130 = metallic_9;
        let _e131 = roughness_17;
        let _e132 = evalRectLightLtc(_e125, _e126, _e127, _e128, _e129, _e130, _e131);
        return _e132;
    }
    let _e133 = global_4.layer_info;
    if (_e133.w > 0.5f) {
        let _e137 = rl_7;
        let _e138 = N_21;
        let _e139 = V_13;
        let _e140 = F0_13;
        let _e141 = albedo_9;
        let _e142 = metallic_9;
        let _e143 = roughness_17;
        let _e144 = evalRectLightQuadrature(_e137, _e138, _e139, _e140, _e141, _e142, _e143);
        return _e144;
    }
    let _e145 = rl_7;
    let _e146 = N_21;
    let _e147 = V_13;
    let _e148 = F0_13;
    let _e149 = albedo_9;
    let _e150 = metallic_9;
    let _e151 = roughness_17;
    let _e152 = evalRectLightLegacy(_e145, _e146, _e147, _e148, _e149, _e150, _e151);
    return _e152;
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
    var local_18: f32;
    var ssao: f32;
    var local_19: f32;
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
    var local_20: f32;
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
    var local_21: f32;
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

    let _e107 = v_uv_1;
    let _e108 = textureSample(zengy_u_base_color_tex_image, zengy_u_base_color_tex_sampler, _e107);
    tex_albedo = _e108;
    let _e110 = tex_albedo;
    let _e112 = global_4.base_color;
    let _e114 = (_e110.xyz * _e112.xyz);
    let _e115 = tex_albedo;
    let _e117 = global_4.base_color;
    albedo_a = vec4<f32>(_e114.x, _e114.y, _e114.z, (_e115.w * _e117.w));
    let _e125 = global_4.cluster_factors;
    let _e129 = albedo_a;
    let _e131 = global_4.cluster_factors;
    if ((_e125.w >= 0f) && (_e129.w < _e131.w)) {
        {
            discard;
        }
    }
    let _e135 = global_4.emissive_weight;
    let _e137 = v_uv_1;
    let _e138 = textureSample(zengy_u_emissive_tex_image, zengy_u_emissive_tex_sampler, _e137);
    emissive_rgb = (_e135.xyz * _e138.xyz);
    let _e142 = global_4.mat_flags;
    if (_e142.x > 0.5f) {
        {
            let _e146 = albedo_a;
            let _e148 = emissive_rgb;
            let _e150 = global_4.layer_info;
            let _e152 = ((_e146.xyz + _e148) * _e150.z);
            let _e153 = albedo_a;
            frag_color = vec4<f32>(_e152.x, _e152.y, _e152.z, _e153.w);
            return;
        }
    }
    let _e159 = v_uv_1;
    let _e160 = textureSample(zengy_u_mr_tex_image, zengy_u_mr_tex_sampler, _e159);
    mr = _e160;
    let _e162 = global_4.mat_params;
    let _e164 = mr;
    metallic_10 = clamp((_e162.x * _e164.z), 0f, 1f);
    let _e171 = global_4.mat_params;
    let _e173 = mr;
    roughness_18 = clamp((_e171.y * _e173.y), 0.045f, 1f);
    let _e180 = v_world_normal_1;
    N_22 = normalize(_e180);
    let _e184 = gl_FrontFacing_1;
    if !(_e184) {
        {
            let _e186 = N_22;
            N_22 = -(_e186);
        }
    }
    let _e188 = global_4.camera_pos_fog;
    let _e190 = v_world_pos_1;
    V_14 = normalize((_e188.xyz - _e190));
    let _e194 = global_4.mat_flags;
    if (_e194.y > 0f) {
        {
            let _e198 = N_22;
            let _e199 = V_14;
            let _e200 = v_uv_1;
            let _e201 = perturbNormal(_e198, _e199, _e200);
            N_22 = _e201;
        }
    }
    let _e204 = global_4.sh_coeffs[4];
    if (_e204.w > 0.5f) {
        {
            let _e208 = N_22;
            let _e209 = dpdx(_e208);
            nx = _e209;
            let _e211 = N_22;
            let _e212 = dpdy(_e211);
            ny = _e212;
            let _e216 = nx;
            let _e217 = nx;
            let _e219 = ny;
            let _e220 = ny;
            variance_1 = min(0.15f, (0.5f * (dot(_e216, _e217) + dot(_e219, _e220))));
            let _e226 = roughness_18;
            let _e227 = roughness_18;
            r2_ = (_e226 * _e227);
            let _e230 = r2_;
            let _e231 = r2_;
            let _e233 = variance_1;
            roughness_18 = pow(clamp(((_e230 * _e231) + _e233), 0.0000041f, 1f), 0.25f);
        }
    }
    let _e241 = global_4.mat_params;
    let _e244 = global_4.mat_params;
    let _e248 = albedo_a;
    let _e250 = metallic_10;
    F0_14 = mix(vec3(((0.16f * _e241.z) * _e244.z)), _e248.xyz, vec3(_e250));
    let _e254 = v_world_pos_1;
    let _e255 = global_4.camera_pos_fog;
    let _e258 = global_4.camera_fwd_overlap;
    view_depth_4 = max(dot((_e254 - _e255.xyz), normalize(_e258.xyz)), 0f);
    let _e265 = gl_FragCoord_1;
    let _e269 = global_4.sh_coeffs[1];
    let _e273 = global_4.sh_coeffs[2];
    suv_3 = (_e265.xy * vec2<f32>(_e269.w, _e273.w));
    let _e278 = suv_3;
    let _e279 = textureSample(zengy_u_ssao_tex_image, zengy_u_ssao_tex_sampler, _e278);
    ssao_sample = _e279;
    let _e283 = global_4.sh_coeffs[0];
    if (_e283.w > 0.5f) {
        let _e287 = ssao_sample;
        local_18 = _e287.x;
    } else {
        local_18 = 1f;
    }
    let _e291 = local_18;
    ssao = _e291;
    let _e295 = global_4.sh_coeffs[3];
    if (_e295.w > 0.5f) {
        let _e299 = ssao_sample;
        local_19 = _e299.y;
    } else {
        local_19 = 1f;
    }
    let _e303 = local_19;
    contact_shadow = _e303;
    let _e305 = gl_FragCoord_1;
    let _e307 = ign(_e305.xy);
    rot_7 = (_e307 * 6.2831855f);
    let _e314 = global_4.dir_light_dir;
    let _e318 = global_4.layer_info;
    let _e320 = global_4.layer_info;
    let _e322 = layersOverlap(_e318.y, _e320.x);
    if ((_e314.w > 0f) && _e322) {
        {
            let _e324 = global_4.dir_light_dir;
            L_12 = normalize(_e324.xyz);
            let _e328 = N_22;
            let _e329 = L_12;
            let _e330 = view_depth_4;
            let _e331 = sampleShadowCSM(_e328, _e329, _e330);
            let _e332 = contact_shadow;
            vis_1 = (_e331 * _e332);
            let _e335 = Lo;
            let _e336 = N_22;
            let _e337 = V_14;
            let _e338 = F0_14;
            let _e339 = albedo_a;
            let _e341 = metallic_10;
            let _e342 = roughness_18;
            let _e343 = L_12;
            let _e344 = global_4.dir_light_col;
            let _e346 = global_4.dir_light_dir;
            let _e350 = evalLight(_e336, _e337, _e338, _e339.xyz, _e341, _e342, _e343, (_e344.xyz * _e346.w), 1f);
            let _e351 = vis_1;
            Lo = (_e335 + (_e350 * _e351));
        }
    }
    let _e354 = global_4.cluster_factors;
    if (_e354.z > 0.5f) {
        {
            let _e358 = suv_3;
            cx_1 = clamp(i32((_e358.x * 16f)), 0i, 15i);
            let _e367 = suv_3;
            cy_1 = clamp(i32((_e367.y * 9f)), 0i, 8i);
            let _e376 = view_depth_4;
            let _e380 = global_4.cluster_factors;
            let _e383 = global_4.cluster_factors;
            cz = clamp(i32(floor(((log(max(_e376, 0.05f)) * _e380.x) - _e383.y))), 0i, 23i);
            let _e392 = cy_1;
            let _e395 = cx_1;
            let _e399 = cz;
            let _e402 = global_1.clusters[((((_e392 * 16i) + _e395) * 24i) + _e399)];
            cl = _e402;
            let _e404 = cl;
            p_off = (_e404.x >> 8u);
            let _e409 = cl;
            p_cnt = (_e409.x & 255u);
            loop {
                let _e416 = i_12;
                let _e417 = p_cnt;
                if !((_e416 < _e417)) {
                    break;
                }
                {
                    let _e423 = p_off;
                    let _e424 = i_12;
                    let _e427 = global_2.cluster_indices[(_e423 + _e424)];
                    let _e429 = global.c_points[_e427];
                    pl = _e429;
                    let _e431 = pl;
                    let _e434 = global_4.layer_info;
                    let _e436 = layersOverlap(_e431.shadow_params.y, _e434.x);
                    if !(_e436) {
                        continue;
                    }
                    let _e438 = pl;
                    let _e441 = v_world_pos_1;
                    to_l_1 = (_e438.pos_range.xyz - _e441);
                    let _e444 = to_l_1;
                    dist_3 = length(_e444);
                    let _e447 = pl;
                    range_3 = max(_e447.pos_range.w, 0.001f);
                    let _e453 = dist_3;
                    let _e454 = range_3;
                    if (_e453 < _e454) {
                        {
                            let _e457 = dist_3;
                            let _e458 = range_3;
                            att_2 = clamp((1f - pow((_e457 / _e458), 4f)), 0f, 1f);
                            let _e467 = att_2;
                            let _e468 = att_2;
                            let _e470 = dist_3;
                            let _e471 = dist_3;
                            let _e475 = pl;
                            let _e478 = pl;
                            att_2 = ((_e467 * _e468) / (((_e470 * _e471) + 1f) + (_e475.shadow_params.x * _e478.shadow_params.x)));
                            let _e484 = to_l_1;
                            let _e485 = dist_3;
                            L_13 = (_e484 / vec3(max(_e485, 0.0001f)));
                            let _e491 = N_22;
                            let _e492 = L_13;
                            if (dot(_e491, _e492) <= 0f) {
                                continue;
                            }
                            let _e496 = pl;
                            if (_e496.col_radius.w >= 0f) {
                                let _e501 = pl;
                                let _e507 = pl;
                                let _e510 = N_22;
                                let _e511 = L_13;
                                let _e512 = rot_7;
                                let _e513 = pl;
                                let _e516 = samplePointShadow(i32((_e501.col_radius.w + 0.5f)), _e507.pos_range.xyz, _e510, _e511, _e512, _e513.shadow_params.x);
                                local_20 = _e516;
                            } else {
                                local_20 = 1f;
                            }
                            let _e519 = local_20;
                            vis_2 = _e519;
                            let _e521 = Lo;
                            let _e522 = N_22;
                            let _e523 = V_14;
                            let _e524 = F0_14;
                            let _e525 = albedo_a;
                            let _e527 = metallic_10;
                            let _e528 = roughness_18;
                            let _e529 = L_13;
                            let _e530 = pl;
                            let _e533 = att_2;
                            let _e535 = pl;
                            let _e538 = evalLight(_e522, _e523, _e524, _e525.xyz, _e527, _e528, _e529, (_e530.col_radius.xyz * _e533), _e535.shadow_params.z);
                            let _e539 = vis_2;
                            Lo = (_e521 + (_e538 * _e539));
                        }
                    }
                }
                continuing {
                    let _e420 = i_12;
                    i_12 = (_e420 + 1u);
                }
            }
            let _e542 = cl;
            s_off = (_e542.y >> 8u);
            let _e547 = cl;
            s_cnt = (_e547.y & 255u);
            loop {
                let _e554 = i_13;
                let _e555 = s_cnt;
                if !((_e554 < _e555)) {
                    break;
                }
                {
                    let _e561 = s_off;
                    let _e562 = i_13;
                    let _e565 = global_2.cluster_indices[(_e561 + _e562)];
                    let _e567 = global.c_spots[_e565];
                    sl = _e567;
                    let _e569 = sl;
                    let _e572 = global_4.layer_info;
                    let _e574 = layersOverlap(_e569.shadow_params.w, _e572.x);
                    if !(_e574) {
                        continue;
                    }
                    let _e576 = sl;
                    let _e579 = v_world_pos_1;
                    to_l_2 = (_e576.pos_range.xyz - _e579);
                    let _e582 = to_l_2;
                    dist_4 = length(_e582);
                    let _e585 = sl;
                    range_4 = max(_e585.pos_range.w, 0.001f);
                    let _e591 = dist_4;
                    let _e592 = range_4;
                    if (_e591 < _e592) {
                        {
                            let _e594 = to_l_2;
                            let _e595 = dist_4;
                            L_14 = (_e594 / vec3(max(_e595, 0.0001f)));
                            let _e601 = L_14;
                            let _e602 = sl;
                            theta_1 = dot(_e601, normalize(-(_e602.dir_cos_inner.xyz)));
                            let _e609 = sl;
                            let _e612 = sl;
                            eps = max((_e609.dir_cos_inner.w - _e612.col_cos_outer.w), 0.001f);
                            let _e619 = theta_1;
                            let _e620 = sl;
                            let _e624 = eps;
                            cone = clamp(((_e619 - _e620.col_cos_outer.w) / _e624), 0f, 1f);
                            let _e631 = dist_4;
                            let _e632 = range_4;
                            att_3 = clamp((1f - pow((_e631 / _e632), 4f)), 0f, 1f);
                            let _e641 = att_3;
                            let _e642 = att_3;
                            let _e644 = dist_4;
                            let _e645 = dist_4;
                            att_3 = ((_e641 * _e642) / ((_e644 * _e645) + 1f));
                            let _e650 = cone;
                            let _e653 = N_22;
                            let _e654 = L_14;
                            if ((_e650 <= 0f) || (dot(_e653, _e654) <= 0f)) {
                                continue;
                            }
                            let _e661 = N_22;
                            let _e662 = L_14;
                            spot_bias = (0.0012f + ((1f - max(dot(_e661, _e662), 0f)) * 0.004f));
                            let _e671 = sl;
                            if (_e671.shadow_params.x >= 0f) {
                                let _e676 = sl;
                                let _e682 = v_world_pos_1;
                                let _e683 = spot_bias;
                                let _e684 = rot_7;
                                let _e685 = sl;
                                let _e688 = sampleLocalTile(i32((_e676.shadow_params.x + 0.5f)), _e682, _e683, _e684, _e685.shadow_params.z);
                                local_21 = _e688;
                            } else {
                                local_21 = 1f;
                            }
                            let _e691 = local_21;
                            vis_3 = _e691;
                            let _e693 = Lo;
                            let _e694 = N_22;
                            let _e695 = V_14;
                            let _e696 = F0_14;
                            let _e697 = albedo_a;
                            let _e699 = metallic_10;
                            let _e700 = roughness_18;
                            let _e701 = L_14;
                            let _e702 = sl;
                            let _e705 = att_3;
                            let _e707 = cone;
                            let _e710 = evalLight(_e694, _e695, _e696, _e697.xyz, _e699, _e700, _e701, ((_e702.col_cos_outer.xyz * _e705) * _e707), 1f);
                            let _e711 = vis_3;
                            Lo = (_e693 + (_e710 * _e711));
                        }
                    }
                }
                continuing {
                    let _e558 = i_13;
                    i_13 = (_e558 + 1u);
                }
            }
            let _e714 = cl;
            r_off = (_e714.z >> 8u);
            let _e719 = cl;
            r_cnt = (_e719.z & 255u);
            loop {
                let _e726 = i_14;
                let _e727 = r_cnt;
                if !((_e726 < _e727)) {
                    break;
                }
                {
                    let _e733 = r_off;
                    let _e734 = i_14;
                    let _e737 = global_2.cluster_indices[(_e733 + _e734)];
                    let _e739 = global.c_rects[_e737];
                    rl_8 = _e739;
                    let _e741 = rl_8;
                    let _e744 = global_4.layer_info;
                    let _e746 = layersOverlap(_e741.col_pad.w, _e744.x);
                    if !(_e746) {
                        continue;
                    }
                    let _e748 = Lo;
                    let _e749 = rl_8;
                    let _e750 = N_22;
                    let _e751 = V_14;
                    let _e752 = F0_14;
                    let _e753 = albedo_a;
                    let _e755 = metallic_10;
                    let _e756 = roughness_18;
                    let _e757 = evalRectLight(_e749, _e750, _e751, _e752, _e753.xyz, _e755, _e756);
                    Lo = (_e748 + _e757);
                }
                continuing {
                    let _e730 = i_14;
                    i_14 = (_e730 + 1u);
                }
            }
        }
    }
    let _e759 = N_22;
    let _e760 = V_14;
    NdotV_2 = max(dot(_e759, _e760), 0f);
    let _e765 = NdotV_2;
    let _e766 = F0_14;
    let _e767 = roughness_18;
    let _e768 = fresnelSchlickRoughness(_e765, _e766, _e767);
    F_env = _e768;
    let _e772 = F_env;
    let _e775 = metallic_10;
    kD_env = ((vec3(1f) - _e772) * (1f - _e775));
    let _e779 = N_22;
    let _e780 = evalSH9Diffuse(_e779);
    let _e781 = global_4.ambient_sky;
    irradiance = (_e780 + _e781.xyz);
    let _e785 = irradiance;
    let _e786 = albedo_a;
    diffuse_ibl = (_e785 * _e786.xyz);
    let _e790 = V_14;
    let _e792 = N_22;
    R = reflect(-(_e790), _e792);
    let _e795 = R;
    let _e796 = equirectUv(_e795);
    let _e797 = roughness_18;
    let _e798 = global_4.sky_horizon;
    let _e801 = textureSampleLevel(zengy_u_prefilter_env_image, zengy_u_prefilter_env_sampler, _e796, (_e797 * _e798.w));
    prefiltered = _e801.xyz;
    let _e804 = global_4.probe_volumetric;
    probe_cnt = i32((_e804.x + 0.5f));
    let _e810 = probe_cnt;
    if (_e810 > 0i) {
        {
            loop {
                let _e823 = i_15;
                if !((_e823 < 32i)) {
                    break;
                }
                {
                    let _e830 = i_15;
                    let _e831 = probe_cnt;
                    if (_e830 >= _e831) {
                        break;
                    }
                    let _e833 = i_15;
                    let _e835 = global.c_probes[_e833];
                    pr = _e835;
                    let _e837 = v_world_pos_1;
                    let _e838 = pr;
                    d_6 = abs((_e837 - _e838.pos_int.xyz));
                    let _e844 = pr;
                    let _e847 = d_6;
                    edge_d = (_e844.half_blend.xyz - _e847);
                    let _e850 = edge_d;
                    let _e854 = edge_d;
                    let _e859 = edge_d;
                    if (((_e850.x > 0f) && (_e854.y > 0f)) && (_e859.z > 0f)) {
                        {
                            let _e866 = pr;
                            let _e872 = edge_d;
                            f3_ = smoothstep(vec3(0f), vec3(max(_e866.half_blend.w, 0.05f)), _e872);
                            let _e875 = f3_;
                            let _e877 = f3_;
                            let _e880 = f3_;
                            let _e883 = pr;
                            w_1 = (((_e875.x * _e877.y) * _e880.z) * _e883.pos_int.w);
                            let _e888 = N_22;
                            hemi = ((_e888.y * 0.5f) + 0.5f);
                            let _e895 = probe_irr;
                            let _e896 = pr;
                            let _e899 = pr;
                            let _e902 = hemi;
                            let _e905 = w_1;
                            let _e906 = pr;
                            probe_irr = (_e895 + (mix(_e896.ground_pad.xyz, _e899.sky_box.xyz, vec3(_e902)) * (_e905 * _e906.ground_pad.w)));
                            let _e912 = R;
                            r_hemi = ((_e912.y * 0.5f) + 0.5f);
                            let _e919 = pr;
                            let _e922 = pr;
                            let _e925 = r_hemi;
                            local_spec = mix(_e919.ground_pad.xyz, _e922.sky_box.xyz, vec3(_e925));
                            let _e929 = pr;
                            if (_e929.environment_info.x > 0.5f) {
                                {
                                    let _e934 = R;
                                    local_R = _e934;
                                    let _e936 = pr;
                                    if (_e936.sky_box.w > 0.5f) {
                                        {
                                            let _e941 = v_world_pos_1;
                                            let _e942 = pr;
                                            relative = (_e941 - _e942.pos_int.xyz);
                                            let _e947 = pr;
                                            let _e951 = pr;
                                            let _e954 = R;
                                            side = select(-(_e947.half_blend.xyz), _e951.half_blend.xyz, (_e954 >= vec3(0f)));
                                            t_1 = vec3(100000000000000000000f);
                                            axis = 0i;
                                            loop {
                                                let _e966 = axis;
                                                if !((_e966 < 3i)) {
                                                    break;
                                                }
                                                let _e973 = axis;
                                                let _e975 = R[_e973];
                                                if (abs(_e975) > 0.000001f) {
                                                    let _e979 = axis;
                                                    let _e981 = axis;
                                                    let _e983 = side[_e981];
                                                    let _e984 = axis;
                                                    let _e986 = relative[_e984];
                                                    let _e988 = axis;
                                                    let _e990 = R[_e988];
                                                    t_1[_e979] = ((_e983 - _e986) / _e990);
                                                }
                                                continuing {
                                                    let _e970 = axis;
                                                    axis = (_e970 + 1i);
                                                }
                                            }
                                            let _e992 = t_1;
                                            let _e994 = t_1;
                                            let _e997 = t_1;
                                            travel = max(min(min(_e992.x, _e994.y), _e997.z), 0f);
                                            let _e1003 = relative;
                                            let _e1004 = R;
                                            let _e1005 = travel;
                                            corrected = (_e1003 + (_e1004 * _e1005));
                                            let _e1009 = corrected;
                                            let _e1010 = corrected;
                                            if (dot(_e1009, _e1010) > 0.00000001f) {
                                                let _e1014 = corrected;
                                                local_R = normalize(_e1014);
                                            }
                                        }
                                    }
                                    let _e1016 = local_R;
                                    let _e1017 = equirectUv(_e1016);
                                    let _e1018 = roughness_18;
                                    let _e1019 = pr;
                                    let _e1023 = textureSampleLevel(zengy_u_probe_environment_image, zengy_u_probe_environment_sampler, _e1017, (_e1018 * _e1019.environment_info.y));
                                    local_spec = _e1023.xyz;
                                }
                            }
                            let _e1025 = probe_spec;
                            let _e1026 = local_spec;
                            let _e1027 = w_1;
                            probe_spec = (_e1025 + (_e1026 * _e1027));
                            let _e1030 = probe_w;
                            let _e1031 = w_1;
                            probe_w = (_e1030 + _e1031);
                        }
                    }
                }
                continuing {
                    let _e827 = i_15;
                    i_15 = (_e827 + 1i);
                }
            }
            let _e1033 = probe_w;
            pw = clamp(_e1033, 0f, 1f);
            let _e1038 = pw;
            if (_e1038 > 0f) {
                {
                    let _e1041 = diffuse_ibl;
                    let _e1042 = probe_irr;
                    let _e1043 = probe_w;
                    let _e1048 = albedo_a;
                    let _e1051 = pw;
                    diffuse_ibl = mix(_e1041, ((_e1042 / vec3(max(_e1043, 0.0001f))) * _e1048.xyz), vec3(_e1051));
                    let _e1054 = prefiltered;
                    let _e1055 = probe_spec;
                    let _e1056 = probe_w;
                    let _e1061 = pw;
                    prefiltered = mix(_e1054, (_e1055 / vec3(max(_e1056, 0.0001f))), vec3(_e1061));
                }
            }
        }
    }
    let _e1064 = v_world_pos_1;
    let _e1065 = N_22;
    let _e1069 = N_22;
    let _e1070 = sampleDynamicGi((_e1064 + (_e1065 * 0.03f)), _e1069);
    dynamic_gi = _e1070;
    let _e1072 = diffuse_ibl;
    let _e1073 = dynamic_gi;
    let _e1075 = albedo_a;
    let _e1078 = dynamic_gi;
    diffuse_ibl = mix(_e1072, (_e1073.xyz * _e1075.xyz), vec3(_e1078.w));
    let _e1082 = NdotV_2;
    let _e1083 = roughness_18;
    let _e1085 = textureSample(zengy_u_brdf_lut_image, zengy_u_brdf_lut_sampler, vec2<f32>(_e1082, _e1083));
    brdf = _e1085.xy;
    let _e1088 = F0_14;
    let _e1089 = brdf;
    let _e1092 = brdf;
    FssEss = ((_e1088 * _e1089.x) + vec3(_e1092.y));
    let _e1097 = brdf;
    let _e1099 = brdf;
    Ess = (_e1097.x + _e1099.y);
    let _e1104 = Ess;
    Ems = (1f - _e1104);
    let _e1107 = F0_14;
    let _e1109 = F0_14;
    Favg = (_e1107 + ((vec3(1f) - _e1109) / vec3(21f)));
    let _e1117 = FssEss;
    let _e1118 = Favg;
    let _e1122 = Ems;
    let _e1123 = Favg;
    Fms = ((_e1117 * _e1118) / max((vec3(1f) - (_e1122 * _e1123)), vec3(0.0001f)));
    let _e1131 = prefiltered;
    let _e1132 = FssEss;
    let _e1133 = Fms;
    let _e1134 = Ems;
    specular_ibl = (_e1131 * (_e1132 + (_e1133 * _e1134)));
    let _e1139 = v_uv_1;
    let _e1140 = textureSample(zengy_u_ao_tex_image, zengy_u_ao_tex_sampler, _e1139);
    ao_tex_val = _e1140.x;
    let _e1144 = ao_tex_val;
    let _e1145 = global_4.mat_params;
    let _e1148 = ssao;
    diff_ao = (mix(1f, _e1144, _e1145.w) * _e1148);
    let _e1151 = NdotV_2;
    let _e1152 = diff_ao;
    let _e1156 = roughness_18;
    let _e1164 = diff_ao;
    spec_ao = clamp(((pow((_e1151 + _e1152), exp2(((-16f * _e1156) - 1f))) - 1f) + _e1164), 0f, 1f);
    let _e1170 = kD_env;
    let _e1171 = diffuse_ibl;
    let _e1173 = diff_ao;
    let _e1175 = specular_ibl;
    let _e1176 = spec_ao;
    ambient = (((_e1170 * _e1171) * _e1173) + (_e1175 * _e1176));
    let _e1180 = ambient;
    let _e1181 = Lo;
    let _e1183 = emissive_rgb;
    color = ((_e1180 + _e1181) + _e1183);
    let _e1186 = global_4.camera_pos_fog;
    let _e1190 = global_4.probe_volumetric;
    if ((_e1186.w > 0.5f) && (_e1190.z < 0.5f)) {
        {
            let _e1195 = global_4.camera_pos_fog;
            let _e1197 = v_world_pos_1;
            let _e1200 = global_4.fog_color_start;
            d_7 = max((length((_e1195.xyz - _e1197)) - _e1200.w), 0f);
            let _e1207 = d_7;
            let _e1209 = global_4.ambient_sky;
            fog_f = (1f - exp((-(_e1207) * _e1209.w)));
            let _e1215 = color;
            let _e1216 = global_4.fog_color_start;
            let _e1218 = fog_f;
            color = mix(_e1215, _e1216.xyz, vec3(clamp(_e1218, 0f, 1f)));
        }
    }
    let _e1224 = color;
    let _e1225 = global_4.layer_info;
    let _e1227 = (_e1224 * _e1225.z);
    let _e1228 = albedo_a;
    frag_color = vec4<f32>(_e1227.x, _e1227.y, _e1227.z, _e1228.w);
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
    let _e160 = frag_color;
    return FragmentOutput(_e160);
}
