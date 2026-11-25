// Ported from volumetric_composite.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct VolCompositeParams {
    inv_view_proj: mat4x4<f32>,
    cam_pos: vec4<f32>,
    vol_size_dist: vec4<f32>,
    fog_color_density: vec4<f32>,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

var<private> v_ndc_1: vec2<f32>;
@group(0) @binding(0) 
var zengy_u_vol_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_vol_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<uniform> global: VolCompositeParams;
var<private> frag_color: vec4<f32>;

fn sceneDistance(ndc: vec2<f32>, d: f32, max_d: f32, cam: vec3<f32>) -> f32 {
    var ndc_1: vec2<f32>;
    var d_1: f32;
    var max_d_1: f32;
    var cam_1: vec3<f32>;
    var wp4_: vec4<f32>;
    var wp: vec3<f32>;

    ndc_1 = ndc;
    d_1 = d;
    max_d_1 = max_d;
    cam_1 = cam;
    let _e22 = d_1;
    if (_e22 >= 0.9999f) {
        let _e25 = max_d_1;
        return _e25;
    }
    let _e26 = global.inv_view_proj;
    let _e27 = ndc_1;
    let _e28 = d_1;
    wp4_ = (_e26 * vec4<f32>(_e27.x, _e27.y, _e28, 1f));
    let _e35 = wp4_;
    let _e37 = wp4_;
    wp = (_e35.xyz / vec3(max(_e37.w, 0.00001f)));
    let _e44 = wp;
    let _e45 = cam_1;
    let _e48 = max_d_1;
    return min(length((_e44 - _e45)), _e48);
}

fn main_1() {
    var uv: vec2<f32>;
    var max_d_2: f32;
    var d_2: f32;
    var dist_here: f32;
    var local: f32;
    var T: f32;
    var size: vec2<f32>;
    var max_texel: vec2<i32>;
    var q: vec2<f32>;
    var base: vec2<i32>;
    var f: vec2<f32>;
    var acc: vec3<f32> = vec3(0f);
    var wsum: f32 = 0f;
    var k: i32 = 0i;
    var o: vec2<i32>;
    var t: vec2<i32>;
    var s: vec4<f32>;
    var local_1: f32;
    var wx: f32;
    var local_2: f32;
    var wy: f32;
    var rel: f32;
    var w: f32;
    var scatter: vec3<f32>;
    var nearest_t: vec2<i32>;

    let _e14 = v_ndc_1;
    let _e21 = v_ndc_1;
    uv = vec2<f32>(((_e14.x * 0.5f) + 0.5f), (0.5f - (_e21.y * 0.5f)));
    let _e28 = global.vol_size_dist;
    max_d_2 = _e28.z;
    let _e31 = uv;
    let _e32 = textureSample(zengy_u_depth_image, zengy_u_depth_sampler, _e31);
    d_2 = _e32.x;
    let _e35 = v_ndc_1;
    let _e36 = d_2;
    let _e37 = max_d_2;
    let _e38 = global.cam_pos;
    let _e40 = sceneDistance(_e35, _e36, _e37, _e38.xyz);
    dist_here = _e40;
    let _e42 = d_2;
    if (_e42 >= 0.9999f) {
        local = 1f;
    } else {
        let _e46 = global.fog_color_density;
        let _e51 = dist_here;
        local = exp((-(max(_e46.w, 0f)) * max(_e51, 0f)));
    }
    let _e57 = local;
    T = _e57;
    let _e59 = global.vol_size_dist;
    if (_e59.w < 0.5f) {
        {
            let _e63 = T;
            let _e64 = vec3(_e63);
            frag_color = vec4<f32>(_e64.x, _e64.y, _e64.z, 1f);
            return;
        }
    }
    let _e70 = global.vol_size_dist;
    size = _e70.xy;
    let _e73 = size;
    max_texel = (vec2<i32>(_e73) - vec2(1i));
    let _e79 = uv;
    let _e80 = size;
    q = ((_e79 * _e80) - vec2(0.5f));
    let _e86 = q;
    base = vec2<i32>(floor(_e86));
    let _e90 = q;
    let _e91 = base;
    f = (_e90 - vec2<f32>(_e91));
    loop {
        let _e102 = k;
        if !((_e102 < 4i)) {
            break;
        }
        {
            let _e109 = k;
            let _e112 = k;
            o = vec2<i32>((_e109 & 1i), (_e112 >> 1u));
            let _e118 = base;
            let _e119 = o;
            let _e123 = max_texel;
            t = clamp((_e118 + _e119), vec2(0i), _e123);
            let _e126 = t;
            let _e128 = textureLoad(zengy_u_vol_image, _e126, 0i);
            s = _e128;
            let _e130 = k;
            if ((_e130 & 1i) == 0i) {
                let _e136 = f;
                local_1 = (1f - _e136.x);
            } else {
                let _e139 = f;
                local_1 = _e139.x;
            }
            let _e142 = local_1;
            wx = _e142;
            let _e144 = k;
            if ((_e144 >> 1u) == 0i) {
                let _e151 = f;
                local_2 = (1f - _e151.y);
            } else {
                let _e154 = f;
                local_2 = _e154.y;
            }
            let _e157 = local_2;
            wy = _e157;
            let _e159 = s;
            let _e161 = dist_here;
            let _e164 = dist_here;
            rel = (abs((_e159.w - _e161)) / max(_e164, 0.5f));
            let _e169 = wx;
            let _e170 = wy;
            let _e172 = rel;
            let _e174 = rel;
            w = ((_e169 * _e170) * exp(((-(_e172) * _e174) * 64f)));
            let _e181 = acc;
            let _e182 = s;
            let _e184 = w;
            acc = (_e181 + (_e182.xyz * _e184));
            let _e187 = wsum;
            let _e188 = w;
            wsum = (_e187 + _e188);
        }
        continuing {
            let _e106 = k;
            k = (_e106 + 1i);
        }
    }
    let _e190 = acc;
    let _e191 = wsum;
    scatter = (_e190 / vec3(max(_e191, 0.00001f)));
    let _e197 = wsum;
    if (_e197 < 0.0001f) {
        {
            let _e200 = uv;
            let _e201 = size;
            let _e207 = max_texel;
            nearest_t = clamp(vec2<i32>(floor((_e200 * _e201))), vec2(0i), _e207);
            let _e210 = nearest_t;
            let _e212 = textureLoad(zengy_u_vol_image, _e210, 0i);
            scatter = _e212.xyz;
        }
    }
    let _e214 = scatter;
    let _e215 = global.cam_pos;
    let _e217 = (_e214 * _e215.w);
    frag_color = vec4<f32>(_e217.x, _e217.y, _e217.z, 0f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    main_1();
    let _e23 = frag_color;
    return FragmentOutput(_e23);
}
