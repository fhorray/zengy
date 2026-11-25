// Ported from bloom_upsample.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct BloomUpParams {
    texel_scatter: vec4<f32>,
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
var<uniform> global: BloomUpParams;
var<private> frag_color: vec4<f32>;

fn main_1() {
    var uv: vec2<f32>;
    var t: vec2<f32>;
    var s: vec3<f32> = vec3(0f);

    let _e6 = v_ndc_1;
    let _e13 = v_ndc_1;
    uv = vec2<f32>(((_e6.x * 0.5f) + 0.5f), (0.5f - (_e13.y * 0.5f)));
    let _e20 = global.texel_scatter;
    let _e22 = global.texel_scatter;
    t = (_e20.xy * _e22.z);
    let _e29 = s;
    let _e30 = uv;
    let _e31 = t;
    let _e34 = t;
    let _e39 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e30 + vec2<f32>(-(_e31.x), -(_e34.y))));
    s = (_e29 + (_e39.xyz * 1f));
    let _e44 = s;
    let _e45 = uv;
    let _e47 = t;
    let _e52 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e45 + vec2<f32>(0f, -(_e47.y))));
    s = (_e44 + (_e52.xyz * 2f));
    let _e57 = s;
    let _e58 = uv;
    let _e59 = t;
    let _e61 = t;
    let _e66 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e58 + vec2<f32>(_e59.x, -(_e61.y))));
    s = (_e57 + (_e66.xyz * 1f));
    let _e71 = s;
    let _e72 = uv;
    let _e73 = t;
    let _e79 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e72 + vec2<f32>(-(_e73.x), 0f)));
    s = (_e71 + (_e79.xyz * 2f));
    let _e84 = s;
    let _e85 = uv;
    let _e86 = textureSample(zengy_u_src_image, zengy_u_src_sampler, _e85);
    s = (_e84 + (_e86.xyz * 4f));
    let _e91 = s;
    let _e92 = uv;
    let _e93 = t;
    let _e98 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e92 + vec2<f32>(_e93.x, 0f)));
    s = (_e91 + (_e98.xyz * 2f));
    let _e103 = s;
    let _e104 = uv;
    let _e105 = t;
    let _e108 = t;
    let _e112 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e104 + vec2<f32>(-(_e105.x), _e108.y)));
    s = (_e103 + (_e112.xyz * 1f));
    let _e117 = s;
    let _e118 = uv;
    let _e120 = t;
    let _e124 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e118 + vec2<f32>(0f, _e120.y)));
    s = (_e117 + (_e124.xyz * 2f));
    let _e129 = s;
    let _e130 = uv;
    let _e131 = t;
    let _e133 = t;
    let _e137 = textureSample(zengy_u_src_image, zengy_u_src_sampler, (_e130 + vec2<f32>(_e131.x, _e133.y)));
    s = (_e129 + (_e137.xyz * 1f));
    let _e142 = s;
    let _e145 = (_e142 / vec3(16f));
    frag_color = vec4<f32>(_e145.x, _e145.y, _e145.z, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e13 = frag_color;
    return FragmentOutput(_e13);
}
