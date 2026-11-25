// Ported from dynamic_gi.comp (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct Geometry {
    geom: array<u32>,
}

struct PreviousGrid {
    old_grid: array<u32>,
}

struct ClusterOutput {
    lighting: array<u32>,
}

struct Reservoirs {
    reservoirs: array<vec4<u32>>,
}

struct GiParams {
    counts: vec4<u32>,
    offsets: vec4<u32>,
    dispatch_info: vec4<u32>,
    light_key: vec4<u32>,
    config: vec4<f32>,
    sun_dir_int: vec4<f32>,
    sun_color: vec4<f32>,
    sky_zenith: vec4<f32>,
    sky_horizon: vec4<f32>,
    sky_ground: vec4<f32>,
    cdf: array<vec4<f32>, 64>,
}

struct Hit {
    t: f32,
    material: u32,
    normal: vec3<f32>,
    found: bool,
}

const PI: f32 = 3.1415927f;
const PROBE_WORDS: u32 = 52u;
const INVALID: u32 = 4294967295u;
const axes: array<vec3<f32>, 6> = array<vec3<f32>, 6>(vec3<f32>(1f, 0f, 0f), vec3<f32>(-1f, 0f, 0f), vec3<f32>(0f, 1f, 0f), vec3<f32>(0f, -1f, 0f), vec3<f32>(0f, 0f, 1f), vec3<f32>(0f, 0f, -1f));

@group(0) @binding(0) 
var<storage> global: Geometry;
@group(0) @binding(1) 
var<storage> global_1: PreviousGrid;
@group(1) @binding(0) 
var<storage, read_write> global_2: ClusterOutput;
@group(1) @binding(1) 
var<storage, read_write> global_3: Reservoirs;
@group(2) @binding(0) 
var<uniform> global_4: GiParams;
var<workgroup> probe_pos: vec3<f32>;
var<workgroup> probe_offset: vec3<f32>;
var<workgroup> ray_result: array<vec4<f32>, 64>;
var<workgroup> ray_direction: array<vec4<f32>, 64>;
var<private> gl_LocalInvocationIndex_1: u32;
var<private> gl_WorkGroupID_1: vec3<u32>;

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

fn finiteRgb(x: vec3<f32>) -> vec3<f32> {
    var x_1: vec3<f32>;
    var local: vec3<f32>;

    x_1 = x;
    let _e40 = x_1;
    let _e41 = zy_isnan_2(_e40);
    let _e43 = x_1;
    let _e44 = zy_isinf_2(_e43);
    if (any(_e41) || any(_e44)) {
        local = vec3(0f);
    } else {
        let _e50 = x_1;
        local = clamp(_e50, vec3(0f), vec3(1000f));
    }
    let _e59 = local;
    return _e59;
}

fn norm(x_2: vec3<f32>) -> vec3<f32> {
    var x_3: vec3<f32>;

    x_3 = x_2;
    let _e40 = x_3;
    let _e41 = x_3;
    let _e42 = x_3;
    return (_e40 * inverseSqrt(max(dot(_e41, _e42), 0.000000000001f)));
}

fn geom3_(i: u32) -> vec3<f32> {
    var i_1: u32;

    i_1 = i;
    let _e40 = i_1;
    let _e42 = global.geom[_e40];
    let _e43 = i_1;
    let _e47 = global.geom[(_e43 + 1u)];
    let _e48 = i_1;
    let _e52 = global.geom[(_e48 + 2u)];
    return bitcast<vec3<f32>>(vec3<u32>(_e42, _e47, _e52));
}

fn old4_(i_2: u32) -> vec4<f32> {
    var i_3: u32;

    i_3 = i_2;
    let _e40 = i_3;
    let _e42 = global_1.old_grid[_e40];
    let _e43 = i_3;
    let _e47 = global_1.old_grid[(_e43 + 1u)];
    let _e48 = i_3;
    let _e52 = global_1.old_grid[(_e48 + 2u)];
    let _e53 = i_3;
    let _e57 = global_1.old_grid[(_e53 + 3u)];
    return bitcast<vec4<f32>>(vec4<u32>(_e42, _e47, _e52, _e57));
}

fn light4_(i_4: u32) -> vec4<f32> {
    var i_5: u32;

    i_5 = i_4;
    let _e40 = i_5;
    let _e42 = global_2.lighting[_e40];
    let _e43 = i_5;
    let _e47 = global_2.lighting[(_e43 + 1u)];
    let _e48 = i_5;
    let _e52 = global_2.lighting[(_e48 + 2u)];
    let _e53 = i_5;
    let _e57 = global_2.lighting[(_e53 + 3u)];
    return bitcast<vec4<f32>>(vec4<u32>(_e42, _e47, _e52, _e57));
}

fn store4_(i_6: u32, v_16: vec4<f32>) {
    var i_7: u32;
    var v_17: vec4<f32>;
    var u: vec4<u32>;

    i_7 = i_6;
    v_17 = v_16;
    let _e42 = v_17;
    u = bitcast<vec4<u32>>(_e42);
    let _e45 = i_7;
    let _e47 = u;
    global_2.lighting[_e45] = _e47.x;
    let _e49 = i_7;
    let _e53 = u;
    global_2.lighting[(_e49 + 1u)] = _e53.y;
    let _e55 = i_7;
    let _e59 = u;
    global_2.lighting[(_e55 + 2u)] = _e59.z;
    let _e61 = i_7;
    let _e65 = u;
    global_2.lighting[(_e61 + 3u)] = _e65.w;
    return;
}

fn probeBase(i_8: u32) -> u32 {
    var i_9: u32;

    i_9 = i_8;
    let _e41 = i_9;
    return (8u + (PROBE_WORDS * _e41));
}

fn probeCoords(i_10: u32) -> vec3<f32> {
    var i_11: u32;

    i_11 = i_10;
    let _e40 = i_11;
    let _e43 = i_11;
    let _e48 = i_11;
    return vec3<f32>(f32((_e40 % 4u)), f32(((_e43 / 4u) % 4u)), f32((_e48 / 16u)));
}

fn sector(d: vec3<f32>) -> u32 {
    var d_1: vec3<f32>;
    var a: vec3<f32>;
    var local_1: u32;
    var local_2: u32;
    var local_3: u32;

    d_1 = d;
    let _e40 = d_1;
    a = abs(_e40);
    let _e43 = a;
    let _e45 = a;
    let _e48 = a;
    let _e50 = a;
    if ((_e43.x >= _e45.y) && (_e48.x >= _e50.z)) {
        let _e54 = d_1;
        if (_e54.x >= 0f) {
            local_1 = 0u;
        } else {
            local_1 = 1u;
        }
        let _e62 = local_1;
        return _e62;
    }
    let _e63 = a;
    let _e65 = a;
    if (_e63.y >= _e65.z) {
        let _e68 = d_1;
        if (_e68.y >= 0f) {
            local_2 = 2u;
        } else {
            local_2 = 3u;
        }
        let _e76 = local_2;
        return _e76;
    }
    let _e77 = d_1;
    if (_e77.z >= 0f) {
        local_3 = 4u;
    } else {
        local_3 = 5u;
    }
    let _e85 = local_3;
    return _e85;
}

