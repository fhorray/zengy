// Ported from ssao.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct SsaoParams {
    proj: mat4x4<f32>,
    inv_proj: mat4x4<f32>,
    params: vec4<f32>,
    sun_view_dir: vec4<f32>,
    contact_params: vec4<f32>,
    fade_range: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: SsaoParams;
var<private> frag_color: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;

fn reconstructViewPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    var uv_1: vec2<f32>;
    var depth_1: f32;
    var ndc: vec4<f32>;
    var vp: vec4<f32>;

    uv_1 = uv;
    depth_1 = depth;
    let _e20 = uv_1;
    let _e27 = uv_1;
    let _e32 = depth_1;
    ndc = vec4<f32>(((_e20.x * 2f) - 1f), (1f - (_e27.y * 2f)), _e32, 1f);
    let _e36 = global.inv_proj;
    let _e37 = ndc;
    vp = (_e36 * _e37);
    let _e40 = vp;
    let _e42 = vp;
    return (_e40.xyz / vec3(max(_e42.w, 0.00001f)));
}

fn hash12_(p: vec2<f32>) -> f32 {
    var p_1: vec2<f32>;

    p_1 = p;
    let _e19 = p_1;
    return fract((52.982918f * fract(dot(_e19, vec2<f32>(0.06711056f, 0.00583715f)))));
}

