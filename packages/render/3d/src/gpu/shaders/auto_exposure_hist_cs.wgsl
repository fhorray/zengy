// Luminance histogram for automatic exposure (hand port of auto_exposure_hist.comp: Naga's GLSL front end has no
// atomicAdd). Bin 0 is underflow/black, bins 1..62 are equal-width log intervals, bin 63 is overflow. The adaptation
// shader uses the same convention.
struct HistogramBuffer {
    bins: array<atomic<u32>, 64>,
    adapted_ev100: f32,
    target_ev100: f32,
}

struct AutoExpParams {
    range_params: vec4<f32>,    // min_log2, inverse log range, sample-grid width, height
    metering_params: vec4<f32>, // x = center weighting strength, y = subpixel phase X, z = phase Y, w = maximum integer weight
}

@group(0) @binding(0) var hdr: texture_2d<f32>;
@group(1) @binding(0) var<storage, read_write> histogram: HistogramBuffer;
@group(2) @binding(0) var<uniform> params: AutoExpParams;

var<workgroup> local_bins: array<atomic<u32>, 64>;

fn is_finite_value(v: f32) -> bool {
    // IEEE-754: NaN and infinity have an all-ones exponent. WGSL has no predicate for them.
    return (bitcast<u32>(v) & 0x7f800000u) != 0x7f800000u;
}

@compute @workgroup_size(16, 16, 1)
fn main(@builtin(local_invocation_index) tid: u32, @builtin(global_invocation_id) gid: vec3<u32>) {
    if (tid < 64u) {
        atomicStore(&local_bins[tid], 0u);
    }
    workgroupBarrier();

    if (gid.x < u32(params.range_params.z) && gid.y < u32(params.range_params.w)) {
        // Stratify over the actual HDR image rather than averaging away small highlights.
        let uv = (vec2<f32>(gid.xy) + params.metering_params.yz) / params.range_params.zw;
        let size = vec2<i32>(textureDimensions(hdr, 0));
        let pixel = clamp(vec2<i32>(uv * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
        let col = textureLoad(hdr, pixel, 0).rgb;
        if (is_finite_value(col.x) && is_finite_value(col.y) && is_finite_value(col.z)) {
            let lum = dot(max(col, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
            let min_log = params.range_params.x;
            let log_lum = log2(max(lum, 1e-30));
            let t = (log_lum - min_log) * params.range_params.y;
            var bin = 0u;
            if (lum > 0.0 && t > 0.0) {
                if (t >= 1.0) {
                    bin = 63u;
                } else {
                    bin = min(u32(t * 62.0) + 1u, 62u);
                }
            }
            var weight = 1u;
            if (params.metering_params.x > 0.0 && params.metering_params.w > 1.0) {
                let delta = (uv - vec2<f32>(0.5)) * 2.0;
                let center = exp(-2.0 * dot(delta, delta));
                weight = u32(round(1.0 + (params.metering_params.w - 1.0) * params.metering_params.x * center));
            }
            atomicAdd(&local_bins[bin], weight);
        }
    }
    workgroupBarrier();
    if (tid < 64u) {
        let count = atomicLoad(&local_bins[tid]);
        if (count > 0u) {
            atomicAdd(&histogram.bins[tid], count);
        }
    }
}