fn rng(x_4: ptr<function, u32>) -> u32 {
    let _e39 = (*x_4);
    let _e40 = (*x_4);
    (*x_4) = (_e39 ^ (_e40 << 13u));
    let _e45 = (*x_4);
    let _e46 = (*x_4);
    (*x_4) = (_e45 ^ (_e46 >> 17u));
    let _e51 = (*x_4);
    let _e52 = (*x_4);
    (*x_4) = (_e51 ^ (_e52 << 5u));
    let _e57 = (*x_4);
    return _e57;
}

fn random(x_5: ptr<function, u32>) -> f32 {
    let _e41 = rng(x_5);
    return (f32((_e41 >> 8u)) * 0.000000059604645f);
}

fn aabb(o: vec3<f32>, d_2: vec3<f32>, mn: vec3<f32>, mx: vec3<f32>, maxT: f32, entry: ptr<function, f32>) -> bool {
    var o_1: vec3<f32>;
    var d_3: vec3<f32>;
    var mn_1: vec3<f32>;
    var mx_1: vec3<f32>;
    var maxT_1: f32;
    var lo: f32 = 0.001f;
    var hi: f32;
    var i_12: i32 = 0i;
    var a_1: f32;
    var b: f32;

    o_1 = o;
    d_3 = d_2;
    mn_1 = mn;
    mx_1 = mx;
    maxT_1 = maxT;
    let _e51 = maxT_1;
    hi = _e51;
    loop {
        let _e55 = i_12;
        if !((_e55 < 3i)) {
            break;
        }
        {
            let _e62 = i_12;
            let _e64 = d_3[_e62];
            if (abs(_e64) < 0.00000001f) {
                {
                    let _e68 = i_12;
                    let _e70 = o_1[_e68];
                    let _e71 = i_12;
                    let _e73 = mn_1[_e71];
                    let _e75 = i_12;
                    let _e77 = o_1[_e75];
                    let _e78 = i_12;
                    let _e80 = mx_1[_e78];
                    if ((_e70 < _e73) || (_e77 > _e80)) {
                        return false;
                    }
                }
            } else {
                {
                    let _e84 = i_12;
                    let _e86 = mn_1[_e84];
                    let _e87 = i_12;
                    let _e89 = o_1[_e87];
                    let _e91 = i_12;
                    let _e93 = d_3[_e91];
                    a_1 = ((_e86 - _e89) / _e93);
                    let _e96 = i_12;
                    let _e98 = mx_1[_e96];
                    let _e99 = i_12;
                    let _e101 = o_1[_e99];
                    let _e103 = i_12;
                    let _e105 = d_3[_e103];
                    b = ((_e98 - _e101) / _e105);
                    let _e108 = lo;
                    let _e109 = a_1;
                    let _e110 = b;
                    lo = max(_e108, min(_e109, _e110));
                    let _e113 = hi;
                    let _e114 = a_1;
                    let _e115 = b;
                    hi = min(_e113, max(_e114, _e115));
                    let _e118 = lo;
                    let _e119 = hi;
                    if (_e118 > _e119) {
                        return false;
                    }
                }
            }
        }
        continuing {
            let _e59 = i_12;
            i_12 = (_e59 + 1i);
        }
    }
    let _e122 = lo;
    (*entry) = _e122;
    return true;
}

