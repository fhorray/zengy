// Ported from shadow.vert (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct ShadowUniforms {
    light_mvp: mat4x4<f32>,
}

struct VertexOutput {
    @builtin(position) @invariant gl_Position: vec4<f32>,
    @location(0) v_uv: vec2<f32>,
}

var<private> in_pos_1: vec3<f32>;
var<private> in_normal_1: vec3<f32>;
var<private> in_uv_1: vec2<f32>;
@group(1) @binding(0) 
var<uniform> global: ShadowUniforms;
var<private> gl_Position: vec4<f32>;
var<private> v_uv: vec2<f32>;

fn main_1() {
    let _e7 = in_uv_1;
    v_uv = _e7;
    let _e8 = global.light_mvp;
    let _e9 = in_pos_1;
    gl_Position = (_e8 * vec4<f32>(_e9.x, _e9.y, _e9.z, 1f));
    return;
}

@vertex 
fn main(@location(0) in_pos: vec3<f32>, @location(1) in_normal: vec3<f32>, @location(2) in_uv: vec2<f32>) -> VertexOutput {
    in_pos_1 = in_pos;
    in_normal_1 = in_normal;
    in_uv_1 = in_uv;
    main_1();
    let _e18 = gl_Position;
    let _e20 = v_uv;
    return VertexOutput(_e18, _e20);
}
