// Ported from volumetric_resolve.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct VolResolveParams {
    inv_view_proj: mat4x4<f32>,
    prev_view_proj: mat4x4<f32>,
    cam_pos_max: vec4<f32>,
    size_blend: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_cur_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_cur_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_hist_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_hist_sampler: sampler;
@group(0) @binding(2) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(34) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: VolResolveParams;
var<private> frag_color: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;

fn main_1() {
    var px: vec2<i32>;
    var cur: vec4<f32>;
    var uv: vec2<f32>;
    var d: f32;
    var sky: bool;
    var local: f32;
    var wp4_: vec4<f32>;
    var wp: vec3<f32>;
    var pc: vec4<f32>;
    var puv: vec2<f32>;
    var hist: vec4<f32>;
    var rel: f32;
    var max_px: vec2<i32>;
    var m1_: vec3<f32> = vec3(0f);
    var m2_: vec3<f32> = vec3(0f);
    var y: i32 = -1i;
    var x: i32;
    var s: vec3<f32>;
    var mean: vec3<f32>;
    var sigma: vec3<f32>;
    var clipped: vec3<f32>;

    let _e17 = gl_FragCoord_1;
    px = vec2<i32>(_e17.xy);
    let _e21 = px;
    let _e23 = textureLoad(zengy_u_cur_image, _e21, 0i);
    cur = _e23;
    let _e25 = global.size_blend;
    if (_e25.w < 0.5f) {
        {
            let _e29 = cur;
            frag_color = _e29;
            return;
        }
    }
    let _e30 = v_ndc_1;
    let _e37 = v_ndc_1;
    uv = vec2<f32>(((_e30.x * 0.5f) + 0.5f), (0.5f - (_e37.y * 0.5f)));
    let _e44 = uv;
    let _e46 = textureSampleLevel(zengy_u_depth_image, zengy_u_depth_sampler, _e44, 0f);
    d = _e46.x;
    let _e49 = d;
    sky = (_e49 >= 0.9999f);
    let _e53 = global.inv_view_proj;
    let _e54 = v_ndc_1;
    let _e55 = sky;
    if _e55 {
        local = 1f;
    } else {
        let _e57 = d;
        local = _e57;
    }
    let _e59 = local;
    wp4_ = (_e53 * vec4<f32>(_e54.x, _e54.y, _e59, 1f));
    let _e66 = wp4_;
    let _e68 = wp4_;
    wp = (_e66.xyz / vec3(max(_e68.w, 0.00001f)));
    let _e75 = sky;
    if _e75 {
        {
            let _e76 = global.cam_pos_max;
            let _e78 = wp;
            let _e79 = global.cam_pos_max;
            let _e83 = global.cam_pos_max;
            wp = (_e76.xyz + (normalize((_e78 - _e79.xyz)) * _e83.w));
        }
    }
    let _e87 = global.prev_view_proj;
    let _e88 = wp;
    pc = (_e87 * vec4<f32>(_e88.x, _e88.y, _e88.z, 1f));
    let _e96 = pc;
    let _e98 = pc;
    let _e106 = pc;
    let _e108 = pc;
    puv = vec2<f32>((((_e96.x / _e98.w) * 0.5f) + 0.5f), (0.5f - ((_e106.y / _e108.w) * 0.5f)));
    let _e116 = pc;
    let _e120 = puv;
    let _e125 = puv;
    let _e130 = puv;
    let _e135 = puv;
    if (((((_e116.w <= 0.0001f) || (_e120.x < 0f)) || (_e125.x > 1f)) || (_e130.y < 0f)) || (_e135.y > 1f)) {
        {
            let _e140 = cur;
            frag_color = _e140;
            return;
        }
    }
    let _e141 = puv;
    let _e143 = textureSampleLevel(zengy_u_hist_image, zengy_u_hist_sampler, _e141, 0f);
    hist = _e143;
    let _e145 = hist;
    let _e147 = cur;
    let _e151 = cur;
    rel = (abs((_e145.w - _e147.w)) / max(_e151.w, 0.5f));
    let _e157 = rel;
    if (_e157 > 0.2f) {
        {
            let _e160 = cur;
            frag_color = _e160;
            return;
        }
    }
    let _e161 = global.size_blend;
    max_px = (vec2<i32>(_e161.xy) - vec2(1i));
    loop {
        let _e177 = y;
        if !((_e177 <= 1i)) {
            break;
        }
        {
            x = -1i;
            loop {
                let _e187 = x;
                if !((_e187 <= 1i)) {
                    break;
                }
                {
                    let _e194 = px;
                    let _e195 = x;
                    let _e196 = y;
                    let _e201 = max_px;
                    let _e204 = textureLoad(zengy_u_cur_image, clamp((_e194 + vec2<i32>(_e195, _e196)), vec2(0i), _e201), 0i);
                    s = _e204.xyz;
                    let _e207 = m1_;
                    let _e208 = s;
                    m1_ = (_e207 + _e208);
                    let _e210 = m2_;
                    let _e211 = s;
                    let _e212 = s;
                    m2_ = (_e210 + (_e211 * _e212));
                }
                continuing {
                    let _e191 = x;
                    x = (_e191 + 1i);
                }
            }
        }
        continuing {
            let _e181 = y;
            y = (_e181 + 1i);
        }
    }
    let _e215 = m1_;
    mean = (_e215 / vec3(9f));
    let _e220 = m2_;
    let _e224 = mean;
    let _e225 = mean;
    sigma = sqrt(max(((_e220 / vec3(9f)) - (_e224 * _e225)), vec3(0f)));
    let _e233 = hist;
    let _e235 = mean;
    let _e237 = sigma;
    let _e240 = mean;
    let _e242 = sigma;
    clipped = clamp(_e233.xyz, (_e235 - (1.5f * _e237)), (_e240 + (1.5f * _e242)));
    let _e247 = clipped;
    let _e248 = cur;
    let _e250 = global.size_blend;
    let _e253 = mix(_e247, _e248.xyz, vec3(_e250.z));
    let _e254 = cur;
    frag_color = vec4<f32>(_e253.x, _e253.y, _e253.z, _e254.w);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>, @builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e29 = frag_color;
    return FragmentOutput(_e29);
}