fn main_1() {
    var uv_2: vec2<f32>;
    var d: f32;
    var pos: vec3<f32>;
    var texel: vec2<f32>;
    var ux: vec2<f32>;
    var lx: vec2<f32>;
    var uy: vec2<f32>;
    var ly: vec2<f32>;
    var dr: f32;
    var dl: f32;
    var dd: f32;
    var du: f32;
    var right: vec3<f32>;
    var left: vec3<f32>;
    var down: vec3<f32>;
    var up: vec3<f32>;
    var right_valid: bool;
    var left_valid: bool;
    var down_valid: bool;
    var up_valid: bool;
    var local: vec3<f32>;
    var local_1: vec3<f32>;
    var dx: vec3<f32>;
    var local_2: vec3<f32>;
    var local_3: vec3<f32>;
    var dy: vec3<f32>;
    var nn: vec3<f32>;
    var local_4: vec3<f32>;
    var N: vec3<f32>;
    var dist_fade: f32;
    var ao: f32 = 1f;
    var radius: f32;
    var bias: f32;
    var occ: f32 = 0f;
    var rot: f32;
    var radius_uv: vec2<f32>;
    var i: i32 = 0i;
    var ang: f32;
    var axis: vec2<f32>;
    var horizon: f32;
    var j: i32;
    var suv: vec2<f32>;
    var sd: f32;
    var delta: vec3<f32>;
    var len: f32;
    var falloff: f32;
    var i_1: i32 = 0i;
    var fi: f32;
    var ang_1: f32;
    var r: f32;
    var offset: vec3<f32>;
    var dir: vec3<f32>;
    var sp: vec3<f32>;
    var clip: vec4<f32>;
    var suv_1: vec2<f32>;
    var sd_1: f32;
    var sample_vp: vec3<f32>;
    var range_check: f32;
    var local_5: f32;
    var contact: f32 = 1f;
    var ldir_v: vec3<f32>;
    var ndotl_v: f32;
    var step_len: f32;
    var occ_c: f32 = 0f;
    var slope_bias: f32;
    var start_pos: vec3<f32>;
    var jitter: f32;
    var i_2: i32 = 1i;
    var rp: vec3<f32>;
    var rclip: vec4<f32>;
    var ruv: vec2<f32>;
    var rd: f32;
    var rvp: vec3<f32>;
    var dz: f32;
    var fade_n: f32;

    let _e16 = global.params;
    let _e20 = global.contact_params;
    if ((_e16.w < 0.5f) && (_e20.w < 0.5f)) {
        {
            frag_color = vec4(1f);
            return;
        }
    }
    let _e27 = v_ndc_1;
    let _e34 = v_ndc_1;
    uv_2 = vec2<f32>(((_e27.x * 0.5f) + 0.5f), (0.5f - (_e34.y * 0.5f)));
    let _e41 = uv_2;
    let _e42 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e41);
    d = _e42.x;
    let _e45 = d;
    if (_e45 >= 0.9999f) {
        {
            frag_color = vec4(1f);
            return;
        }
    }
    let _e50 = uv_2;
    let _e51 = d;
    let _e52 = reconstructViewPos(_e50, _e51);
    pos = _e52;
    let _e56 = textureDimensions(zengy_u_depth_image, 0i);
    texel = (vec2(1f) / vec2<f32>(vec2<i32>(_e56)));
    let _e62 = uv_2;
    let _e63 = texel;
    ux = clamp((_e62 + vec2<f32>(_e63.x, 0f)), vec2(0f), vec2(1f));
    let _e77 = uv_2;
    let _e78 = texel;
    lx = clamp((_e77 - vec2<f32>(_e78.x, 0f)), vec2(0f), vec2(1f));
    let _e92 = uv_2;
    let _e94 = texel;
    uy = clamp((_e92 + vec2<f32>(0f, _e94.y)), vec2(0f), vec2(1f));
    let _e107 = uv_2;
    let _e109 = texel;
    ly = clamp((_e107 - vec2<f32>(0f, _e109.y)), vec2(0f), vec2(1f));
    let _e122 = ux;
    let _e123 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e122);
    dr = _e123.x;
    let _e126 = lx;
    let _e127 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e126);
    dl = _e127.x;
    let _e130 = uy;
    let _e131 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e130);
    dd = _e131.x;
    let _e134 = ly;
    let _e135 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e134);
    du = _e135.x;
    let _e138 = ux;
    let _e139 = dr;
    let _e140 = reconstructViewPos(_e138, _e139);
    let _e141 = pos;
    right = (_e140 - _e141);
    let _e144 = pos;
    let _e145 = lx;
    let _e146 = dl;
    let _e147 = reconstructViewPos(_e145, _e146);
    left = (_e144 - _e147);
    let _e150 = uy;
    let _e151 = dd;
    let _e152 = reconstructViewPos(_e150, _e151);
    let _e153 = pos;
    down = (_e152 - _e153);
    let _e156 = pos;
    let _e157 = ly;
    let _e158 = du;
    let _e159 = reconstructViewPos(_e157, _e158);
    up = (_e156 - _e159);
    let _e162 = right;
    let _e163 = right;
    let _e167 = dr;
    right_valid = ((dot(_e162, _e163) > 0.000000000001f) && (_e167 < 0.9999f));
    let _e172 = left;
    let _e173 = left;
    let _e177 = dl;
    left_valid = ((dot(_e172, _e173) > 0.000000000001f) && (_e177 < 0.9999f));
    let _e182 = down;
    let _e183 = down;
    let _e187 = dd;
    down_valid = ((dot(_e182, _e183) > 0.000000000001f) && (_e187 < 0.9999f));
    let _e192 = up;
    let _e193 = up;
    let _e197 = du;
    up_valid = ((dot(_e192, _e193) > 0.000000000001f) && (_e197 < 0.9999f));
    let _e202 = right_valid;
    let _e203 = left_valid;
    let _e205 = right;
    let _e208 = left;
    if (_e202 && (!(_e203) || (abs(_e205.z) < abs(_e208.z)))) {
        let _e214 = right;
        local_1 = _e214;
    } else {
        let _e215 = left_valid;
        if _e215 {
            let _e216 = left;
            local = _e216;
        } else {
            local = vec3(0f);
        }
        let _e221 = local;
        local_1 = _e221;
    }
    let _e223 = local_1;
    dx = _e223;
    let _e225 = down_valid;
    let _e226 = up_valid;
    let _e228 = down;
    let _e231 = up;
    if (_e225 && (!(_e226) || (abs(_e228.z) < abs(_e231.z)))) {
        let _e237 = down;
        local_3 = _e237;
    } else {
        let _e238 = up_valid;
        if _e238 {
            let _e239 = up;
            local_2 = _e239;
        } else {
            local_2 = vec3(0f);
        }
        let _e244 = local_2;
        local_3 = _e244;
    }
    let _e246 = local_3;
    dy = _e246;
    let _e248 = dy;
    let _e249 = dx;
    nn = cross(_e248, _e249);
    let _e252 = nn;
    let _e253 = nn;
    if (dot(_e252, _e253) > 0.000000000001f) {
        let _e257 = nn;
        local_4 = normalize(_e257);
    } else {
        let _e259 = pos;
        let _e261 = pos;
        let _e262 = pos;
        local_4 = (-(_e259) * inverseSqrt(max(dot(_e261, _e262), 0.000000000001f)));
    }
    let _e269 = local_4;
    N = _e269;
    let _e271 = N;
    let _e272 = pos;
    if (dot(_e271, -(_e272)) < 0f) {
        let _e277 = N;
        N = -(_e277);
    }
    let _e280 = global.fade_range;
    let _e284 = global.fade_range;
    let _e286 = global.fade_range;
    let _e293 = pos;
    dist_fade = (1f - smoothstep(max(_e280.x, 0f), max(_e284.y, (max(_e286.x, 0f) + 0.001f)), abs(_e293.z)));
    let _e301 = global.params;
    let _e305 = dist_fade;
    if ((_e301.w > 0.5f) && (_e305 > 0.01f)) {
        {
            let _e309 = global.params;
            radius = max(_e309.x, 0.001f);
            let _e314 = global.params;
            let _e319 = pos;
            bias = (max(_e314.y, 0f) + (0.004f * abs(_e319.z)));
            let _e328 = gl_FragCoord_1;
            let _e330 = hash12_(_e328.xy);
            rot = (_e330 * 6.2831855f);
            let _e334 = global.fade_range;
            if (_e334.z > 0.5f) {
                {
                    let _e342 = global.proj[0][0];
                    let _e347 = global.proj[1][1];
                    let _e350 = radius;
                    let _e352 = pos;
                    radius_uv = ((abs(vec2<f32>(_e342, _e347)) * _e350) / vec2(max((abs(_e352.z) * 2f), 0.001f)));
                    loop {
                        let _e364 = i;
                        if !((_e364 < 4i)) {
                            break;
                        }
                        {
                            let _e371 = rot;
                            let _e372 = i;
                            ang = (_e371 + (f32(_e372) * 1.5707964f));
                            let _e378 = ang;
                            let _e380 = ang;
                            axis = vec2<f32>(cos(_e378), sin(_e380));
                            horizon = 0f;
                            j = 1i;
                            loop {
                                let _e388 = j;
                                if !((_e388 <= 3i)) {
                                    break;
                                }
                                {
                                    let _e395 = uv_2;
                                    let _e396 = axis;
                                    let _e397 = radius_uv;
                                    let _e399 = j;
                                    suv = (_e395 + ((_e396 * _e397) * (f32(_e399) / 3f)));
                                    let _e406 = suv;
                                    let _e411 = suv;
                                    if (any((_e406 < vec2(0f))) || any((_e411 > vec2(1f)))) {
                                        continue;
                                    }
                                    let _e417 = suv;
                                    let _e418 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e417);
                                    sd = _e418.x;
                                    let _e421 = sd;
                                    if (_e421 >= 0.9999f) {
                                        continue;
                                    }
                                    let _e424 = suv;
                                    let _e425 = sd;
                                    let _e426 = reconstructViewPos(_e424, _e425);
                                    let _e427 = pos;
                                    delta = (_e426 - _e427);
                                    let _e430 = delta;
                                    len = length(_e430);
                                    let _e433 = len;
                                    let _e434 = bias;
                                    let _e438 = len;
                                    let _e439 = radius;
                                    if ((_e433 <= max(_e434, 0.0001f)) || (_e438 >= _e439)) {
                                        continue;
                                    }
                                    let _e443 = radius;
                                    let _e446 = radius;
                                    let _e447 = len;
                                    falloff = (1f - smoothstep((_e443 * 0.25f), _e446, _e447));
                                    let _e451 = horizon;
                                    let _e452 = N;
                                    let _e453 = delta;
                                    let _e454 = len;
                                    let _e458 = bias;
                                    let _e459 = len;
                                    let _e464 = falloff;
                                    horizon = max(_e451, (max((dot(_e452, (_e453 / vec3(_e454))) - (_e458 / _e459)), 0f) * _e464));
                                }
                                continuing {
                                    let _e392 = j;
                                    j = (_e392 + 1i);
                                }
                            }
                            let _e467 = occ;
                            let _e468 = horizon;
                            occ = (_e467 + (_e468 * 3f));
                        }
                        continuing {
                            let _e368 = i;
                            i = (_e368 + 1i);
                        }
                    }
                }
            } else {
                loop {
                    let _e474 = i_1;
                    if !((_e474 < 12i)) {
                        break;
                    }
                    {
                        let _e481 = i_1;
                        fi = f32(_e481);
                        let _e484 = rot;
                        let _e485 = fi;
                        ang_1 = (_e484 + (_e485 * 2.3999631f));
                        let _e490 = fi;
                        let _e496 = radius;
                        r = (sqrt(((_e490 + 0.5f) / 12f)) * _e496);
                        let _e499 = ang_1;
                        let _e501 = ang_1;
                        let _e505 = fi;
                        offset = vec3<f32>(cos(_e499), sin(_e501), (0.35f + (0.4f * fract((_e505 * 0.37f)))));
                        let _e513 = offset;
                        dir = normalize(_e513);
                        let _e516 = dir;
                        let _e517 = N;
                        if (dot(_e516, _e517) < 0f) {
                            let _e521 = dir;
                            dir = -(_e521);
                        }
                        let _e523 = dir;
                        let _e524 = N;
                        dir = normalize((_e523 + (_e524 * 0.25f)));
                        let _e529 = pos;
                        let _e530 = dir;
                        let _e531 = r;
                        sp = (_e529 + (_e530 * _e531));
                        let _e535 = global.proj;
                        let _e536 = sp;
                        clip = (_e535 * vec4<f32>(_e536.x, _e536.y, _e536.z, 1f));
                        let _e544 = clip;
                        if (_e544.w <= 0.0001f) {
                            continue;
                        }
                        let _e548 = clip;
                        let _e550 = clip;
                        let _e558 = clip;
                        let _e560 = clip;
                        suv_1 = vec2<f32>((((_e548.x / _e550.w) * 0.5f) + 0.5f), (0.5f - ((_e558.y / _e560.w) * 0.5f)));
                        let _e568 = suv_1;
                        let _e572 = suv_1;
                        let _e577 = suv_1;
                        let _e582 = suv_1;
                        if ((((_e568.x < 0f) || (_e572.x > 1f)) || (_e577.y < 0f)) || (_e582.y > 1f)) {
                            continue;
                        }
                        let _e587 = suv_1;
                        let _e588 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e587);
                        sd_1 = _e588.x;
                        let _e591 = sd_1;
                        if (_e591 >= 0.9999f) {
                            continue;
                        }
                        let _e594 = suv_1;
                        let _e595 = sd_1;
                        let _e596 = reconstructViewPos(_e594, _e595);
                        sample_vp = _e596;
                        let _e600 = radius;
                        let _e601 = pos;
                        let _e603 = sample_vp;
                        range_check = smoothstep(0f, 1f, (_e600 / max(abs((_e601.z - _e603.z)), 0.001f)));
                        let _e612 = occ;
                        let _e613 = sample_vp;
                        let _e615 = sp;
                        let _e617 = bias;
                        if (_e613.z >= (_e615.z + _e617)) {
                            local_5 = 1f;
                        } else {
                            local_5 = 0f;
                        }
                        let _e623 = local_5;
                        let _e624 = range_check;
                        occ = (_e612 + (_e623 * _e624));
                    }
                    continuing {
                        let _e478 = i_1;
                        i_1 = (_e478 + 1i);
                    }
                }
            }
            let _e628 = occ;
            let _e631 = global.params;
            let _e634 = dist_fade;
            ao = clamp((1f - (((_e628 / 12f) * _e631.z) * _e634)), 0.05f, 1f);
        }
    }
    let _e642 = global.contact_params;
    let _e646 = dist_fade;
    if ((_e642.w > 0.5f) && (_e646 > 0.01f)) {
        {
            let _e650 = global.sun_view_dir;
            ldir_v = normalize(_e650.xyz);
            let _e654 = N;
            let _e655 = ldir_v;
            ndotl_v = dot(_e654, _e655);
            let _e658 = ndotl_v;
            if (_e658 > 0.08f) {
                {
                    let _e661 = global.sun_view_dir;
                    let _e663 = global.contact_params;
                    step_len = (_e661.w / max(_e663.z, 4f));
                    let _e673 = pos;
                    let _e678 = ndotl_v;
                    slope_bias = ((0.03f + (0.012f * abs(_e673.z))) / max(_e678, 0.25f));
                    let _e683 = pos;
                    let _e684 = N;
                    let _e685 = slope_bias;
                    start_pos = (_e683 + (_e684 * _e685));
                    let _e689 = gl_FragCoord_1;
                    let _e695 = hash12_((_e689.xy + vec2<f32>(17f, 31f)));
                    jitter = _e695;
                    loop {
                        let _e699 = i_2;
                        if !((_e699 <= 16i)) {
                            break;
                        }
                        {
                            let _e706 = i_2;
                            let _e708 = global.contact_params;
                            if (f32(_e706) > _e708.z) {
                                break;
                            }
                            let _e711 = start_pos;
                            let _e712 = ldir_v;
                            let _e713 = i_2;
                            let _e717 = jitter;
                            let _e721 = step_len;
                            rp = (_e711 + (_e712 * (((f32(_e713) - 0.5f) + (_e717 * 0.5f)) * _e721)));
                            let _e726 = global.proj;
                            let _e727 = rp;
                            rclip = (_e726 * vec4<f32>(_e727.x, _e727.y, _e727.z, 1f));
                            let _e735 = rclip;
                            if (_e735.w <= 0.0001f) {
                                break;
                            }
                            let _e739 = rclip;
                            let _e741 = rclip;
                            let _e749 = rclip;
                            let _e751 = rclip;
                            ruv = vec2<f32>((((_e739.x / _e741.w) * 0.5f) + 0.5f), (0.5f - ((_e749.y / _e751.w) * 0.5f)));
                            let _e759 = ruv;
                            let _e763 = ruv;
                            let _e768 = ruv;
                            let _e773 = ruv;
                            if ((((_e759.x < 0f) || (_e763.x > 1f)) || (_e768.y < 0f)) || (_e773.y > 1f)) {
                                break;
                            }
                            let _e778 = ruv;
                            let _e779 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e778);
                            rd = _e779.x;
                            let _e782 = rd;
                            if (_e782 >= 0.9999f) {
                                continue;
                            }
                            let _e785 = ruv;
                            let _e786 = rd;
                            let _e787 = reconstructViewPos(_e785, _e786);
                            rvp = _e787;
                            let _e789 = rvp;
                            let _e791 = rp;
                            dz = (_e789.z - _e791.z);
                            let _e795 = dz;
                            let _e796 = slope_bias;
                            let _e798 = dz;
                            let _e799 = global.contact_params;
                            let _e801 = slope_bias;
                            if ((_e795 > _e796) && (_e798 < (_e799.y + _e801))) {
                                {
                                    occ_c = 1f;
                                    break;
                                }
                            }
                        }
                        continuing {
                            let _e703 = i_2;
                            i_2 = (_e703 + 1i);
                        }
                    }
                    let _e808 = ndotl_v;
                    fade_n = smoothstep(0.08f, 0.28f, _e808);
                    let _e812 = occ_c;
                    let _e813 = global.contact_params;
                    let _e816 = dist_fade;
                    let _e818 = fade_n;
                    contact = (1f - (((_e812 * _e813.x) * _e816) * _e818));
                }
            }
        }
    }
    let _e821 = ao;
    let _e822 = contact;
    frag_color = vec4<f32>(_e821, _e822, 1f, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>, @builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e25 = frag_color;
    return FragmentOutput(_e25);
}
