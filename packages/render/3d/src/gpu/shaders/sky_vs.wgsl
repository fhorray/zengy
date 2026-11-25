// Ported from sky.vert (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct VertexOutput {
    @location(0) v_ndc: vec2<f32>,
    @builtin(position) gl_Position: vec4<f32>,
}

var<private> v_ndc: vec2<f32>;
var<private> gl_VertexIndex_1: u32;
var<private> gl_Position: vec4<f32>;

fn main_1() {
    var pos: vec2<f32>;

    let _e2 = gl_VertexIndex_1;
    let _e9 = gl_VertexIndex_1;
    pos = ((vec2<f32>(f32(((_e2 << 1u) & 2u)), f32((_e9 & 2u))) * 2f) - vec2(1f));
    let _e22 = pos;
    v_ndc = _e22;
    let _e24 = pos;
    gl_Position = vec4<f32>(_e24.x, _e24.y, 1f, 1f);
    return;
}

@vertex 
fn main(@builtin(vertex_index) gl_VertexIndex: u32) -> VertexOutput {
    gl_VertexIndex_1 = gl_VertexIndex;
    main_1();
    let _e5 = v_ndc;
    let _e7 = gl_Position;
    return VertexOutput(_e5, _e7);
}
