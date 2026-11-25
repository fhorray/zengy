// Ported from froxel_integrate.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct FroxelIntegrateParams {
    inv_view_proj: mat4x4<f32>,
    cam_max: vec4<f32>,
    dimensions: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
var<private> frag_color: vec4<f32>;
@group(0) @binding(0) 
var zengy_u_froxels_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_froxels_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: FroxelIntegrateParams;

fn boundary(k: f32, count: f32) -> f32 {
    var k_1: f32;
    var count_1: f32;

    k_1 = k;
    count_1 = count;
    let _e16 = global.cam_max;
    let _e19 = k_1;
    let _e21 = count_1;
    return ((_e16.w * (exp2(((4f * _e19) / _e21)) - 1f)) / 15f);
}

fn main_1() {
    var uv: vec2<f32>;
    var d: f32;
    var h: vec4<f32>;
    var local: f32;
    var maxDist: f32;
    var T: f32 = 1f;
    var L: vec3<f32> = vec3(0f);
    var count_2: i32;
    var xy: vec2<f32>;
    var density: f32;
    var i: i32 = 0i;
    var nearD: f32;
    var farD: f32;
    var len: f32;
    var atlasUV: vec2<f32>;
    var source: vec3<f32>;
    var stepT: f32;
    var local_1: f32;
    var integral: f32;

    let _e12 = v_ndc_1;
    let _e19 = v_ndc_1;
    uv = vec2<f32>(((_e12.x * 0.5f) + 0.5f), (0.5f - (_e19.y * 0.5f)));
    let _e26 = uv;
    let _e28 = textureSampleLevel(zengy_u_depth_image, zengy_u_depth_sampler, _e26, 0f);
    d = _e28.x;
    let _e31 = global.inv_view_proj;
    let _e32 = v_ndc_1;
    let _e33 = d;
    h = (_e31 * vec4<f32>(_e32.x, _e32.y, _e33, 1f));
    let _e40 = d;
    if (_e40 >= 0.9999f) {
        let _e43 = global.cam_max;
        local = _e43.w;
    } else {
        let _e45 = h;
        let _e47 = h;
        let _e53 = global.cam_max;
        let _e57 = global.cam_max;
        local = min(length(((_e45.xyz / vec3(max(_e47.w, 0.00001f))) - _e53.xyz)), _e57.w);
    }
    let _e61 = local;
    maxDist = _e61;
    let _e69 = global.dimensions;
    count_2 = clamp(i32(_e69.z), 1i, 64i);
    let _e76 = uv;
    let _e77 = global.dimensions;
    let _e82 = global.dimensions;
    xy = clamp((_e76 * _e77.xy), vec2(0.5f), (_e82.xy - vec2(0.5f)));
    let _e89 = global.dimensions;
    density = max(_e89.w, 0f);
    loop {
        let _e96 = i;
        let _e97 = count_2;
        if !((_e96 < _e97)) {
            break;
        }
        {
            let _e103 = i;
            let _e105 = count_2;
            let _e107 = boundary(f32(_e103), f32(_e105));
            nearD = _e107;
            let _e109 = nearD;
            let _e110 = maxDist;
            let _e112 = T;
            if ((_e109 >= _e110) || (_e112 < 0.005f)) {
                break;
            }
            let _e116 = i;
            let _e120 = count_2;
            let _e122 = boundary(f32((_e116 + 1i)), f32(_e120));
            farD = _e122;
            let _e124 = maxDist;
            let _e125 = farD;
            let _e127 = nearD;
            len = (min(_e124, _e125) - _e127);
            let _e130 = xy;
            let _e132 = global.dimensions;
            let _e135 = xy;
            let _e137 = i;
            let _e139 = global.dimensions;
            let _e143 = global.dimensions;
            let _e145 = count_2;
            atlasUV = vec2<f32>((_e130.x / _e132.x), ((_e135.y + (f32(_e137) * _e139.y)) / (_e143.y * f32(_e145))));
            let _e151 = atlasUV;
            let _e153 = textureSampleLevel(zengy_u_froxels_image, zengy_u_froxels_sampler, _e151, 0f);
            source = _e153.xyz;
            let _e156 = density;
            let _e158 = len;
            stepT = exp((-(_e156) * _e158));
            let _e162 = density;
            let _e163 = len;
            if ((_e162 * _e163) > 0.0001f) {
                let _e168 = stepT;
                let _e170 = density;
                local_1 = ((1f - _e168) / _e170);
            } else {
                let _e172 = len;
                local_1 = _e172;
            }
            let _e174 = local_1;
            integral = _e174;
            let _e176 = L;
            let _e177 = T;
            let _e178 = source;
            let _e180 = integral;
            L = (_e176 + ((_e177 * _e178) * _e180));
            let _e183 = T;
            let _e184 = stepT;
            T = (_e183 * _e184);
        }
        continuing {
            let _e100 = i;
            i = (_e100 + 1i);
        }
    }
    let _e186 = L;
    let _e193 = clamp(_e186, vec3(0f), vec3(65000f));
    let _e194 = maxDist;
    frag_color = vec4<f32>(_e193.x, _e193.y, _e193.z, _e194);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e21 = frag_color;
    return FragmentOutput(_e21);
}