fn trace(o_2: vec3<f32>, d_4: vec3<f32>, maxT_2: f32, anyHit: bool) -> Hit {
    var o_3: vec3<f32>;
    var d_5: vec3<f32>;
    var maxT_3: f32;
    var anyHit_1: bool;
    var best: Hit;
    var stack: array<u32, 64>;
    var nearStack: array<f32, 64>;
    var sp: i32 = 1i;
    var entry_1: f32;
    var index: u32;
    var base: u32;
    var first: u32;
    var n: u32;
    var i_13: u32;
    var t: u32;
    var v0_: vec3<f32>;
    var e1_: vec3<f32>;
    var e2_: vec3<f32>;
    var h: vec3<f32>;
    var determinant: f32;
    var inv: f32;
    var s: vec3<f32>;
    var u_1: f32;
    var q: vec3<f32>;
    var v_18: f32;
    var hitT: f32;
    var l: u32;
    var r: u32;
    var lb: u32;
    var rb: u32;
    var dl: f32;
    var dr: f32;
    var hl: bool;
    var hr: bool;
    var local_4: u32;
    var local_5: u32;
    var local_6: u32;
    var local_7: f32;

    o_3 = o_2;
    d_5 = d_4;
    maxT_3 = maxT_2;
    anyHit_1 = anyHit;
    let _e46 = maxT_3;
    best = Hit(_e46, INVALID, vec3<f32>(0f, 1f, 0f), false);
    let _e57 = global_4.counts;
    let _e61 = maxT_3;
    if ((_e57.x == 0u) || (_e61 <= 0.001f)) {
        let _e65 = best;
        return _e65;
    }
    let _e71 = o_3;
    let _e72 = d_5;
    let _e73 = global_4.offsets;
    let _e75 = geom3_(_e73.x);
    let _e76 = global_4.offsets;
    let _e80 = geom3_((_e76.x + 4u));
    let _e81 = maxT_3;
    let _e84 = aabb(_e71, _e72, _e75, _e80, _e81, (&entry_1));
    if !(_e84) {
        let _e86 = best;
        return _e86;
    }
    stack[0i] = 0u;
    let _e92 = entry_1;
    nearStack[0i] = _e92;
    loop {
        let _e93 = sp;
        if !((_e93 > 0i)) {
            break;
        }
        {
            let _e97 = sp;
            sp = (_e97 - 1i);
            let _e100 = sp;
            let _e102 = stack[_e100];
            index = _e102;
            let _e104 = sp;
            let _e106 = nearStack[_e104];
            let _e107 = best;
            let _e110 = index;
            let _e111 = global_4.counts;
            if ((_e106 > _e107.t) || (_e110 >= _e111.x)) {
                continue;
            }
            let _e115 = global_4.offsets;
            let _e117 = index;
            base = (_e115.x + (_e117 * 8u));
            let _e122 = base;
            let _e126 = global.geom[(_e122 + 3u)];
            first = _e126;
            let _e128 = base;
            let _e132 = global.geom[(_e128 + 7u)];
            n = _e132;
            let _e134 = n;
            if (_e134 > 0u) {
                {
                    let _e137 = first;
                    let _e138 = global_4.counts;
                    let _e141 = n;
                    let _e142 = global_4.counts;
                    let _e144 = first;
                    if ((_e137 >= _e138.y) || (_e141 > (_e142.y - _e144))) {
                        continue;
                    }
                    i_13 = 0u;
                    loop {
                        let _e150 = i_13;
                        let _e151 = n;
                        if !((_e150 < _e151)) {
                            break;
                        }
                        {
                            let _e157 = global_4.offsets;
                            let _e159 = first;
                            let _e160 = i_13;
                            t = (_e157.y + ((_e159 + _e160) * 12u));
                            let _e166 = t;
                            let _e170 = global.geom[(_e166 + 7u)];
                            if (_e170 == 0u) {
                                continue;
                            }
                            let _e173 = t;
                            let _e174 = geom3_(_e173);
                            v0_ = _e174;
                            let _e176 = t;
                            let _e179 = geom3_((_e176 + 4u));
                            let _e180 = v0_;
                            e1_ = (_e179 - _e180);
                            let _e183 = t;
                            let _e186 = geom3_((_e183 + 8u));
                            let _e187 = v0_;
                            e2_ = (_e186 - _e187);
                            let _e190 = d_5;
                            let _e191 = e2_;
                            h = cross(_e190, _e191);
                            let _e194 = e1_;
                            let _e195 = h;
                            determinant = dot(_e194, _e195);
                            let _e198 = determinant;
                            if (abs(_e198) < 0.0000001f) {
                                continue;
                            }
                            let _e203 = determinant;
                            inv = (1f / _e203);
                            let _e206 = o_3;
                            let _e207 = v0_;
                            s = (_e206 - _e207);
                            let _e210 = s;
                            let _e211 = h;
                            let _e213 = inv;
                            u_1 = (dot(_e210, _e211) * _e213);
                            let _e216 = u_1;
                            let _e219 = u_1;
                            if ((_e216 < 0f) || (_e219 > 1f)) {
                                continue;
                            }
                            let _e223 = s;
                            let _e224 = e1_;
                            q = cross(_e223, _e224);
                            let _e227 = d_5;
                            let _e228 = q;
                            let _e230 = inv;
                            v_18 = (dot(_e227, _e228) * _e230);
                            let _e233 = v_18;
                            let _e236 = u_1;
                            let _e237 = v_18;
                            if ((_e233 < 0f) || ((_e236 + _e237) > 1f)) {
                                continue;
                            }
                            let _e242 = e2_;
                            let _e243 = q;
                            let _e245 = inv;
                            hitT = (dot(_e242, _e243) * _e245);
                            let _e248 = hitT;
                            let _e251 = hitT;
                            let _e252 = best;
                            let _e256 = hitT;
                            let _e257 = zy_isnan(_e256);
                            let _e259 = hitT;
                            let _e260 = zy_isinf(_e259);
                            if ((((_e248 < 0.001f) || (_e251 > _e252.t)) || _e257) || _e260) {
                                continue;
                            }
                            let _e262 = hitT;
                            let _e263 = t;
                            let _e267 = global.geom[(_e263 + 3u)];
                            let _e268 = e1_;
                            let _e269 = e2_;
                            let _e271 = norm(cross(_e268, _e269));
                            best = Hit(_e262, _e267, _e271, true);
                            let _e274 = anyHit_1;
                            if _e274 {
                                let _e275 = best;
                                return _e275;
                            }
                        }
                        continuing {
                            let _e154 = i_13;
                            i_13 = (_e154 + 1u);
                        }
                    }
                }
            } else {
                {
                    let _e276 = first;
                    l = _e276;
                    let _e278 = l;
                    r = (_e278 + 1u);
                    let _e282 = r;
                    let _e283 = global_4.counts;
                    if (_e282 >= _e283.x) {
                        continue;
                    }
                    let _e286 = global_4.offsets;
                    let _e288 = l;
                    lb = (_e286.x + (_e288 * 8u));
                    let _e293 = global_4.offsets;
                    let _e295 = r;
                    rb = (_e293.x + (_e295 * 8u));
                    dl = 0f;
                    dr = 0f;
                    let _e306 = o_3;
                    let _e307 = d_5;
                    let _e308 = lb;
                    let _e309 = geom3_(_e308);
                    let _e310 = lb;
                    let _e313 = geom3_((_e310 + 4u));
                    let _e314 = best;
                    let _e318 = aabb(_e306, _e307, _e309, _e313, _e314.t, (&dl));
                    hl = _e318;
                    let _e320 = o_3;
                    let _e321 = d_5;
                    let _e322 = rb;
                    let _e323 = geom3_(_e322);
                    let _e324 = rb;
                    let _e327 = geom3_((_e324 + 4u));
                    let _e328 = best;
                    let _e332 = aabb(_e320, _e321, _e323, _e327, _e328.t, (&dr));
                    hr = _e332;
                    let _e334 = hl;
                    let _e335 = hr;
                    if (_e334 && _e335) {
                        {
                            let _e337 = sp;
                            if ((_e337 + 2i) > 64i) {
                                {
                                    let _e342 = anyHit_1;
                                    if _e342 {
                                        return Hit(0f, 4294967295u, vec3(0f), true);
                                    }
                                    let _e351 = best;
                                    return _e351;
                                }
                            }
                            let _e352 = sp;
                            let _e354 = dl;
                            let _e355 = dr;
                            if (_e354 <= _e355) {
                                let _e357 = r;
                                local_4 = _e357;
                            } else {
                                let _e358 = l;
                                local_4 = _e358;
                            }
                            let _e360 = local_4;
                            stack[_e352] = _e360;
                            let _e361 = sp;
                            sp = (_e361 + 1i);
                            let _e365 = dl;
                            let _e366 = dr;
                            nearStack[_e361] = max(_e365, _e366);
                            let _e368 = sp;
                            let _e370 = dl;
                            let _e371 = dr;
                            if (_e370 <= _e371) {
                                let _e373 = l;
                                local_5 = _e373;
                            } else {
                                let _e374 = r;
                                local_5 = _e374;
                            }
                            let _e376 = local_5;
                            stack[_e368] = _e376;
                            let _e377 = sp;
                            sp = (_e377 + 1i);
                            let _e381 = dl;
                            let _e382 = dr;
                            nearStack[_e377] = min(_e381, _e382);
                        }
                    } else {
                        let _e384 = hl;
                        let _e385 = hr;
                        if (_e384 || _e385) {
                            {
                                let _e387 = sp;
                                if (_e387 >= 64i) {
                                    {
                                        let _e390 = anyHit_1;
                                        if _e390 {
                                            return Hit(0f, 4294967295u, vec3(0f), true);
                                        }
                                        let _e399 = best;
                                        return _e399;
                                    }
                                }
                                let _e400 = sp;
                                let _e402 = hl;
                                if _e402 {
                                    let _e403 = l;
                                    local_6 = _e403;
                                } else {
                                    let _e404 = r;
                                    local_6 = _e404;
                                }
                                let _e406 = local_6;
                                stack[_e400] = _e406;
                                let _e407 = sp;
                                sp = (_e407 + 1i);
                                let _e411 = hl;
                                if _e411 {
                                    let _e412 = dl;
                                    local_7 = _e412;
                                } else {
                                    let _e413 = dr;
                                    local_7 = _e413;
                                }
                                let _e415 = local_7;
                                nearStack[_e407] = _e415;
                            }
                        }
                    }
                }
            }
        }
    }
    let _e416 = best;
    return _e416;
}

