// Ported from shadow_mask.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct ShadowMaskParams {
    base_color: vec4<f32>,
    params: vec4<f32>,
}

var<private> v_uv_1: vec2<f32>;
@group(2) @binding(0) 
var zengy_u_base_color_tex_image: texture_2d<f32>;
@group(2) @binding(32) 
var zengy_u_base_color_tex_sampler: sampler;
@group(3) @binding(0) 
var<uniform> global: ShadowMaskParams;

fn main_1() {
    var alpha: f32;

    let _e7 = v_uv_1;
    let _e8 = textureSample(zengy_u_base_color_tex_image, zengy_u_base_color_tex_sampler, _e7);
    let _e10 = global.base_color;
    alpha = (_e8.w * _e10.w);
    let _e14 = alpha;
    let _e15 = global.params;
    if (_e14 < _e15.x) {
        {
            discard;
        }
    } else {
        return;
    }
}

@fragment 
fn main(@location(0) v_uv: vec2<f32>) {
    v_uv_1 = v_uv;
    main_1();
    return;
}
