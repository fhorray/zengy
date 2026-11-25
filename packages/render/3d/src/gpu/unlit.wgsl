// Unlit textured mesh shader (port of mesh_unlit.vert/frag). One uniform slot per draw via dynamic offset.
struct MeshUniforms {
    mvp: mat4x4<f32>,
    base_color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> u: MeshUniforms;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct VsIn {
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.normal = in.normal;
    out.uv = in.uv;
    out.color = u.base_color;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let t = textureSample(tex, samp, in.uv);
    let shade = 0.65 + 0.35 * clamp(dot(normalize(in.normal), normalize(vec3<f32>(0.4, 0.8, 0.5))), -1.0, 1.0);
    return vec4<f32>(t.rgb * in.color.rgb * shade, t.a * in.color.a);
}
