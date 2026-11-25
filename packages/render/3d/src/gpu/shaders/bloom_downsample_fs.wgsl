// Ported from bloom_downsample.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct BloomDownParams {
    texel_thresh: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_src_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_src_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: BloomDownParams;
var<private> frag_color: vec4<f32>;

fn main_1() {
    var uv: vec2<f32>;
    var t: vec2<f32>;
    var c0_: vec3<f32>;
    var c1_: vec3<f32>;
    var c2_: vec3<f32>;
    var c3_: vec3<f32>;
    var c4_: vec3<f32>;
    var col: vec3<f32>;
    var lum: f32;
    var thresh: f32;
    var knee: f32;
    var soft: f32;
    var contrib: f32;

    let _e6 = v_ndc_1;
    let _e13 = v_ndc_1;
    uv = vec2<f32>(((_e6.x * 0.5f) + 0.5f), (0.5f - (_e13.y * 0.5f)));
    let _e20 = global.texel_thresh;
    t = _e20.xy;
    let _e23 = uv;
    let _e24 = t;
    let _e27 = t;
    let _e32 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e23 + vec2<f32>(-(_e24.x), -(_e27.y))));
    c0_ = _e32.xyz;
    let _e35 = uv;
    let _e36 = t;
    let _e38 = t;
    let _e43 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e35 + vec2<f32>(_e36.x, -(_e38.y))));
    c1_ = _e43.xyz;
    let _e46 = uv;
    let _e47 = t;
    let _e50 = t;
    let _e54 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e46 + vec2<f32>(-(_e47.x), _e50.y)));
    c2_ = _e54.xyz;
    let _e57 = uv;
    let _e58 = t;
    let _e60 = t;
    let _e64 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e57 + vec2<f32>(_e58.x, _e60.y)));
    c3_ = _e64.xyz;
    let _e67 = uv;
    let _e68 = textureSample(zengy_u_src_image, zengy_u_src_sampler, _e67);
    c4_ = _e68.xyz;
    let _e71 = c0_;
    let _e72 = c1_;
    let _e74 = c2_;
    let _e76 = c3_;
    let _e80 = c4_;
    col = (((((_e71 + _e72) + _e74) + _e76) * 0.125f) + (_e80 * 0.5f));
    let _e85 = global.texel_thresh;
    if (_e85.w > 0.5f) {
        {
            let _e89 = col;
            let _e91 = col;
            let _e94 = col;
            lum = max(max(_e89.x, _e91.y), _e94.z);
            let _e98 = global.texel_thresh;
            thresh = _e98.z;
            let _e101 = thresh;
            knee = (_e101 * 0.5f);
            let _e105 = lum;
            let _e106 = thresh;
            let _e108 = knee;
            let _e112 = knee;
            soft = clamp(((_e105 - _e106) + _e108), 0f, (2f * _e112));
            let _e116 = soft;
            let _e117 = soft;
            let _e120 = knee;
            soft = ((_e116 * _e117) / max((4f * _e120), 0.00001f));
            let _e125 = soft;
            let _e126 = lum;
            let _e127 = thresh;
            let _e130 = lum;
            contrib = (max(_e125, (_e126 - _e127)) / max(_e130, 0.00001f));
            let _e135 = col;
            let _e136 = contrib;
            col = (_e135 * _e136);
        }
    }
    let _e138 = col;
    frag_color = vec4<f32>(_e138.x, _e138.y, _e138.z, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e13 = frag_color;
    return FragmentOutput(_e13);
}
