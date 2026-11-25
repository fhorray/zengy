// Ported from pbr.vert (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct PbrVertUniforms {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    mvp: mat4x4<f32>,
    light_vp: array<mat4x4<f32>, 4>,
    shadow_offset: vec4<f32>,
    cascade_texel: vec4<f32>,
    to_sun: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) @invariant gl_Position: vec4<f32>,
    @location(0) v_world_pos: vec3<f32>,
    @location(1) v_world_normal: vec3<f32>,
    @location(2) v_uv: vec2<f32>,
    @location(3) v_light_pos: vec4<f32>,
    @location(4) v_light_pos_1: vec4<f32>,
    @location(5) v_light_pos_2: vec4<f32>,
    @location(6) v_light_pos_3: vec4<f32>,
}

var<private> in_pos_1: vec3<f32>;
var<private> in_normal_1: vec3<f32>;
var<private> in_uv_1: vec2<f32>;
@group(1) @binding(0) 
var<uniform> global: PbrVertUniforms;
var<private> gl_Position: vec4<f32>;
var<private> v_world_pos: vec3<f32>;
var<private> v_world_normal: vec3<f32>;
var<private> v_uv: vec2<f32>;
var<private> v_light_pos: array<vec4<f32>, 4>;

fn main_1() {
    var wp: vec4<f32>;
    var n_dot_l: f32;
    var slope: f32;
    var i: i32 = 0i;
    var offset: vec3<f32>;

    let _e22 = global.model;
    let _e23 = in_pos_1;
    wp = (_e22 * vec4<f32>(_e23.x, _e23.y, _e23.z, 1f));
    let _e31 = wp;
    v_world_pos = _e31.xyz;
    let _e33 = global.normal_matrix;
    let _e43 = in_normal_1;
    v_world_normal = normalize((mat3x3<f32>(_e33[0].xyz, _e33[1].xyz, _e33[2].xyz) * _e43));
    let _e46 = in_uv_1;
    v_uv = _e46;
    let _e47 = v_world_normal;
    let _e48 = global.to_sun;
    n_dot_l = clamp(dot(_e47, _e48.xyz), 0f, 1f);
    let _e56 = n_dot_l;
    let _e57 = n_dot_l;
    slope = sqrt(max((1f - (_e56 * _e57)), 0f));
    loop {
        let _e66 = i;
        if !((_e66 < 4i)) {
            break;
        }
        {
            let _e73 = v_world_normal;
            let _e74 = global.shadow_offset;
            let _e76 = i;
            let _e78 = global.cascade_texel[_e76];
            let _e80 = slope;
            offset = (_e73 * ((_e74.x * _e78) * _e80));
            let _e84 = i;
            let _e86 = i;
            let _e88 = global.light_vp[_e86];
            let _e89 = wp;
            let _e91 = offset;
            let _e92 = (_e89.xyz + _e91);
            v_light_pos[_e84] = (_e88 * vec4<f32>(_e92.x, _e92.y, _e92.z, 1f));
        }
        continuing {
            let _e70 = i;
            i = (_e70 + 1i);
        }
    }
    let _e99 = global.mvp;
    let _e100 = in_pos_1;
    gl_Position = (_e99 * vec4<f32>(_e100.x, _e100.y, _e100.z, 1f));
    return;
}

@vertex 
fn main(@location(0) in_pos: vec3<f32>, @location(1) in_normal: vec3<f32>, @location(2) in_uv: vec2<f32>) -> VertexOutput {
    in_pos_1 = in_pos;
    in_normal_1 = in_normal;
    in_uv_1 = in_uv;
    main_1();
    let _e36 = gl_Position;
    let _e38 = v_world_pos;
    let _e40 = v_world_normal;
    let _e42 = v_uv;
    let _e45 = v_light_pos[0];
    let _e47 = v_light_pos[1];
    let _e49 = v_light_pos[2];
    let _e51 = v_light_pos[3];
    return VertexOutput(_e36, _e38, _e40, _e42, _e45, _e47, _e49, _e51);
}
