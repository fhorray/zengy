// Ported from ssao_blur.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct SsaoBlurParams {
    depth_range: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_ssao_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_ssao_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: SsaoBlurParams;
var<private> frag_color: vec4<f32>;

fn linearDepth(d: f32) -> f32 {
    var d_1: f32;
    var n: f32;
    var f: f32;

    d_1 = d;
    let _e10 = global.depth_range;
    n = _e10.x;
    let _e13 = global.depth_range;
    f = _e13.y;
    let _e16 = n;
    let _e17 = f;
    let _e19 = f;
    let _e20 = d_1;
    let _e21 = f;
    let _e22 = n;
    return ((_e16 * _e17) / max((_e19 - (_e20 * (_e21 - _e22))), 0.000001f));
}

fn main_1() {
    var uv: vec2<f32>;
    var d_c: f32;
    var lin_c: f32;
    var ss: vec2<i32>;
    var max_texel: vec2<i32>;
    var centre: vec2<i32>;
    var sum: vec2<f32> = vec2(0f);
    var wsum: f32 = 0f;
    var y: i32 = -1i;
    var x: i32;
    var t: vec2<i32>;
    var s: vec2<f32>;
    var suv: vec2<f32>;
    var lin_s: f32;
    var rel: f32;
    var local: f32;
    var spatial_w: f32;
    var w: f32;

    let _e8 = v_ndc_1;
    let _e15 = v_ndc_1;
    uv = vec2<f32>(((_e8.x * 0.5f) + 0.5f), (0.5f - (_e15.y * 0.5f)));
    let _e22 = uv;
    let _e23 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e22);
    d_c = _e23.x;
    let _e26 = d_c;
    if (_e26 >= 0.9999f) {
        {
            frag_color = vec4(1f);
            return;
        }
    }
    let _e31 = d_c;
    let _e32 = linearDepth(_e31);
    lin_c = _e32;
    let _e35 = textureDimensions(zengy_u_ssao_image, 0i);
    ss = vec2<i32>(_e35);
    let _e38 = ss;
    max_texel = (_e38 - vec2(1i));
    let _e43 = uv;
    let _e44 = ss;
    let _e50 = max_texel;
    centre = clamp(vec2<i32>((_e43 * vec2<f32>(_e44))), vec2(0i), _e50);
    loop {
        let _e61 = y;
        if !((_e61 <= 1i)) {
            break;
        }
        {
            x = -1i;
            loop {
                let _e71 = x;
                if !((_e71 <= 1i)) {
                    break;
                }
                {
                    let _e78 = centre;
                    let _e79 = x;
                    let _e80 = y;
                    let _e85 = max_texel;
                    t = clamp((_e78 + vec2<i32>(_e79, _e80)), vec2(0i), _e85);
                    let _e88 = t;
                    let _e90 = textureLoad(zengy_u_ssao_image, _e88, 0i);
                    s = _e90.xy;
                    let _e93 = t;
                    let _e98 = ss;
                    suv = ((vec2<f32>(_e93) + vec2(0.5f)) / vec2<f32>(_e98));
                    let _e102 = suv;
                    let _e103 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e102);
                    let _e105 = linearDepth(_e103.x);
                    lin_s = _e105;
                    let _e107 = lin_s;
                    let _e108 = lin_c;
                    let _e111 = lin_c;
                    rel = (abs((_e107 - _e108)) / max(_e111, 0.1f));
                    let _e116 = x;
                    let _e119 = y;
                    if ((_e116 == 0i) && (_e119 == 0i)) {
                        local = 1.5f;
                    } else {
                        local = 1f;
                    }
                    let _e126 = local;
                    spatial_w = _e126;
                    let _e128 = spatial_w;
                    let _e129 = rel;
                    let _e131 = rel;
                    w = (_e128 * exp(((-(_e129) * _e131) * 25f)));
                    let _e138 = sum;
                    let _e139 = s;
                    let _e140 = w;
                    sum = (_e138 + (_e139 * _e140));
                    let _e143 = wsum;
                    let _e144 = w;
                    wsum = (_e143 + _e144);
                }
                continuing {
                    let _e75 = x;
                    x = (_e75 + 1i);
                }
            }
        }
        continuing {
            let _e65 = y;
            y = (_e65 + 1i);
        }
    }
    let _e146 = wsum;
    if (_e146 < 0.0001f) {
        {
            frag_color = vec4(1f);
            return;
        }
    }
    let _e151 = sum;
    let _e152 = wsum;
    let _e154 = (_e151 / vec2(_e152));
    frag_color = vec4<f32>(_e154.x, _e154.y, 1f, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e17 = frag_color;
    return FragmentOutput(_e17);
}
