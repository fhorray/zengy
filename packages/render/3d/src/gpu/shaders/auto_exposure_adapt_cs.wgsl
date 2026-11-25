// Ported from auto_exposure_adapt.comp (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct HistogramBuffer {
    bins: array<u32, 64>,
    adapted_ev100_: f32,
    target_ev100_: f32,
}

struct AdaptParams {
    ev_bounds: vec4<f32>,
    speed_dt: vec4<f32>,
    hist_range: vec4<f32>,
    physical_params: vec4<f32>,
}

@group(1) @binding(0) 
var u_exposure_out: texture_storage_2d<r32float,write>;
@group(1) @binding(1) 
var<storage, read_write> global: HistogramBuffer;
@group(2) @binding(0) 
var<uniform> global_1: AdaptParams;
var<workgroup> s_bins: array<u32, 64>;
var<private> gl_LocalInvocationIndex_1: u32;

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

fn finiteOr(x: f32, fallback: f32) -> f32 {
    var x_1: f32;
    var fallback_1: f32;
    var local: f32;

    x_1 = x;
    fallback_1 = fallback;
    let _e20 = x_1;
    let _e21 = zy_isnan(_e20);
    let _e22 = x_1;
    let _e23 = zy_isinf(_e22);
    if (_e21 || _e23) {
        let _e25 = fallback_1;
        local = _e25;
    } else {
        let _e26 = x_1;
        local = _e26;
    }
    let _e28 = local;
    return _e28;
}

fn adaptEv(current: f32, target_: f32, speed: f32, dt: f32, transition: f32) -> f32 {
    var current_1: f32;
    var target_1: f32;
    var speed_1: f32;
    var dt_1: f32;
    var transition_1: f32;
    var distance: f32;
    var linear_time: f32;
    var local_1: f32;
    var remaining: f32;

    current_1 = current;
    target_1 = target_;
    speed_1 = speed;
    dt_1 = dt;
    transition_1 = transition;
    let _e26 = target_1;
    let _e27 = current_1;
    distance = abs((_e26 - _e27));
    let _e31 = distance;
    let _e34 = speed_1;
    let _e38 = dt_1;
    if (((_e31 <= 0.00001f) || (_e34 <= 0f)) || (_e38 <= 0f)) {
        let _e42 = current_1;
        return _e42;
    }
    let _e43 = transition_1;
    if (_e43 <= 0f) {
        {
            let _e46 = current_1;
            let _e47 = target_1;
            let _e49 = speed_1;
            let _e51 = dt_1;
            return mix(_e46, _e47, (1f - exp((-(_e49) * _e51))));
        }
    }
    let _e56 = distance;
    let _e57 = transition_1;
    let _e61 = speed_1;
    linear_time = (max((_e56 - _e57), 0f) / _e61);
    let _e64 = dt_1;
    let _e65 = linear_time;
    if (_e64 < _e65) {
        let _e67 = distance;
        let _e68 = speed_1;
        let _e69 = dt_1;
        local_1 = (_e67 - (_e68 * _e69));
    } else {
        let _e72 = distance;
        let _e73 = transition_1;
        let _e75 = speed_1;
        let _e77 = dt_1;
        let _e78 = linear_time;
        let _e81 = transition_1;
        local_1 = (min(_e72, _e73) * exp(((-(_e75) * (_e77 - _e78)) / _e81)));
    }
    let _e86 = local_1;
    remaining = _e86;
    let _e88 = target_1;
    let _e89 = current_1;
    let _e90 = target_1;
    let _e93 = remaining;
    return (_e88 + (sign((_e89 - _e90)) * _e93));
}

