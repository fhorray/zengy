// 2D textured/colored batch shader. Vertex positions are physical pixels (origin top-left); the viewport
// uniform converts them to clip space, matching the legacy `textured.vert` behavior.

struct Viewport {
    size: vec4<f32>, // x = width, y = height
};

@group(0) @binding(0) var<uniform> viewport: Viewport;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct VsIn {
    @location(0) pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    let w = max(viewport.size.x, 1.0);
    let h = max(viewport.size.y, 1.0);
    let ndc = vec2<f32>((in.pos.x / w) * 2.0 - 1.0, 1.0 - (in.pos.y / h) * 2.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, in.uv) * in.color;
}
