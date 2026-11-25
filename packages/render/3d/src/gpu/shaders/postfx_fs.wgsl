// Ported from postfx.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct PostFxParams {
    bloom_tint_int: vec4<f32>,
    grade_params: vec4<f32>,
    grade_tint_look: vec4<f32>,
    vignette_params: vec4<f32>,
    vignette_extra: vec4<f32>,
    local_exposure: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_hdr_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_hdr_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_bloom_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_bloom_sampler: sampler;
@group(0) @binding(2) 
var zengy_u_exposure_image: texture_2d<f32>;
@group(0) @binding(34) 
var zengy_u_exposure_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: PostFxParams;
var<private> frag_color: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;

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

fn linearToSrgb1_(c: f32) -> f32 {
    var c_1: f32;
    var local: f32;

    c_1 = c;
    let _e22 = c_1;
    c_1 = clamp(_e22, 0f, 1f);
    let _e26 = c_1;
    if (_e26 <= 0.0031308f) {
        let _e29 = c_1;
        local = (_e29 * 12.92f);
    } else {
        let _e33 = c_1;
        local = ((1.055f * pow(_e33, 0.41666666f)) - 0.055f);
    }
    let _e42 = local;
    return _e42;
}

fn linearToSrgb(c_2: vec3<f32>) -> vec3<f32> {
    var c_3: vec3<f32>;

    c_3 = c_2;
    let _e22 = c_3;
    let _e24 = linearToSrgb1_(_e22.x);
    let _e25 = c_3;
    let _e27 = linearToSrgb1_(_e25.y);
    let _e28 = c_3;
    let _e30 = linearToSrgb1_(_e28.z);
    return vec3<f32>(_e24, _e27, _e30);
}

fn acesFit(x: vec3<f32>) -> vec3<f32> {
    var x_1: vec3<f32>;

    x_1 = x;
    let _e22 = x_1;
    let _e23 = x_1;
    let _e31 = x_1;
    let _e33 = x_1;
    return (((_e22 * (_e23 + vec3(0.0245786f))) - vec3(0.000090537f)) / ((_e31 * ((0.983729f * _e33) + vec3(0.432951f))) + vec3(0.238081f)));
}

fn tonemapACES(c_4: vec3<f32>) -> vec3<f32> {
    var c_5: vec3<f32>;
    var input_mat: mat3x3<f32> = mat3x3<f32>(vec3<f32>(0.59719f, 0.076f, 0.0284f), vec3<f32>(0.35458f, 0.90834f, 0.13383f), vec3<f32>(0.04823f, 0.01566f, 0.83777f));
    var output_mat: mat3x3<f32> = mat3x3<f32>(vec3<f32>(1.60475f, -0.10208f, -0.00327f), vec3<f32>(-0.53108f, 1.10813f, -0.07276f), vec3<f32>(-0.07367f, -0.00605f, 1.07602f));

    c_5 = c_4;
    let _e56 = output_mat;
    let _e57 = input_mat;
    let _e58 = c_5;
    let _e65 = acesFit((_e57 * max((_e58 * 1.4f), vec3(0f))));
    return clamp((_e56 * _e65), vec3(0f), vec3(1f));
}

