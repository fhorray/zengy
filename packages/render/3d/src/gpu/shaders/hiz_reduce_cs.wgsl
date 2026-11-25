// Ported from hiz_reduce.comp (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct DepthBounds {
    bounds: array<vec2<f32>>,
}

struct ReduceParams {
    src: vec4<u32>,
    dst: vec4<u32>,
}

@group(0) @binding(0) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_depth_sampler: sampler;
@group(1) @binding(0) 
var<storage, read_write> global: DepthBounds;
@group(2) @binding(0) 
var<uniform> global_1: ReduceParams;
var<private> gl_GlobalInvocationID_1: vec3<u32>;

fn zy_isnan(v: f32) -> bool {
    var v_1: f32;

    v_1 = v;
    let _e2 = v_1;
    return ((bitcast<u32>(_e2) & 2147483647u) > 2139095040u);
}

fn zy_isinf(v_2: f32) -> bool {
    var v_3: f32;

    v_3 = v_2;
    let _e2 = v_3;
    return ((bitcast<u32>(_e2) & 2147483647u) == 2139095040u);
}

fn zy_isnan_1(v_4: vec2<f32>) -> vec2<bool> {
    var v_5: vec2<f32>;

    v_5 = v_4;
    let _e2 = v_5;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_5;
    let _e7 = zy_isnan(_e5.y);
    return vec2<bool>(_e4, _e7);
}

fn zy_isinf_1(v_6: vec2<f32>) -> vec2<bool> {
    var v_7: vec2<f32>;

    v_7 = v_6;
    let _e2 = v_7;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_7;
    let _e7 = zy_isinf(_e5.y);
    return vec2<bool>(_e4, _e7);
}

fn zy_isnan_2(v_8: vec3<f32>) -> vec3<bool> {
    var v_9: vec3<f32>;

    v_9 = v_8;
    let _e2 = v_9;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_9;
    let _e7 = zy_isnan(_e5.y);
    let _e8 = v_9;
    let _e10 = zy_isnan(_e8.z);
    return vec3<bool>(_e4, _e7, _e10);
}

fn zy_isinf_2(v_10: vec3<f32>) -> vec3<bool> {
    var v_11: vec3<f32>;

    v_11 = v_10;
    let _e2 = v_11;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_11;
    let _e7 = zy_isinf(_e5.y);
    let _e8 = v_11;
    let _e10 = zy_isinf(_e8.z);
    return vec3<bool>(_e4, _e7, _e10);
}

fn zy_isnan_3(v_12: vec4<f32>) -> vec4<bool> {
    var v_13: vec4<f32>;

    v_13 = v_12;
    let _e2 = v_13;
    let _e4 = zy_isnan(_e2.x);
    let _e5 = v_13;
    let _e7 = zy_isnan(_e5.y);
    let _e8 = v_13;
    let _e10 = zy_isnan(_e8.z);
    let _e11 = v_13;
    let _e13 = zy_isnan(_e11.w);
    return vec4<bool>(_e4, _e7, _e10, _e13);
}

fn zy_isinf_3(v_14: vec4<f32>) -> vec4<bool> {
    var v_15: vec4<f32>;

    v_15 = v_14;
    let _e2 = v_15;
    let _e4 = zy_isinf(_e2.x);
    let _e5 = v_15;
    let _e7 = zy_isinf(_e5.y);
    let _e8 = v_15;
    let _e10 = zy_isinf(_e8.z);
    let _e11 = v_15;
    let _e13 = zy_isinf(_e11.w);
    return vec4<bool>(_e4, _e7, _e10, _e13);
}

fn main_1() {
    var p: vec2<u32>;
    var result: vec2<f32> = vec2<f32>(1f, 0f);
    var d: f32;
    var y: u32 = 0u;
    var x: u32;
    var q: vec2<u32>;
    var v_16: vec2<f32>;

    let _e9 = gl_GlobalInvocationID_1;
    p = _e9.xy;
    let _e12 = p;
    let _e13 = global_1.dst;
    if any((_e12 >= _e13.yz)) {
        return;
    }
    let _e21 = global_1.src;
    if (_e21.w != 0u) {
        {
            let _e25 = p;
            let _e28 = textureLoad(zengy_u_depth_image, vec2<i32>(_e25), 0i);
            d = _e28.x;
            let _e31 = d;
            let _e32 = zy_isnan(_e31);
            let _e33 = d;
            let _e34 = zy_isinf(_e33);
            if (_e32 || _e34) {
                d = 1f;
            }
            let _e37 = d;
            result = vec2(clamp(_e37, 0f, 1f));
        }
    } else {
        {
            loop {
                let _e44 = y;
                if !((_e44 < 2u)) {
                    break;
                }
                x = 0u;
                loop {
                    let _e53 = x;
                    if !((_e53 < 2u)) {
                        break;
                    }
                    {
                        let _e60 = p;
                        let _e63 = x;
                        let _e64 = y;
                        q = ((_e60 * 2u) + vec2<u32>(_e63, _e64));
                        let _e68 = q;
                        let _e69 = global_1.src;
                        if any((_e68 >= _e69.yz)) {
                            continue;
                        }
                        let _e73 = global_1.src;
                        let _e75 = q;
                        let _e77 = global_1.src;
                        let _e81 = q;
                        let _e85 = global.bounds[((_e73.x + (_e75.y * _e77.y)) + _e81.x)];
                        v_16 = _e85;
                        let _e87 = result;
                        let _e89 = v_16;
                        let _e92 = result;
                        let _e94 = v_16;
                        result = vec2<f32>(min(_e87.x, _e89.x), max(_e92.y, _e94.y));
                    }
                    continuing {
                        let _e57 = x;
                        x = (_e57 + 1u);
                    }
                }
                continuing {
                    let _e48 = y;
                    y = (_e48 + 1u);
                }
            }
        }
    }
    let _e98 = global_1.dst;
    let _e100 = p;
    let _e102 = global_1.dst;
    let _e106 = p;
    let _e110 = result;
    global.bounds[((_e98.x + (_e100.y * _e102.y)) + _e106.x)] = _e110;
    return;
}

@compute @workgroup_size(16, 16, 1) 
fn main(@builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>) {
    gl_GlobalInvocationID_1 = gl_GlobalInvocationID;
    main_1();
    return;
}