fn samplePrevious(p: vec3<f32>, n_1: vec3<f32>) -> vec4<f32> {
    var p_1: vec3<f32>;
    var n_2: vec3<f32>;
    var origin: vec3<f32>;
    var spacing: vec3<f32>;
    var q_1: vec3<f32>;
    var base_1: vec3<i32>;
    var f: vec3<f32>;
    var rgb: vec3<f32> = vec3(0f);
    var weights: f32 = 0f;
    var i_14: i32 = 0i;
    var o_4: vec3<i32>;
    var c: vec3<i32>;
    var index_1: u32;
    var b_1: u32;
    var off: vec4<f32>;
    var w3_: vec3<f32>;
    var w: f32;
    var delta: vec3<f32>;
    var s_1: u32;
    var mom: vec4<f32>;
    var mean: f32;
    var variance: f32;
    var excess: f32;
    var visibility: f32;
    var n2_: vec3<f32>;
    var local_8: u32;
    var local_9: u32;
    var local_10: u32;
    var rad: vec3<f32>;

    p_1 = p;
    n_2 = n_1;
    let _e43 = old4_(0u);
    origin = _e43.xyz;
    let _e47 = old4_(4u);
    spacing = _e47.xyz;
    let _e50 = spacing;
    if any((_e50 <= vec3(0.01f))) {
        return vec4(0f);
    }
    let _e58 = p_1;
    let _e59 = origin;
    let _e61 = spacing;
    q_1 = ((_e58 - _e59) / _e61);
    let _e64 = q_1;
    let _e70 = q_1;
    if (any((_e64 < vec3(-0.05f))) || any((_e70 > vec3(3.05f)))) {
        return vec4(0f);
    }
    let _e79 = q_1;
    q_1 = clamp(_e79, vec3(0f), vec3(3f));
    let _e87 = q_1;
    base_1 = min(vec3<i32>(floor(_e87)), vec3(2i));
    let _e94 = q_1;
    let _e95 = base_1;
    f = (_e94 - vec3<f32>(_e95));
    loop {
        let _e108 = i_14;
        if !((_e108 < 8i)) {
            break;
        }
        {
            let _e115 = i_14;
            let _e118 = i_14;
            let _e124 = i_14;
            o_4 = vec3<i32>((_e115 & 1i), ((_e118 >> 1u) & 1i), ((_e124 >> 2u) & 1i));
            let _e132 = base_1;
            let _e133 = o_4;
            c = (_e132 + _e133);
            let _e136 = c;
            let _e139 = c;
            let _e144 = c;
            index_1 = u32(((_e136.x + (4i * _e139.y)) + (16i * _e144.z)));
            let _e150 = index_1;
            let _e151 = probeBase(_e150);
            b_1 = _e151;
            let _e153 = b_1;
            let _e156 = old4_((_e153 + 48u));
            off = _e156;
            let _e159 = f;
            let _e162 = f;
            let _e163 = o_4;
            w3_ = mix((vec3(1f) - _e159), _e162, vec3<f32>(_e163));
            let _e167 = w3_;
            let _e169 = w3_;
            let _e172 = w3_;
            let _e175 = off;
            w = (((_e167.x * _e169.y) * _e172.z) * _e175.w);
            let _e179 = w;
            if (_e179 <= 0.00001f) {
                continue;
            }
            let _e182 = p_1;
            let _e183 = origin;
            let _e184 = c;
            let _e186 = spacing;
            let _e189 = off;
            delta = (_e182 - ((_e183 + (vec3<f32>(_e184) * _e186)) + _e189.xyz));
            let _e194 = delta;
            let _e195 = sector(_e194);
            s_1 = _e195;
            let _e197 = b_1;
            let _e201 = s_1;
            let _e204 = old4_(((_e197 + 24u) + (4u * _e201)));
            mom = _e204;
            let _e206 = mom;
            if (_e206.y <= 0f) {
                continue;
            }
            let _e211 = b_1;
            let _e213 = s_1;
            let _e216 = old4_((_e211 + (4u * _e213)));
            mean = _e216.w;
            let _e219 = mom;
            let _e221 = mean;
            let _e222 = mean;
            variance = max((_e219.x - (_e221 * _e222)), 0.0025f);
            let _e228 = delta;
            let _e230 = mean;
            excess = max(((length(_e228) - _e230) - 0.05f), 0f);
            let _e237 = variance;
            let _e238 = variance;
            let _e239 = excess;
            let _e240 = excess;
            visibility = (_e237 / (_e238 + (_e239 * _e240)));
            let _e245 = visibility;
            let _e246 = visibility;
            let _e248 = visibility;
            visibility = ((_e245 * _e246) * _e248);
            let _e250 = n_2;
            let _e251 = n_2;
            n2_ = (_e250 * _e251);
            let _e254 = b_1;
            let _e256 = n_2;
            if (_e256.x >= 0f) {
                local_8 = 0u;
            } else {
                local_8 = 1u;
            }
            let _e264 = local_8;
            let _e267 = old4_((_e254 + (4u * _e264)));
            let _e269 = n2_;
            let _e272 = b_1;
            let _e274 = n_2;
            if (_e274.y >= 0f) {
                local_9 = 2u;
            } else {
                local_9 = 3u;
            }
            let _e282 = local_9;
            let _e285 = old4_((_e272 + (4u * _e282)));
            let _e287 = n2_;
            let _e291 = b_1;
            let _e293 = n_2;
            if (_e293.z >= 0f) {
                local_10 = 4u;
            } else {
                local_10 = 5u;
            }
            let _e301 = local_10;
            let _e304 = old4_((_e291 + (4u * _e301)));
            let _e306 = n2_;
            rad = (((_e267.xyz * _e269.x) + (_e285.xyz * _e287.y)) + (_e304.xyz * _e306.z));
            let _e311 = rgb;
            let _e312 = rad;
            let _e313 = finiteRgb(_e312);
            let _e314 = w;
            let _e316 = visibility;
            rgb = (_e311 + ((_e313 * _e314) * _e316));
            let _e319 = weights;
            let _e320 = w;
            weights = (_e319 + _e320);
        }
        continuing {
            let _e112 = i_14;
            i_14 = (_e112 + 1i);
        }
    }
    let _e322 = rgb;
    let _e323 = weights;
    let _e327 = (_e322 / vec3(max(_e323, 0.00001f)));
    let _e328 = weights;
    return vec4<f32>(_e327.x, _e327.y, _e327.z, clamp(_e328, 0f, 1f));
}

fn cdfAt(i_15: u32) -> f32 {
    var i_16: u32;

    i_16 = i_15;
    let _e40 = i_16;
    let _e43 = i_16;
    let _e48 = global_4.cdf[(_e43 / 4u)][(_e40 % 4u)];
    return _e48;
}

fn importancePdf(i_17: u32) -> f32 {
    var i_18: u32;
    var local_11: f32;

    i_18 = i_17;
    let _e40 = i_18;
    let _e41 = cdfAt(_e40);
    let _e42 = i_18;
    if (_e42 == 0u) {
        local_11 = 0f;
    } else {
        let _e46 = i_18;
        let _e49 = cdfAt((_e46 - 1u));
        local_11 = _e49;
    }
    let _e51 = local_11;
    return max((_e41 - _e51), 0f);
}

fn importanceSample(u_2: f32) -> u32 {
    var u_3: f32;
    var lo_1: u32 = 0u;
    var hi_1: u32;
    var i_19: i32 = 0i;
    var mid: u32;

    u_3 = u_2;
    let _e42 = global_4.counts;
    hi_1 = (_e42.w - 1u);
    loop {
        let _e49 = i_19;
        if !((_e49 < 8i)) {
            break;
        }
        {
            let _e56 = lo_1;
            let _e57 = hi_1;
            if (_e56 >= _e57) {
                break;
            }
            let _e59 = lo_1;
            let _e60 = hi_1;
            mid = ((_e59 + _e60) / 2u);
            let _e65 = u_3;
            let _e66 = mid;
            let _e67 = cdfAt(_e66);
            if (_e65 < _e67) {
                let _e69 = mid;
                hi_1 = _e69;
            } else {
                let _e70 = mid;
                lo_1 = (_e70 + 1u);
            }
        }
        continuing {
            let _e53 = i_19;
            i_19 = (_e53 + 1i);
        }
    }
    let _e73 = lo_1;
    return _e73;
}