fn tonemapPbrNeutral(color: vec3<f32>) -> vec3<f32> {
    var color_1: vec3<f32>;
    var startCompression: f32 = 0.76f;
    var desaturation: f32 = 0.15f;
    var x_2: f32;
    var local_1: f32;
    var offset: f32;
    var peak: f32;
    var d: f32;
    var newPeak: f32;
    var g: f32;

    color_1 = color;
    let _e28 = color_1;
    let _e30 = color_1;
    let _e32 = color_1;
    x_2 = min(_e28.x, min(_e30.y, _e32.z));
    let _e37 = x_2;
    if (_e37 < 0.08f) {
        let _e40 = x_2;
        let _e42 = x_2;
        let _e44 = x_2;
        local_1 = (_e40 - ((6.25f * _e42) * _e44));
    } else {
        local_1 = 0.04f;
    }
    let _e49 = local_1;
    offset = _e49;
    let _e51 = color_1;
    let _e52 = offset;
    color_1 = (_e51 - vec3(_e52));
    let _e55 = color_1;
    let _e57 = color_1;
    let _e59 = color_1;
    peak = max(_e55.x, max(_e57.y, _e59.z));
    let _e64 = peak;
    let _e65 = startCompression;
    if (_e64 < _e65) {
        let _e67 = color_1;
        return _e67;
    }
    let _e69 = startCompression;
    d = (1f - _e69);
    let _e73 = d;
    let _e74 = d;
    let _e76 = peak;
    let _e77 = d;
    let _e79 = startCompression;
    newPeak = (1f - ((_e73 * _e74) / ((_e76 + _e77) - _e79)));
    let _e84 = color_1;
    let _e85 = newPeak;
    let _e86 = peak;
    color_1 = (_e84 * (_e85 / _e86));
    let _e91 = desaturation;
    let _e92 = peak;
    let _e93 = newPeak;
    g = (1f - (1f / ((_e91 * (_e92 - _e93)) + 1f)));
    let _e101 = color_1;
    let _e102 = newPeak;
    let _e104 = g;
    return mix(_e101, vec3(_e102), vec3(_e104));
}

fn agxDefaultContrastApprox(x_3: vec3<f32>) -> vec3<f32> {
    var x_4: vec3<f32>;
    var x2_: vec3<f32>;
    var x4_: vec3<f32>;

    x_4 = x_3;
    let _e22 = x_4;
    let _e23 = x_4;
    x2_ = (_e22 * _e23);
    let _e26 = x2_;
    let _e27 = x2_;
    x4_ = (_e26 * _e27);
    let _e31 = x4_;
    let _e33 = x2_;
    let _e36 = x4_;
    let _e38 = x_4;
    let _e42 = x4_;
    let _e46 = x2_;
    let _e48 = x_4;
    let _e52 = x2_;
    let _e56 = x_4;
    return ((((((((15.5f * _e31) * _e33) - ((40.14f * _e36) * _e38)) + (31.96f * _e42)) - ((6.868f * _e46) * _e48)) + (0.4298f * _e52)) + (0.1191f * _e56)) - vec3(0.00232f));
}

fn tonemapAgX(val: vec3<f32>, punchy: bool) -> vec3<f32> {
    var val_1: vec3<f32>;
    var punchy_1: bool;
    var agx_mat: mat3x3<f32> = mat3x3<f32>(vec3<f32>(0.84247905f, 0.042328242f, 0.042375654f), vec3<f32>(0.0784336f, 0.87846863f, 0.0784336f), vec3<f32>(0.079223745f, 0.07916613f, 0.879143f));
    var agx_mat_inv: mat3x3<f32> = mat3x3<f32>(vec3<f32>(1.196879f, -0.052896854f, -0.052971635f), vec3<f32>(-0.09802088f, 1.1519032f, -0.09804345f), vec3<f32>(-0.09902974f, -0.098961174f, 1.1510737f));
    var min_ev: f32 = -12.47393f;
    var max_ev: f32 = 4.026069f;
    var luma: f32;

    val_1 = val;
    punchy_1 = punchy;
    let _e63 = agx_mat;
    let _e64 = val_1;
    val_1 = (_e63 * max(_e64, vec3(0.000001f)));
    let _e69 = val_1;
    let _e71 = min_ev;
    let _e72 = max_ev;
    val_1 = clamp(log2(_e69), vec3(_e71), vec3(_e72));
    let _e76 = val_1;
    let _e77 = min_ev;
    let _e80 = max_ev;
    let _e81 = min_ev;
    val_1 = ((_e76 - vec3(_e77)) / vec3((_e80 - _e81)));
    let _e85 = val_1;
    let _e86 = agxDefaultContrastApprox(_e85);
    val_1 = _e86;
    let _e87 = agx_mat_inv;
    let _e88 = val_1;
    val_1 = clamp((_e87 * _e88), vec3(0f), vec3(1f));
    let _e95 = punchy_1;
    if _e95 {
        {
            let _e96 = val_1;
            luma = dot(_e96, vec3<f32>(0.2126f, 0.7152f, 0.0722f));
            let _e103 = val_1;
            val_1 = pow(_e103, vec3(1.18f));
            let _e107 = luma;
            let _e109 = val_1;
            val_1 = mix(vec3(_e107), _e109, vec3(1.22f));
        }
    }
    let _e113 = val_1;
    return pow(clamp(_e113, vec3(0f), vec3(1f)), vec3(2.2f));
}