fn main_1() {
    var idx: u32;
    var ev_a: f32;
    var ev_b: f32;
    var ev_min: f32;
    var ev_max: f32;
    var reset: bool;
    var prev: f32;
    var total: f32 = 0f;
    var i: u32 = 0u;
    var local_2: f32;
    var a: f32;
    var b: f32;
    var low: f32;
    var high: f32;
    var low_count: f32;
    var high_count: f32;
    var accum: f32 = 0f;
    var weighted_sum: f32 = 0f;
    var weight_total: f32 = 0f;
    var i_1: u32 = 0u;
    var next_acc: f32;
    var w: f32;
    var local_3: f32;
    var local_4: f32;
    var t: f32;
    var local_5: f32;
    var avg_log2_: f32;
    var compensation: f32;
    var local_6: f32;
    var metered_ev: f32;
    var target_2: f32;
    var local_7: f32;
    var speed_2: f32;
    var dt_2: f32;
    var transition_2: f32;
    var local_8: f32;
    var next_ev: f32;

    let _e17 = gl_LocalInvocationIndex_1;
    idx = _e17;
    let _e19 = idx;
    let _e21 = idx;
    let _e23 = global.bins[_e21];
    s_bins[_e19] = _e23;
    let _e24 = idx;
    global.bins[_e24] = 0u;
    storageBarrier();
    workgroupBarrier();
    workgroupBarrier();
    textureBarrier();
    let _e27 = idx;
    if (_e27 != 0u) {
        return;
    }
    let _e30 = global_1.ev_bounds;
    let _e34 = finiteOr(_e30.x, -4f);
    ev_a = clamp(_e34, -32f, 32f);
    let _e40 = global_1.ev_bounds;
    let _e43 = finiteOr(_e40.y, 8f);
    ev_b = clamp(_e43, -32f, 32f);
    let _e49 = ev_a;
    let _e50 = ev_b;
    ev_min = min(_e49, _e50);
    let _e53 = ev_a;
    let _e54 = ev_b;
    ev_max = max(_e53, _e54);
    let _e57 = global_1.hist_range;
    reset = (_e57.z > 1.5f);
    let _e62 = global.adapted_ev100_;
    let _e64 = finiteOr(_e62, 0f);
    let _e65 = ev_min;
    let _e66 = ev_max;
    prev = clamp(_e64, _e65, _e66);
    loop {
        let _e73 = i;
        if !((_e73 < 64u)) {
            break;
        }
        let _e80 = total;
        let _e81 = i;
        let _e83 = s_bins[_e81];
        total = (_e80 + f32(_e83));
        continuing {
            let _e77 = i;
            i = (_e77 + 1u);
        }
    }
    let _e86 = total;
    if (_e86 <= 0f) {
        {
            let _e89 = reset;
            if _e89 {
                let _e90 = global_1.physical_params;
                if (_e90.x > 0.5f) {
                    let _e94 = global_1.physical_params;
                    let _e97 = finiteOr(_e94.z, 0f);
                    local_2 = _e97;
                } else {
                    local_2 = 0f;
                }
                let _e100 = local_2;
                let _e101 = ev_min;
                let _e102 = ev_max;
                prev = clamp(_e100, _e101, _e102);
            }
            let _e104 = prev;
            global.adapted_ev100_ = _e104;
            let _e105 = prev;
            global.target_ev100_ = _e105;
            let _e108 = prev;
            textureStore(u_exposure_out, vec2(0i), vec4<f32>(_e108, 0f, 0f, 1f));
            return;
        }
    }
    let _e113 = global_1.ev_bounds;
    let _e116 = finiteOr(_e113.z, 0.1f);
    a = clamp(_e116, 0f, 1f);
    let _e121 = global_1.ev_bounds;
    let _e124 = finiteOr(_e121.w, 0.9f);
    b = clamp(_e124, 0f, 1f);
    let _e129 = a;
    let _e130 = b;
    low = min(_e129, _e130);
    let _e133 = a;
    let _e134 = b;
    high = max(_e133, _e134);
    let _e137 = high;
    let _e138 = low;
    if ((_e137 - _e138) < 0.001f) {
        {
            low = 0.1f;
            high = 0.9f;
        }
    }
    let _e144 = total;
    let _e145 = low;
    low_count = (_e144 * _e145);
    let _e148 = total;
    let _e149 = high;
    high_count = (_e148 * _e149);
    loop {
        let _e160 = i_1;
        if !((_e160 < 64u)) {
            break;
        }
        {
            let _e167 = accum;
            let _e168 = i_1;
            let _e170 = s_bins[_e168];
            next_acc = (_e167 + f32(_e170));
            let _e175 = next_acc;
            let _e176 = high_count;
            let _e178 = accum;
            let _e179 = low_count;
            w = max(0f, (min(_e175, _e176) - max(_e178, _e179)));
            let _e184 = i_1;
            if (_e184 == 0u) {
                local_4 = 0f;
            } else {
                let _e188 = i_1;
                if (_e188 == 63u) {
                    local_3 = 1f;
                } else {
                    let _e192 = i_1;
                    local_3 = ((f32(_e192) - 0.5f) / 62f);
                }
                let _e199 = local_3;
                local_4 = _e199;
            }
            let _e201 = local_4;
            t = _e201;
            let _e203 = weighted_sum;
            let _e204 = global_1.hist_range;
            let _e206 = t;
            let _e207 = global_1.hist_range;
            let _e211 = w;
            weighted_sum = (_e203 + ((_e204.x + (_e206 * _e207.y)) * _e211));
            let _e214 = weight_total;
            let _e215 = w;
            weight_total = (_e214 + _e215);
            let _e217 = next_acc;
            accum = _e217;
        }
        continuing {
            let _e164 = i_1;
            i_1 = (_e164 + 1u);
        }
    }
    let _e218 = weight_total;
    if (_e218 > 0f) {
        let _e221 = weighted_sum;
        let _e222 = weight_total;
        local_5 = (_e221 / _e222);
    } else {
        local_5 = -2.473931f;
    }
    let _e227 = local_5;
    avg_log2_ = _e227;
    let _e229 = global_1.speed_dt;
    let _e232 = finiteOr(_e229.w, 0f);
    compensation = clamp(_e232, -32f, 32f);
    let _e238 = global_1.physical_params;
    if (_e238.x > 0.5f) {
        let _e242 = avg_log2_;
        let _e243 = global_1.physical_params;
        local_6 = ((_e242 + _e243.y) + 3f);
    } else {
        let _e251 = avg_log2_;
        local_6 = (_e251 - -2.473931f);
    }
    let _e256 = local_6;
    metered_ev = _e256;
    let _e258 = metered_ev;
    let _e259 = compensation;
    let _e261 = ev_min;
    let _e262 = ev_max;
    target_2 = clamp((_e258 - _e259), _e261, _e262);
    let _e265 = target_2;
    global.target_ev100_ = _e265;
    let _e266 = target_2;
    let _e267 = prev;
    if (_e266 < _e267) {
        let _e269 = global_1.speed_dt;
        local_7 = _e269.x;
    } else {
        let _e271 = global_1.speed_dt;
        local_7 = _e271.y;
    }
    let _e274 = local_7;
    let _e276 = finiteOr(_e274, 1f);
    speed_2 = clamp(_e276, 0f, 64f);
    let _e281 = global_1.speed_dt;
    let _e284 = finiteOr(_e281.z, 0f);
    dt_2 = clamp(_e284, 0f, 0.1f);
    let _e289 = global_1.hist_range;
    let _e292 = finiteOr(_e289.w, 0f);
    transition_2 = clamp(_e292, 0f, 16f);
    let _e297 = reset;
    if _e297 {
        let _e298 = target_2;
        local_8 = _e298;
    } else {
        let _e299 = prev;
        let _e300 = target_2;
        let _e301 = speed_2;
        let _e302 = dt_2;
        let _e303 = transition_2;
        let _e304 = adaptEv(_e299, _e300, _e301, _e302, _e303);
        local_8 = _e304;
    }
    let _e306 = local_8;
    next_ev = _e306;
    let _e308 = next_ev;
    global.adapted_ev100_ = _e308;
    let _e311 = next_ev;
    textureStore(u_exposure_out, vec2(0i), vec4<f32>(_e311, 0f, 0f, 1f));
    return;
}

@compute @workgroup_size(64, 1, 1) 
fn main(@builtin(local_invocation_index) gl_LocalInvocationIndex: u32) {
    gl_LocalInvocationIndex_1 = gl_LocalInvocationIndex;
    main_1();
    return;
}