fn lightContribution(index_2: u32, p_2: vec3<f32>, n_3: vec3<f32>, l_1: ptr<function, vec3<f32>>, distance: ptr<function, f32>) -> vec3<f32> {
    var index_3: u32;
    var p_3: vec3<f32>;
    var n_4: vec3<f32>;
    var base_2: u32;
    var pr: vec4<f32>;
    var cr: vec4<f32>;
    var sp_1: vec4<f32>;
    var delta_1: vec3<f32>;
    var r_1: f32;
    var w_1: f32;

    index_3 = index_2;
    p_3 = p_2;
    n_4 = n_3;
    let _e46 = index_3;
    base_2 = (_e46 * 12u);
    let _e50 = base_2;
    let _e51 = light4_(_e50);
    pr = _e51;
    let _e53 = base_2;
    let _e56 = light4_((_e53 + 4u));
    cr = _e56;
    let _e58 = base_2;
    let _e61 = light4_((_e58 + 8u));
    sp_1 = _e61;
    let _e63 = pr;
    let _e65 = p_3;
    delta_1 = (_e63.xyz - _e65);
    let _e68 = delta_1;
    (*distance) = length(_e68);
    let _e70 = delta_1;
    let _e71 = (*distance);
    (*l_1) = (_e70 / vec3(max(_e71, 0.00001f)));
    let _e76 = (*distance);
    let _e79 = (*distance);
    let _e80 = pr;
    let _e84 = pr;
    let _e90 = sp_1;
    if ((((_e76 < 0.05f) || (_e79 >= _e80.w)) || (_e84.w <= 0f)) || (_e90.z <= 0f)) {
        return vec3(0f);
    }
    let _e99 = (*distance);
    let _e100 = pr;
    r_1 = (_e99 / _e100.w);
    let _e105 = r_1;
    let _e106 = r_1;
    let _e108 = r_1;
    let _e110 = r_1;
    w_1 = (1f - (((_e105 * _e106) * _e108) * _e110));
    let _e115 = cr;
    let _e117 = w_1;
    let _e118 = w_1;
    let _e120 = (*distance);
    let _e121 = (*distance);
    let _e125 = sp_1;
    let _e127 = sp_1;
    let _e133 = n_4;
    let _e134 = (*l_1);
    let _e140 = finiteRgb(((_e115.xyz * ((_e117 * _e118) / (((_e120 * _e121) + 1f) + (_e125.x * _e127.x)))) * max(dot(_e133, _e134), 0f)));
    return _e140;
}

fn target_(c_1: vec3<f32>) -> f32 {
    var c_2: vec3<f32>;

    c_2 = c_1;
    let _e40 = c_2;
    return max(dot(_e40, vec3<f32>(0.2126f, 0.7152f, 0.0722f)), 0f);
}

fn clearReservoir(base_3: u32) {
    var base_4: u32;

    base_4 = base_3;
    let _e40 = base_4;
    global_3.reservoirs[_e40] = vec4<u32>(0u, 0u, 0u, 4294967295u);
    let _e50 = base_4;
    global_3.reservoirs[(_e50 + 1u)] = vec4(0u);
    let _e57 = base_4;
    global_3.reservoirs[(_e57 + 2u)] = vec4(0u);
    return;
}