fn interleavedGradientNoise(p: vec2<f32>) -> f32 {
    var p_1: vec2<f32>;

    p_1 = p;
    let _e23 = p_1;
    return fract((52.982918f * fract(dot(_e23, vec2<f32>(0.06711056f, 0.00583715f)))));
}

fn main_1() {
    var uv: vec2<f32>;
    var hdr: vec3<f32>;
    var texel: vec2<f32>;
    var nw: vec3<f32>;
    var ne: vec3<f32>;
    var sw: vec3<f32>;
    var se: vec3<f32>;
    var LUMA_W: vec3<f32> = vec3<f32>(0.299f, 0.587f, 0.114f);
    var PERCEPTUAL_GAMMA: vec3<f32> = vec3(0.45454544f);
    var inverse_pre_gain: f32;
    var l_m: f32;
    var l_nw: f32;
    var l_ne: f32;
    var l_sw: f32;
    var l_se: f32;
    var l_min: f32;
    var l_max: f32;
    var aa_dir: vec2<f32>;
    var dir_reduce: f32;
    var rcp_dir: f32;
    var aa_a: vec3<f32>;
    var aa_b: vec3<f32>;
    var l_b: f32;
    var local_2: vec3<f32>;
    var hdr_before_bloom: vec3<f32>;
    var local_3: vec3<f32>;
    var bloom: vec3<f32>;
    var ev: f32;
    var adapted: f32;
    var col: vec3<f32>;
    var lw: vec3<f32> = vec3<f32>(0.2126f, 0.7152f, 0.0722f);
    var gain: f32;
    var center_log: f32;
    var sum_log: f32;
    var sum_w: f32 = 1f;
    var radius: f32;
    var aspect: vec2<f32>;
    var dirs: array<vec2<f32>, 8> = array<vec2<f32>, 8>(vec2<f32>(1f, 0f), vec2(0.70710677f), vec2<f32>(0f, 1f), vec2<f32>(-0.70710677f, 0.70710677f), vec2<f32>(-1f, 0f), vec2(-0.70710677f), vec2<f32>(0f, -1f), vec2<f32>(0.70710677f, -0.70710677f));
    var i: i32 = 0i;
    var offset_1: vec2<f32>;
    var rgb: vec3<f32>;
    var l: f32;
    var w: f32;
    var bound: f32;
    var correction: f32;
    var mode: i32;
    var luma_1: f32;
    var d_1: vec2<f32>;
    var r: f32;
    var inner: f32;
    var vig: f32;
    var srgb: vec3<f32>;
    var dither: f32;

    let _e20 = v_ndc_1;
    let _e27 = v_ndc_1;
    uv = vec2<f32>(((_e20.x * 0.5f) + 0.5f), (0.5f - (_e27.y * 0.5f)));
    let _e34 = uv;
    let _e36 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, _e34, 0f);
    hdr = _e36.xyz;
    let _e39 = global.vignette_extra;
    if (_e39.z > 0.5f) {
        {
            let _e45 = textureDimensions(zengy_u_hdr_image, 0i);
            texel = (vec2(1f) / vec2<f32>(vec2<i32>(_e45)));
            let _e51 = uv;
            let _e57 = texel;
            let _e61 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e51 + (vec2<f32>(-1f, -1f) * _e57)), 0f);
            nw = _e61.xyz;
            let _e64 = uv;
            let _e69 = texel;
            let _e73 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e64 + (vec2<f32>(1f, -1f) * _e69)), 0f);
            ne = _e73.xyz;
            let _e76 = uv;
            let _e81 = texel;
            let _e85 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e76 + (vec2<f32>(-1f, 1f) * _e81)), 0f);
            sw = _e85.xyz;
            let _e88 = uv;
            let _e92 = texel;
            let _e96 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e88 + (vec2<f32>(1f, 1f) * _e92)), 0f);
            se = _e96.xyz;
            let _e110 = global.vignette_extra;
            inverse_pre_gain = (1f / max(_e110.w, 0.000001f));
            let _e116 = hdr;
            let _e117 = inverse_pre_gain;
            let _e122 = PERCEPTUAL_GAMMA;
            let _e124 = LUMA_W;
            l_m = dot(pow(max((_e116 * _e117), vec3(0f)), _e122), _e124);
            let _e127 = nw;
            let _e128 = inverse_pre_gain;
            let _e133 = PERCEPTUAL_GAMMA;
            let _e135 = LUMA_W;
            l_nw = dot(pow(max((_e127 * _e128), vec3(0f)), _e133), _e135);
            let _e138 = ne;
            let _e139 = inverse_pre_gain;
            let _e144 = PERCEPTUAL_GAMMA;
            let _e146 = LUMA_W;
            l_ne = dot(pow(max((_e138 * _e139), vec3(0f)), _e144), _e146);
            let _e149 = sw;
            let _e150 = inverse_pre_gain;
            let _e155 = PERCEPTUAL_GAMMA;
            let _e157 = LUMA_W;
            l_sw = dot(pow(max((_e149 * _e150), vec3(0f)), _e155), _e157);
            let _e160 = se;
            let _e161 = inverse_pre_gain;
            let _e166 = PERCEPTUAL_GAMMA;
            let _e168 = LUMA_W;
            l_se = dot(pow(max((_e160 * _e161), vec3(0f)), _e166), _e168);
            let _e171 = l_m;
            let _e172 = l_nw;
            let _e173 = l_ne;
            let _e175 = l_sw;
            let _e176 = l_se;
            l_min = min(_e171, min(min(_e172, _e173), min(_e175, _e176)));
            let _e181 = l_m;
            let _e182 = l_nw;
            let _e183 = l_ne;
            let _e185 = l_sw;
            let _e186 = l_se;
            l_max = max(_e181, max(max(_e182, _e183), max(_e185, _e186)));
            let _e191 = l_max;
            let _e192 = l_min;
            let _e196 = l_max;
            if ((_e191 - _e192) > max(0.0312f, (0.125f * _e196))) {
                {
                    let _e200 = l_nw;
                    let _e201 = l_ne;
                    let _e203 = l_sw;
                    let _e204 = l_se;
                    let _e208 = l_nw;
                    let _e209 = l_sw;
                    let _e211 = l_ne;
                    let _e212 = l_se;
                    aa_dir = vec2<f32>(-(((_e200 + _e201) - (_e203 + _e204))), ((_e208 + _e209) - (_e211 + _e212)));
                    let _e217 = l_nw;
                    let _e218 = l_ne;
                    let _e220 = l_sw;
                    let _e222 = l_se;
                    dir_reduce = max(((((_e217 + _e218) + _e220) + _e222) * 0.03125f), 0.0078125f);
                    let _e232 = aa_dir;
                    let _e235 = aa_dir;
                    let _e239 = dir_reduce;
                    rcp_dir = (1f / (min(abs(_e232.x), abs(_e235.y)) + _e239));
                    let _e243 = aa_dir;
                    let _e244 = rcp_dir;
                    let _e252 = texel;
                    aa_dir = (clamp((_e243 * _e244), vec2(-4f), vec2(4f)) * _e252);
                    let _e255 = uv;
                    let _e256 = aa_dir;
                    let _e265 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e255 + (_e256 * -0.16666666f)), 0f);
                    let _e267 = uv;
                    let _e268 = aa_dir;
                    let _e277 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e267 + (_e268 * 0.16666669f)), 0f);
                    aa_a = (0.5f * (_e265.xyz + _e277.xyz));
                    let _e282 = aa_a;
                    let _e286 = uv;
                    let _e287 = aa_dir;
                    let _e293 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e286 + (_e287 * -0.5f)), 0f);
                    let _e295 = uv;
                    let _e296 = aa_dir;
                    let _e301 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, (_e295 + (_e296 * 0.5f)), 0f);
                    aa_b = ((_e282 * 0.5f) + (0.25f * (_e293.xyz + _e301.xyz)));
                    let _e307 = aa_b;
                    let _e308 = inverse_pre_gain;
                    let _e313 = PERCEPTUAL_GAMMA;
                    let _e315 = LUMA_W;
                    l_b = dot(pow(max((_e307 * _e308), vec3(0f)), _e313), _e315);
                    let _e318 = l_b;
                    let _e319 = l_min;
                    let _e321 = l_b;
                    let _e322 = l_max;
                    if ((_e318 < _e319) || (_e321 > _e322)) {
                        let _e325 = aa_a;
                        local_2 = _e325;
                    } else {
                        let _e326 = aa_b;
                        local_2 = _e326;
                    }
                    let _e328 = local_2;
                    hdr = _e328;
                }
            }
        }
    }
    let _e329 = hdr;
    hdr_before_bloom = _e329;
    let _e331 = global.bloom_tint_int;
    if (_e331.w > 0f) {
        let _e335 = uv;
        let _e336 = textureSample(zengy_u_bloom_image, zengy_u_bloom_sampler, _e335);
        local_3 = _e336.xyz;
    } else {
        local_3 = vec3(0f);
    }
    let _e341 = local_3;
    bloom = _e341;
    let _e343 = hdr;
    let _e344 = bloom;
    let _e345 = global.bloom_tint_int;
    let _e348 = global.bloom_tint_int;
    hdr = (_e343 + ((_e344 * _e345.xyz) * _e348.w));
    let _e352 = global.grade_params;
    ev = _e352.x;
    let _e355 = global.vignette_extra;
    if (_e355.y > 0.5f) {
        {
            let _e363 = textureLoad(zengy_u_exposure_image, vec2<i32>(0i, 0i), 0i);
            adapted = _e363.x;
            let _e366 = adapted;
            let _e367 = zy_isnan(_e366);
            let _e369 = adapted;
            let _e370 = zy_isinf(_e369);
            if (!(_e367) && !(_e370)) {
                let _e373 = ev;
                let _e374 = adapted;
                ev = (_e373 + _e374);
            }
        }
    }
    let _e376 = hdr;
    let _e377 = ev;
    col = (_e376 * exp2(-(_e377)));
    let _e382 = global.local_exposure;
    let _e386 = global.local_exposure;
    if ((_e382.x > 0f) && (_e386.z > 0f)) {
        {
            let _e396 = ev;
            gain = exp2(-(_e396));
            let _e400 = hdr_before_bloom;
            let _e404 = gain;
            let _e406 = lw;
            center_log = log2(max(dot((max(_e400, vec3(0f)) * _e404), _e406), 0.00001f));
            let _e412 = center_log;
            sum_log = _e412;
            let _e416 = global.local_exposure;
            radius = clamp(_e416.y, 0.001f, 0.15f);
            let _e424 = textureDimensions(zengy_u_hdr_image, 0i);
            let _e429 = textureDimensions(zengy_u_hdr_image, 0i);
            aspect = vec2<f32>(1f, (f32(vec2<i32>(_e424).x) / f32(vec2<i32>(_e429).y)));
            loop {
                let _e475 = i;
                if !((_e475 < 8i)) {
                    break;
                }
                {
                    let _e482 = i;
                    let _e484 = dirs[_e482];
                    let _e485 = radius;
                    let _e487 = aspect;
                    offset_1 = ((_e484 * _e485) * _e487);
                    let _e490 = uv;
                    let _e491 = offset_1;
                    let _e499 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, clamp((_e490 + _e491), vec2(0f), vec2(1f)), 0f);
                    let _e504 = gain;
                    rgb = (max(_e499.xyz, vec3(0f)) * _e504);
                    let _e507 = rgb;
                    let _e508 = lw;
                    l = log2(max(dot(_e507, _e508), 0.00001f));
                    let _e514 = l;
                    let _e515 = center_log;
                    w = exp((-(abs((_e514 - _e515))) * 0.75f));
                    let _e523 = sum_log;
                    let _e524 = l;
                    let _e525 = w;
                    sum_log = (_e523 + (_e524 * _e525));
                    let _e528 = sum_w;
                    let _e529 = w;
                    sum_w = (_e528 + _e529);
                }
                continuing {
                    let _e479 = i;
                    i = (_e479 + 1i);
                }
            }
            let _e531 = global.local_exposure;
            bound = clamp(_e531.z, 0f, 2f);
            let _e539 = sum_log;
            let _e540 = sum_w;
            let _e543 = bound;
            let _e545 = bound;
            correction = clamp((-2.473931f - (_e539 / _e540)), -(_e543), _e545);
            let _e548 = col;
            let _e549 = correction;
            let _e550 = global.local_exposure;
            col = (_e548 * exp2((_e549 * clamp(_e550.x, 0f, 1f))));
        }
    }
    let _e558 = global.grade_params;
    mode = i32((_e558.w + 0.5f));
    let _e564 = mode;
    if (_e564 == 1i) {
        {
            let _e567 = col;
            let _e569 = col;
            col = (_e567 / (vec3(1f) + _e569));
        }
    } else {
        let _e573 = mode;
        if (_e573 == 2i) {
            {
                let _e576 = col;
                let _e577 = tonemapACES(_e576);
                col = _e577;
            }
        } else {
            let _e578 = mode;
            if (_e578 == 3i) {
                {
                    let _e581 = col;
                    let _e582 = global.grade_tint_look;
                    let _e586 = tonemapAgX(_e581, (_e582.w > 0.5f));
                    col = _e586;
                }
            } else {
                let _e587 = mode;
                if (_e587 == 4i) {
                    {
                        let _e590 = col;
                        let _e591 = tonemapPbrNeutral(_e590);
                        col = _e591;
                    }
                } else {
                    {
                        let _e592 = col;
                        col = clamp(_e592, vec3(0f), vec3(1f));
                    }
                }
            }
        }
    }
    let _e598 = col;
    let _e602 = global.grade_params;
    col = (((_e598 - vec3(0.5f)) * _e602.y) + vec3(0.5f));
    let _e608 = col;
    luma_1 = dot(_e608, vec3<f32>(0.2126f, 0.7152f, 0.0722f));
    let _e615 = luma_1;
    let _e617 = col;
    let _e618 = global.grade_params;
    let _e622 = global.grade_tint_look;
    col = (mix(vec3(_e615), _e617, vec3(_e618.z)) * _e622.xyz);
    let _e625 = global.vignette_params;
    if (_e625.w > 0.001f) {
        {
            let _e629 = uv;
            d_1 = (_e629 - vec2(0.5f));
            let _e634 = d_1;
            let _e637 = global.vignette_params;
            r = (length(_e634) * (1f + _e637.w));
            let _e643 = global.vignette_extra;
            inner = (0.75f - max(_e643.x, 0.05f));
            let _e650 = inner;
            let _e652 = r;
            vig = (1f - smoothstep(_e650, 0.75f, _e652));
            let _e656 = global.vignette_params;
            let _e658 = col;
            let _e659 = vig;
            col = mix(_e656.xyz, _e658, vec3(_e659));
        }
    }
    let _e662 = col;
    let _e663 = linearToSrgb(_e662);
    srgb = _e663;
    let _e666 = gl_FragCoord_1;
    let _e668 = interleavedGradientNoise(_e666.xy);
    dither = ((_e668 - 0.5f) / 255f);
    let _e674 = srgb;
    let _e675 = dither;
    let _e682 = clamp((_e674 + vec3(_e675)), vec3(0f), vec3(1f));
    frag_color = vec4<f32>(_e682.x, _e682.y, _e682.z, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>, @builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e33 = frag_color;
    return FragmentOutput(_e33);
}