fn sampleDirect(p_4: vec3<f32>, n_5: vec3<f32>, rb_1: u32, canReuse: bool, state: ptr<function, u32>) -> vec3<f32> {
    var p_5: vec3<f32>;
    var n_6: vec3<f32>;
    var rb_2: u32;
    var canReuse_1: bool;
    var selected: u32 = INVALID;
    var M: u32 = 0u;
    var sum: f32 = 0f;
    var selectedTarget: f32 = 0f;
    var i_20: i32 = 0i;
    var importance: bool;
    var u_4: f32;
    var local_12: u32;
    var idx: u32;
    var l_2: vec3<f32>;
    var distance_1: f32;
    var c_3: vec3<f32>;
    var t_1: f32;
    var pdf: f32;
    var w_2: f32;
    var a_2: vec4<u32>;
    var b_2: vec4<u32>;
    var c_4: vec4<u32>;
    var idx_1: u32;
    var oldM: u32;
    var oldW: f32;
    var l_3: vec3<f32>;
    var distance_2: f32;
    var t_2: f32;
    var w_3: f32;
    var W: f32;
    var l_4: vec3<f32>;
    var distance_3: f32;
    var c_5: vec3<f32>;
    var local_13: vec3<f32>;

    p_5 = p_4;
    n_6 = n_5;
    rb_2 = rb_1;
    canReuse_1 = canReuse;
    let _e47 = global_4.counts;
    if (_e47.w == 0u) {
        {
            let _e51 = rb_2;
            clearReservoir(_e51);
            return vec3(0f);
        }
    }
    loop {
        let _e66 = i_20;
        if !((_e66 < 4i)) {
            break;
        }
        {
            let _e75 = random(state);
            importance = (_e75 < 0.5f);
            let _e81 = random(state);
            u_4 = _e81;
            let _e83 = importance;
            if _e83 {
                let _e84 = u_4;
                let _e85 = importanceSample(_e84);
                local_12 = _e85;
            } else {
                let _e86 = u_4;
                let _e87 = global_4.counts;
                let _e92 = global_4.counts;
                local_12 = min(u32((_e86 * f32(_e87.w))), (_e92.w - 1u));
            }
            let _e98 = local_12;
            idx = _e98;
            let _e102 = idx;
            let _e103 = p_5;
            let _e104 = n_6;
            let _e109 = lightContribution(_e102, _e103, _e104, (&l_2), (&distance_1));
            c_3 = _e109;
            let _e111 = c_3;
            let _e112 = target_(_e111);
            t_1 = _e112;
            let _e115 = global_4.counts;
            let _e120 = idx;
            let _e121 = importancePdf(_e120);
            pdf = ((0.5f / f32(_e115.w)) + (0.5f * _e121));
            let _e125 = t_1;
            let _e126 = pdf;
            w_2 = (_e125 / max(_e126, 0.00000001f));
            let _e131 = sum;
            let _e132 = w_2;
            sum = (_e131 + _e132);
            let _e134 = M;
            M = (_e134 + 1u);
            let _e137 = w_2;
            let _e143 = random(state);
            let _e144 = sum;
            let _e146 = w_2;
            if ((_e137 > 0f) && ((_e143 * _e144) < _e146)) {
                {
                    let _e149 = idx;
                    selected = _e149;
                    let _e150 = t_1;
                    selectedTarget = _e150;
                }
            }
        }
        continuing {
            let _e70 = i_20;
            i_20 = (_e70 + 1i);
        }
    }
    let _e151 = canReuse_1;
    if _e151 {
        {
            let _e152 = rb_2;
            let _e154 = global_3.reservoirs[_e152];
            a_2 = _e154;
            let _e156 = rb_2;
            let _e160 = global_3.reservoirs[(_e156 + 1u)];
            b_2 = _e160;
            let _e162 = rb_2;
            let _e166 = global_3.reservoirs[(_e162 + 2u)];
            c_4 = _e166;
            let _e168 = a_2;
            idx_1 = _e168.w;
            let _e171 = c_4;
            oldM = min(_e171.x, 16u);
            let _e176 = b_2;
            oldW = bitcast<f32>(_e176.w);
            let _e180 = idx_1;
            let _e181 = global_4.counts;
            let _e184 = oldM;
            let _e188 = c_4;
            let _e190 = global_4.light_key;
            let _e194 = c_4;
            let _e196 = global_4.light_key;
            let _e200 = oldW;
            let _e205 = oldW;
            let _e206 = zy_isnan(_e205);
            let _e209 = oldW;
            let _e210 = zy_isinf(_e209);
            let _e213 = a_2;
            let _e216 = p_5;
            let _e222 = b_2;
            let _e225 = n_6;
            if (((((((((_e180 < _e181.w) && (_e184 > 0u)) && (_e188.y == _e190.x)) && (_e194.z == _e196.y)) && (_e200 > 0f)) && !(_e206)) && !(_e210)) && (length((bitcast<vec3<f32>>(_e213.xyz) - _e216)) < 0.15f)) && (dot(bitcast<vec3<f32>>(_e222.xyz), _e225) > 0.9f)) {
                {
                    let _e232 = idx_1;
                    let _e233 = p_5;
                    let _e234 = n_6;
                    let _e239 = lightContribution(_e232, _e233, _e234, (&l_3), (&distance_2));
                    let _e240 = target_(_e239);
                    t_2 = _e240;
                    let _e242 = t_2;
                    let _e243 = oldW;
                    let _e245 = oldM;
                    w_3 = ((_e242 * _e243) * f32(_e245));
                    let _e249 = w_3;
                    let _e250 = zy_isnan(_e249);
                    let _e252 = w_3;
                    let _e253 = zy_isinf(_e252);
                    let _e256 = w_3;
                    if ((!(_e250) && !(_e253)) && (_e256 >= 0f)) {
                        {
                            let _e261 = sum;
                            let _e262 = w_3;
                            sum = (_e261 + _e262);
                            let _e264 = M;
                            let _e265 = oldM;
                            M = (_e264 + _e265);
                            let _e267 = w_3;
                            let _e273 = random(state);
                            let _e274 = sum;
                            let _e276 = w_3;
                            if ((_e267 > 0f) && ((_e273 * _e274) < _e276)) {
                                {
                                    let _e279 = idx_1;
                                    selected = _e279;
                                    let _e280 = t_2;
                                    selectedTarget = _e280;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    let _e281 = selected;
    let _e283 = selectedTarget;
    if ((_e281 == INVALID) || (_e283 <= 0.00000001f)) {
        {
            let _e287 = rb_2;
            clearReservoir(_e287);
            return vec3(0f);
        }
    }
    let _e291 = sum;
    let _e292 = M;
    let _e294 = selectedTarget;
    W = (_e291 / (f32(_e292) * _e294));
    let _e298 = W;
    let _e299 = zy_isnan(_e298);
    let _e300 = W;
    let _e301 = zy_isinf(_e300);
    let _e303 = W;
    if ((_e299 || _e301) || (_e303 <= 0f)) {
        {
            let _e308 = rb_2;
            clearReservoir(_e308);
            return vec3(0f);
        }
    }
    let _e312 = rb_2;
    let _e314 = p_5;
    let _e315 = bitcast<vec3<u32>>(_e314);
    let _e316 = selected;
    global_3.reservoirs[_e312] = vec4<u32>(_e315.x, _e315.y, _e315.z, _e316);
    let _e321 = rb_2;
    let _e325 = n_6;
    let _e326 = bitcast<vec3<u32>>(_e325);
    let _e327 = W;
    global_3.reservoirs[(_e321 + 1u)] = vec4<u32>(_e326.x, _e326.y, _e326.z, bitcast<u32>(_e327));
    let _e333 = rb_2;
    let _e337 = M;
    let _e338 = global_4.light_key;
    let _e340 = global_4.light_key;
    global_3.reservoirs[(_e333 + 2u)] = vec4<u32>(_e337, _e338.x, _e340.y, 0u);
    let _e347 = selected;
    let _e348 = p_5;
    let _e349 = n_6;
    let _e354 = lightContribution(_e347, _e348, _e349, (&l_4), (&distance_3));
    c_5 = _e354;
    let _e356 = p_5;
    let _e357 = l_4;
    let _e358 = distance_3;
    let _e362 = trace(_e356, _e357, (_e358 - 0.005f), true);
    if _e362.found {
        local_13 = vec3(0f);
    } else {
        let _e367 = c_5;
        let _e368 = W;
        let _e370 = finiteRgb((_e367 * _e368));
        local_13 = _e370;
    }
    let _e372 = local_13;
    return _e372;
}

fn main_1() {
    var lane: u32;
    var idx_2: u32;
    var base_5: u32;
    var rb_3: u32;
    var count: u32;
    var prevOff: vec4<f32>;
    var spacing_1: vec3<f32>;
    var original: vec3<f32>;
    var oldOffset: vec3<f32>;
    var shift: vec3<f32> = vec3(0f);
    var p_6: vec3<f32>;
    var clearance: f32;
    var a_3: i32 = 0i;
    var local_14: array<vec3<f32>, 6> = axes;
    var h_1: Hit;
    var local_15: array<vec3<f32>, 6> = axes;
    var y: f32;
    var angle: f32;
    var r_2: f32;
    var dir: vec3<f32>;
    var hit: Hit;
    var radiance: vec3<f32> = vec3(0f);
    var back: f32 = 0f;
    var state_1: u32;
    var local_16: vec3<f32>;
    var n_7: vec3<f32>;
    var local_17: f32;
    var p_7: vec3<f32>;
    var mat: u32;
    var albedo: vec3<f32>;
    var stable: bool;
    var direct: vec3<f32>;
    var sun: vec3<f32>;
    var nl: f32;
    var previous: vec4<f32>;
    var local_18: f32;
    var backs: f32 = 0f;
    var i_21: u32 = 0u;
    var local_19: f32;
    var valid: f32;
    var local_20: f32;
    var h_2: f32;
    var outBase: u32;
    var a_4: u32 = 0u;
    var sum_1: vec3<f32>;
    var weights_1: f32;
    var dist: f32;
    var sq: f32;
    var n_8: f32;
    var i_22: u32;
    var local_21: array<vec3<f32>, 6> = axes;
    var w_4: f32;
    var previous_1: vec4<f32>;
    var mom_1: vec4<f32>;
    var local_22: f32;
    var vh: f32;
    var local_23: f32;
    var mean_1: f32;
    var local_24: f32;
    var square: f32;
    var local_25: f32;
    var local_26: f32;

    let _e39 = gl_LocalInvocationIndex_1;
    lane = _e39;
    let _e42 = global_4.dispatch_info;
    let _e44 = gl_WorkGroupID_1;
    idx_2 = ((_e42.x + _e44.x) % 64u);
    let _e50 = idx_2;
    let _e51 = probeBase(_e50);
    base_5 = _e51;
    let _e53 = idx_2;
    let _e56 = lane;
    rb_3 = (((_e53 * 64u) + _e56) * 3u);
    let _e61 = global_4.dispatch_info;
    count = clamp(_e61.y, 12u, 64u);
    let _e67 = base_5;
    let _e70 = old4_((_e67 + 48u));
    prevOff = _e70;
    let _e73 = old4_(4u);
    spacing_1 = _e73.xyz;
    let _e76 = lane;
    if (_e76 == 0u) {
        {
            let _e80 = old4_(0u);
            let _e82 = idx_2;
            let _e83 = probeCoords(_e82);
            let _e84 = spacing_1;
            original = (_e80.xyz + (_e83 * _e84));
            let _e88 = prevOff;
            oldOffset = _e88.xyz;
            let _e95 = original;
            let _e96 = oldOffset;
            p_6 = (_e95 + _e96);
            let _e99 = spacing_1;
            let _e101 = spacing_1;
            let _e103 = spacing_1;
            clearance = min((min(_e99.x, min(_e101.y, _e103.z)) * 0.15f), 0.2f);
            loop {
                let _e114 = a_3;
                if !((_e114 < 6i)) {
                    break;
                }
                {
                    let _e121 = p_6;
                    let _e122 = a_3;
                    let _e126 = local_14[_e122];
                    let _e127 = clearance;
                    let _e129 = trace(_e121, _e126, _e127, false);
                    h_1 = _e129;
                    let _e131 = h_1;
                    if _e131.found {
                        let _e133 = shift;
                        let _e134 = a_3;
                        let _e138 = local_15[_e134];
                        let _e139 = clearance;
                        let _e140 = h_1;
                        shift = (_e133 - (_e138 * (_e139 - _e140.t)));
                    }
                }
                continuing {
                    let _e118 = a_3;
                    a_3 = (_e118 + 1i);
                }
            }
            let _e145 = oldOffset;
            let _e146 = shift;
            let _e148 = spacing_1;
            let _e152 = spacing_1;
            probe_offset = clamp((_e145 + _e146), (-(_e148) * 0.3f), (_e152 * 0.3f));
            let _e156 = original;
            let _e157 = probe_offset;
            probe_pos = (_e156 + _e157);
        }
    }
    storageBarrier();
    workgroupBarrier();
    workgroupBarrier();
    textureBarrier();
    let _e159 = lane;
    let _e160 = count;
    if (_e159 < _e160) {
        {
            let _e164 = lane;
            let _e169 = count;
            y = (1f - ((2f * (f32(_e164) + 0.5f)) / f32(_e169)));
            let _e174 = lane;
            let _e178 = global_4.dispatch_info;
            angle = ((f32(_e174) * 2.3999631f) + (f32((_e178.z % 1024u)) * 0.381966f));
            let _e188 = y;
            let _e189 = y;
            r_2 = sqrt(max((1f - (_e188 * _e189)), 0f));
            let _e198 = r_2;
            let _e199 = angle;
            let _e202 = y;
            let _e203 = r_2;
            let _e204 = angle;
            dir = vec3<f32>((_e198 * cos(_e199)), _e202, (_e203 * sin(_e204)));
            let _e209 = probe_pos;
            let _e210 = dir;
            let _e211 = global_4.config;
            let _e214 = trace(_e209, _e210, _e211.x, false);
            hit = _e214;
            let _e223 = idx_2;
            let _e228 = lane;
            let _e234 = global_4.dispatch_info;
            state_1 = ((((_e223 + 1u) * 747796405u) ^ ((_e228 + 1u) * 2891336453u)) ^ ((_e234.z + 1u) * 277803737u));
            let _e242 = state_1;
            state_1 = (_e242 | 1u);
            let _e245 = hit;
            if !(_e245.found) {
                {
                    let _e248 = rb_3;
                    clearReservoir(_e248);
                    let _e249 = dir;
                    if (_e249.y >= 0f) {
                        let _e254 = global_4.sky_horizon;
                        let _e256 = global_4.sky_zenith;
                        let _e258 = dir;
                        local_16 = mix(_e254.xyz, _e256.xyz, vec3(pow(clamp(_e258.y, 0f, 1f), 0.55f)));
                    } else {
                        let _e269 = global_4.sky_horizon;
                        let _e271 = global_4.sky_ground;
                        let _e273 = dir;
                        local_16 = mix(_e269.xyz, _e271.xyz, vec3(clamp((-(_e273.y) * 4f), 0f, 1f)));
                    }
                    let _e287 = local_16;
                    radiance = _e287;
                }
            } else {
                let _e288 = hit;
                let _e290 = global_4.counts;
                if (_e288.material < _e290.z) {
                    {
                        let _e293 = hit;
                        n_7 = _e293.normal;
                        let _e296 = n_7;
                        let _e297 = dir;
                        if (dot(_e296, _e297) > 0f) {
                            local_17 = 1f;
                        } else {
                            local_17 = 0f;
                        }
                        let _e305 = local_17;
                        back = _e305;
                        let _e306 = back;
                        if (_e306 > 0f) {
                            let _e310 = n_7;
                            n_7 = -(_e310);
                        }
                        let _e312 = probe_pos;
                        let _e313 = dir;
                        let _e314 = hit;
                        let _e318 = n_7;
                        p_7 = ((_e312 + (_e313 * _e314.t)) + (_e318 * 0.005f));
                        let _e323 = global_4.offsets;
                        let _e325 = hit;
                        mat = (_e323.z + (_e325.material * 8u));
                        let _e331 = mat;
                        let _e332 = geom3_(_e331);
                        let _e340 = mat;
                        let _e344 = global.geom[(_e340 + 3u)];
                        albedo = (clamp(_e332, vec3(0f), vec3(0.95f)) * (1f - clamp(bitcast<f32>(_e344), 0f, 1f)));
                        let _e355 = prevOff;
                        let _e360 = global_4.dispatch_info;
                        let _e365 = probe_offset;
                        let _e366 = prevOff;
                        stable = (((_e355.w > 0f) && (_e360.w == 0u)) && (length((_e365 - _e366.xyz)) < 0.05f));
                        let _e374 = p_7;
                        let _e375 = n_7;
                        let _e376 = rb_3;
                        let _e377 = stable;
                        let _e380 = sampleDirect(_e374, _e375, _e376, _e377, (&state_1));
                        direct = _e380;
                        let _e382 = global_4.sun_dir_int;
                        let _e384 = norm(_e382.xyz);
                        sun = _e384;
                        let _e386 = n_7;
                        let _e387 = sun;
                        nl = max(dot(_e386, _e387), 0f);
                        let _e393 = global_4.sun_dir_int;
                        let _e398 = nl;
                        let _e403 = p_7;
                        let _e404 = sun;
                        let _e408 = trace(_e403, _e404, 1000f, true);
                        if (((_e393.w > 0f) && (_e398 > 0f)) && !(_e408.found)) {
                            let _e412 = direct;
                            let _e413 = global_4.sun_color;
                            let _e415 = global_4.sun_dir_int;
                            let _e418 = nl;
                            let _e420 = finiteRgb(((_e413.xyz * _e415.w) * _e418));
                            direct = (_e412 + _e420);
                        }
                        let _e422 = p_7;
                        let _e423 = n_7;
                        let _e424 = samplePrevious(_e422, _e423);
                        previous = _e424;
                        let _e426 = mat;
                        let _e429 = geom3_((_e426 + 4u));
                        let _e430 = albedo;
                        let _e431 = direct;
                        let _e435 = previous;
                        let _e437 = previous;
                        let _e440 = global_4.config;
                        radiance = (_e429 + (_e430 * ((_e431 / vec3(3.1415927f)) + ((_e435.xyz * _e437.w) * _e440.z))));
                    }
                } else {
                    let _e446 = rb_3;
                    clearReservoir(_e446);
                }
            }
            let _e447 = lane;
            let _e449 = radiance;
            let _e450 = finiteRgb(_e449);
            let _e451 = hit;
            if _e451.found {
                let _e453 = hit;
                local_18 = _e453.t;
            } else {
                let _e455 = global_4.config;
                local_18 = _e455.x;
            }
            let _e458 = local_18;
            ray_result[_e447] = vec4<f32>(_e450.x, _e450.y, _e450.z, _e458);
            let _e463 = lane;
            let _e465 = dir;
            let _e466 = back;
            ray_direction[_e463] = vec4<f32>(_e465.x, _e465.y, _e465.z, _e466);
        }
    } else {
        {
            let _e471 = rb_3;
            clearReservoir(_e471);
            let _e472 = lane;
            ray_result[_e472] = vec4(0f);
            let _e477 = lane;
            ray_direction[_e477] = vec4(0f);
        }
    }
    storageBarrier();
    workgroupBarrier();
    workgroupBarrier();
    textureBarrier();
    let _e482 = lane;
    if (_e482 == 0u) {
        {
            loop {
                let _e490 = i_21;
                let _e491 = count;
                if !((_e490 < _e491)) {
                    break;
                }
                let _e497 = backs;
                let _e498 = i_21;
                let _e500 = ray_direction[_e498];
                backs = (_e497 + _e500.w);
                continuing {
                    let _e494 = i_21;
                    i_21 = (_e494 + 1u);
                }
            }
            let _e503 = backs;
            let _e506 = count;
            if ((_e503 * 2f) > f32(_e506)) {
                local_19 = 0f;
            } else {
                local_19 = 1f;
            }
            let _e512 = local_19;
            valid = _e512;
            let _e514 = prevOff;
            let _e519 = valid;
            let _e524 = probe_offset;
            let _e525 = prevOff;
            let _e532 = global_4.dispatch_info;
            if ((((_e514.w > 0f) && (_e519 > 0f)) && (length((_e524 - _e525.xyz)) < 0.05f)) && (_e532.w == 0u)) {
                let _e537 = global_4.config;
                local_20 = _e537.y;
            } else {
                local_20 = 0f;
            }
            let _e542 = local_20;
            h_2 = _e542;
            let _e544 = global_4.offsets;
            let _e546 = base_5;
            outBase = (_e544.w + _e546);
            loop {
                let _e551 = a_4;
                if !((_e551 < 6u)) {
                    break;
                }
                {
                    sum_1 = vec3(0f);
                    weights_1 = 0f;
                    dist = 0f;
                    sq = 0f;
                    n_8 = 0f;
                    i_22 = 0u;
                    loop {
                        let _e576 = i_22;
                        let _e577 = count;
                        if !((_e576 < _e577)) {
                            break;
                        }
                        {
                            let _e583 = i_22;
                            let _e585 = ray_direction[_e583];
                            let _e587 = a_4;
                            let _e591 = local_21[_e587];
                            w_4 = max(dot(_e585.xyz, _e591), 0f);
                            let _e597 = sum_1;
                            let _e598 = i_22;
                            let _e600 = ray_result[_e598];
                            let _e602 = w_4;
                            sum_1 = (_e597 + (_e600.xyz * _e602));
                            let _e605 = weights_1;
                            let _e606 = w_4;
                            weights_1 = (_e605 + _e606);
                            let _e608 = i_22;
                            let _e610 = ray_direction[_e608];
                            let _e612 = sector(_e610.xyz);
                            let _e613 = a_4;
                            if (_e612 == _e613) {
                                {
                                    let _e615 = dist;
                                    let _e616 = i_22;
                                    let _e618 = ray_result[_e616];
                                    dist = (_e615 + _e618.w);
                                    let _e621 = sq;
                                    let _e622 = i_22;
                                    let _e624 = ray_result[_e622];
                                    let _e626 = i_22;
                                    let _e628 = ray_result[_e626];
                                    sq = (_e621 + (_e624.w * _e628.w));
                                    let _e632 = n_8;
                                    n_8 = (_e632 + 1f);
                                }
                            }
                        }
                        continuing {
                            let _e580 = i_22;
                            i_22 = (_e580 + 1u);
                        }
                    }
                    let _e636 = base_5;
                    let _e637 = a_4;
                    let _e641 = old4_((_e636 + (_e637 * 4u)));
                    previous_1 = _e641;
                    let _e643 = base_5;
                    let _e646 = a_4;
                    let _e650 = old4_(((_e643 + 24u) + (_e646 * 4u)));
                    mom_1 = _e650;
                    let _e652 = mom_1;
                    if (_e652.y > 0f) {
                        let _e657 = h_2;
                        local_22 = _e657;
                    } else {
                        local_22 = 0f;
                    }
                    let _e661 = local_22;
                    vh = _e661;
                    let _e663 = n_8;
                    if (_e663 > 0f) {
                        let _e667 = dist;
                        let _e668 = n_8;
                        let _e670 = previous_1;
                        let _e672 = vh;
                        local_23 = mix((_e667 / _e668), _e670.w, _e672);
                    } else {
                        let _e674 = previous_1;
                        local_23 = _e674.w;
                    }
                    let _e677 = local_23;
                    mean_1 = _e677;
                    let _e679 = n_8;
                    if (_e679 > 0f) {
                        let _e683 = sq;
                        let _e684 = n_8;
                        let _e686 = mom_1;
                        let _e688 = vh;
                        local_24 = mix((_e683 / _e684), _e686.x, _e688);
                    } else {
                        let _e690 = mom_1;
                        local_24 = _e690.x;
                    }
                    let _e693 = local_24;
                    square = _e693;
                    let _e695 = outBase;
                    let _e696 = a_4;
                    let _e700 = sum_1;
                    let _e701 = weights_1;
                    let _e706 = previous_1;
                    let _e708 = h_2;
                    let _e710 = mix((_e700 / vec3(max(_e701, 0.000001f))), _e706.xyz, vec3(_e708));
                    let _e711 = mean_1;
                    store4_((_e695 + (_e696 * 4u)), vec4<f32>(_e710.x, _e710.y, _e710.z, _e711));
                    let _e716 = outBase;
                    let _e719 = a_4;
                    let _e723 = square;
                    let _e724 = n_8;
                    if (_e724 > 0f) {
                        let _e728 = valid;
                        local_26 = _e728;
                    } else {
                        let _e729 = h_2;
                        if (_e729 > 0f) {
                            let _e733 = mom_1;
                            local_25 = _e733.y;
                        } else {
                            local_25 = 0f;
                        }
                        let _e738 = local_25;
                        local_26 = _e738;
                    }
                    let _e740 = local_26;
                    store4_(((_e716 + 24u) + (_e719 * 4u)), vec4<f32>(_e723, _e740, 0f, 0f));
                }
                continuing {
                    let _e555 = a_4;
                    a_4 = (_e555 + 1u);
                }
            }
            let _e746 = outBase;
            let _e749 = probe_offset;
            let _e750 = valid;
            store4_((_e746 + 48u), vec4<f32>(_e749.x, _e749.y, _e749.z, _e750));
            return;
        }
    } else {
        return;
    }
}

@compute @workgroup_size(64, 1, 1) 
fn main(@builtin(local_invocation_index) gl_LocalInvocationIndex: u32, @builtin(workgroup_id) gl_WorkGroupID: vec3<u32>) {
    gl_LocalInvocationIndex_1 = gl_LocalInvocationIndex;
    gl_WorkGroupID_1 = gl_WorkGroupID;
    main_1();
    return;
}
