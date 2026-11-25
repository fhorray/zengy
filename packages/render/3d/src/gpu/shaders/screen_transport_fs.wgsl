// Ported from screen_transport.frag (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.
struct DepthBounds {
    bounds: array<vec2<f32>>,
}

struct ScreenParams {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    camera_gain: vec4<f32>,
    controls: vec4<f32>,
    levels: array<vec4<u32>, 16>,
    budget: vec4<u32>,
}

struct Hit {
    uv: vec2<f32>,
    confidence: f32,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

const PI: f32 = 3.1415927f;

var<private> v_ndc_1: vec2<f32>;
var<private> frag_color: vec4<f32>;
@group(0) @binding(0) 
var zengy_u_hdr_image: texture_2d<f32>;
@group(0) @binding(32) 
var zengy_u_hdr_sampler: sampler;
@group(0) @binding(1) 
var zengy_u_depth_image: texture_2d<f32>;
@group(0) @binding(33) 
var zengy_u_depth_sampler: sampler;
@group(0) @binding(2) 
var zengy_u_surface_image: texture_2d<f32>;
@group(0) @binding(34) 
var zengy_u_surface_sampler: sampler;
@group(0) @binding(3) 
var zengy_u_diffuse_image: texture_2d<f32>;
@group(0) @binding(35) 
var zengy_u_diffuse_sampler: sampler;
@group(0) @binding(4) 
var zengy_u_specular_image: texture_2d<f32>;
@group(0) @binding(36) 
var zengy_u_specular_sampler: sampler;
@group(0) @binding(5) 
var zengy_u_brdf_image: texture_2d<f32>;
@group(0) @binding(37) 
var zengy_u_brdf_sampler: sampler;
@group(0) @binding(6) 
var<storage> global: DepthBounds;
@group(1) @binding(0) 
var<uniform> global_1: ScreenParams;
var<private> gl_FragCoord_1: vec4<f32>;

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

fn safeNormalize(v_16: vec3<f32>) -> vec3<f32> {
    var v_17: vec3<f32>;

    v_17 = v_16;
    let _e31 = v_17;
    let _e32 = v_17;
    let _e33 = v_17;
    return (_e31 * inverseSqrt(max(dot(_e32, _e33), 0.000000000001f)));
}

fn worldAt(uv: vec2<f32>, d: f32) -> vec3<f32> {
    var uv_1: vec2<f32>;
    var d_1: f32;
    var h: vec4<f32>;

    uv_1 = uv;
    d_1 = d;
    let _e33 = global_1.inv_view_proj;
    let _e34 = uv_1;
    let _e41 = uv_1;
    let _e46 = d_1;
    h = (_e33 * vec4<f32>(((_e34.x * 2f) - 1f), (1f - (_e41.y * 2f)), _e46, 1f));
    let _e51 = h;
    let _e53 = h;
    return (_e51.xyz / vec3(max(_e53.w, 0.000001f)));
}

fn projectPoint(h_1: vec4<f32>) -> vec3<f32> {
    var h_2: vec4<f32>;
    var n: vec3<f32>;

    h_2 = h_1;
    let _e31 = h_2;
    let _e33 = h_2;
    n = (_e31.xyz / vec3(_e33.w));
    let _e38 = n;
    let _e45 = n;
    let _e50 = n;
    return vec3<f32>(((_e38.x * 0.5f) + 0.5f), (0.5f - (_e45.y * 0.5f)), _e50.z);
}

fn decodeNormal(e: vec2<f32>) -> vec3<f32> {
    var e_1: vec2<f32>;
    var n_1: vec3<f32>;

    e_1 = e;
    let _e31 = e_1;
    let _e33 = e_1;
    let _e37 = e_1;
    n_1 = vec3<f32>(_e31.x, _e31.y, ((1f - abs(_e33.x)) - abs(_e37.y)));
    let _e45 = n_1;
    if (_e45.z < 0f) {
        let _e49 = n_1;
        let _e52 = n_1;
        let _e62 = n_1;
        let _e69 = ((vec2(1f) - abs(_e52.yx)) * select(vec2(-1f), vec2(1f), (_e62.xy >= vec2(0f))));
        n_1.x = _e69.x;
        n_1.y = _e69.y;
    }
    let _e74 = n_1;
    let _e75 = safeNormalize(_e74);
    return _e75;
}

fn unpackRgb(v_18: f32) -> vec3<f32> {
    var v_19: f32;
    var p: u32;

    v_19 = v_18;
    let _e31 = v_19;
    p = u32(clamp(_e31, 0f, 16777215f));
    let _e37 = p;
    let _e40 = p;
    let _e46 = p;
    return (vec3<f32>(f32((_e37 & 255u)), f32(((_e40 >> 8u) & 255u)), f32(((_e46 >> 16u) & 255u))) / vec3(255f));
}

fn hash(p_1: vec2<f32>) -> f32 {
    var p_2: vec2<f32>;

    p_2 = p_1;
    let _e32 = p_2;
    return fract((52.982918f * fract(dot(_e32, vec2<f32>(0.06711056f, 0.00583715f)))));
}

fn traceRay(origin: vec3<f32>, direction: vec3<f32>) -> Hit {
    var origin_1: vec3<f32>;
    var direction_1: vec3<f32>;
    var miss: Hit = Hit(vec2(0f), 0f);
    var a: vec4<f32>;
    var b: vec4<f32>;
    var t: f32;
    var p_3: vec3<f32>;
    var q: vec3<f32>;
    var d_2: vec3<f32>;
    var full: vec2<f32>;
    var pixels: f32;
    var t_1: f32;
    var epsilon: f32;
    var top: i32;
    var level: i32;
    var i: u32 = 0u;
    var s: vec3<f32>;
    var info: vec4<u32>;
    var scale: f32;
    var grid: vec2<f32>;
    var cell: vec2<i32>;
    var edge: vec2<f32>;
    var dt: vec2<f32>;
    var endT: f32;
    var endZ: f32;
    var range: vec2<f32>;
    var overlaps: bool;
    var depth: f32;
    var local: f32;
    var hitT: f32;
    var hitPos: vec3<f32>;
    var hitUV: vec2<f32>;
    var surface: vec3<f32>;
    var rayPos: vec3<f32>;
    var err: f32;
    var distance: f32;
    var target_: vec4<f32>;
    var edgeFade: f32;

    origin_1 = origin;
    direction_1 = direction;
    let _e39 = global_1.view_proj;
    let _e40 = origin_1;
    a = (_e39 * vec4<f32>(_e40.x, _e40.y, _e40.z, 1f));
    let _e48 = global_1.view_proj;
    let _e49 = origin_1;
    let _e50 = direction_1;
    let _e51 = global_1.controls;
    let _e54 = (_e49 + (_e50 * _e51.z));
    b = (_e48 * vec4<f32>(_e54.x, _e54.y, _e54.z, 1f));
    let _e62 = a;
    if (_e62.w <= 0.0001f) {
        let _e66 = miss;
        return _e66;
    }
    let _e67 = b;
    if (_e67.w < 0.001f) {
        {
            let _e71 = a;
            let _e75 = a;
            let _e77 = b;
            t = clamp(((_e71.w - 0.001f) / max((_e75.w - _e77.w), 0.000001f)), 0f, 1f);
            let _e87 = a;
            let _e88 = b;
            let _e89 = t;
            b = mix(_e87, _e88, vec4(_e89));
        }
    }
    let _e92 = a;
    let _e93 = projectPoint(_e92);
    p_3 = _e93;
    let _e95 = b;
    let _e96 = projectPoint(_e95);
    q = _e96;
    let _e98 = q;
    let _e99 = p_3;
    d_2 = (_e98 - _e99);
    let _e104 = global_1.levels[0];
    full = vec2<f32>(_e104.yz);
    let _e108 = d_2;
    let _e110 = full;
    pixels = length((_e108.xy * _e110));
    let _e114 = pixels;
    if (_e114 < 2f) {
        let _e117 = miss;
        return _e117;
    }
    let _e119 = pixels;
    t_1 = min((2f / _e119), 0.99f);
    let _e125 = pixels;
    epsilon = (0.05f / _e125);
    let _e128 = global_1.budget;
    top = (i32(min(_e128.x, 16u)) - 1i);
    let _e136 = top;
    level = min(_e136, 4i);
    loop {
        let _e142 = i;
        let _e143 = global_1.budget;
        if !((_e142 < min(_e143.y, 128u))) {
            break;
        }
        {
            let _e152 = t_1;
            if (_e152 >= 1f) {
                let _e155 = miss;
                return _e155;
            }
            let _e156 = p_3;
            let _e157 = d_2;
            let _e158 = t_1;
            s = (_e156 + (_e157 * _e158));
            let _e162 = s;
            let _e169 = s;
            let _e177 = s;
            let _e182 = s;
            if (((any((_e162.xy < vec2(0f))) || any((_e169.xy >= vec2(1f)))) || (_e177.z <= 0f)) || (_e182.z >= 1f)) {
                let _e187 = miss;
                return _e187;
            }
            let _e188 = level;
            let _e190 = global_1.levels[_e188];
            info = _e190;
            let _e192 = level;
            scale = exp2(f32(_e192));
            let _e196 = full;
            let _e197 = scale;
            grid = (_e196 / vec2(_e197));
            let _e201 = s;
            let _e203 = grid;
            let _e209 = info;
            cell = clamp(vec2<i32>(floor((_e201.xy * _e203))), vec2(0i), (vec2<i32>(_e209.yz) - vec2(1i)));
            let _e217 = cell;
            let _e225 = d_2;
            let _e233 = grid;
            edge = ((vec2<f32>(_e217) + select(vec2(0f), vec2(1f), (_e225.xy > vec2(0f)))) / _e233);
            dt = vec2(100000000000000000000f);
            let _e239 = d_2;
            if (abs(_e239.x) > 0.00000001f) {
                let _e245 = edge;
                let _e247 = s;
                let _e250 = d_2;
                dt.x = ((_e245.x - _e247.x) / _e250.x);
            }
            let _e253 = d_2;
            if (abs(_e253.y) > 0.00000001f) {
                let _e259 = edge;
                let _e261 = s;
                let _e264 = d_2;
                dt.y = ((_e259.y - _e261.y) / _e264.y);
            }
            let _e268 = t_1;
            let _e269 = dt;
            let _e271 = dt;
            let _e274 = epsilon;
            endT = min(1f, (_e268 + max(min(_e269.x, _e271.y), _e274)));
            let _e279 = p_3;
            let _e281 = d_2;
            let _e283 = endT;
            endZ = (_e279.z + (_e281.z * _e283));
            let _e287 = info;
            let _e289 = cell;
            let _e292 = info;
            let _e296 = cell;
            let _e301 = global.bounds[((_e287.x + (u32(_e289.y) * _e292.y)) + u32(_e296.x))];
            range = _e301;
            let _e303 = range;
            let _e307 = s;
            let _e309 = endZ;
            let _e311 = range;
            let _e315 = s;
            let _e317 = endZ;
            let _e319 = range;
            overlaps = (((_e303.x < 0.99999f) && (max(_e307.z, _e309) >= _e311.x)) && (min(_e315.z, _e317) <= (_e319.y + 0.0001f)));
            let _e326 = overlaps;
            let _e327 = level;
            if (_e326 && (_e327 > 0i)) {
                {
                    let _e331 = level;
                    level = (_e331 - 1i);
                    continue;
                }
            }
            let _e334 = overlaps;
            if _e334 {
                {
                    let _e335 = range;
                    depth = _e335.x;
                    let _e338 = d_2;
                    if (abs(_e338.z) > 0.00000001f) {
                        let _e343 = depth;
                        let _e344 = p_3;
                        let _e347 = d_2;
                        let _e350 = t_1;
                        let _e351 = endT;
                        local = clamp(((_e343 - _e344.z) / _e347.z), _e350, _e351);
                    } else {
                        let _e353 = t_1;
                        local = _e353;
                    }
                    let _e355 = local;
                    hitT = _e355;
                    let _e357 = p_3;
                    let _e358 = d_2;
                    let _e359 = hitT;
                    hitPos = (_e357 + (_e358 * _e359));
                    let _e363 = cell;
                    let _e368 = full;
                    hitUV = ((vec2<f32>(_e363) + vec2(0.5f)) / _e368);
                    let _e371 = hitUV;
                    let _e372 = depth;
                    let _e373 = worldAt(_e371, _e372);
                    surface = _e373;
                    let _e375 = hitPos;
                    let _e377 = hitPos;
                    let _e379 = worldAt(_e375.xy, _e377.z);
                    rayPos = _e379;
                    let _e381 = surface;
                    let _e382 = rayPos;
                    err = length((_e381 - _e382));
                    let _e386 = surface;
                    let _e387 = origin_1;
                    distance = length((_e386 - _e387));
                    let _e391 = err;
                    let _e392 = global_1.controls;
                    let _e395 = distance;
                    let _e396 = global_1.controls;
                    let _e402 = distance;
                    let _e403 = global_1.controls;
                    let _e405 = global_1.controls;
                    if (((_e391 <= _e392.w) && (_e395 > (_e396.w * 1.5f))) && (_e402 <= (_e403.z + _e405.w))) {
                        {
                            let _e410 = cell;
                            let _e412 = textureLoad(zengy_u_surface_image, _e410, 0i);
                            target_ = _e412;
                            let _e414 = target_;
                            let _e418 = target_;
                            let _e420 = decodeNormal(_e418.xy);
                            let _e421 = direction_1;
                            if ((_e414.z >= 0f) && (dot(_e420, -(_e421)) > 0.02f)) {
                                {
                                    let _e427 = hitUV;
                                    let _e430 = hitUV;
                                    let _e434 = hitUV;
                                    let _e437 = hitUV;
                                    edgeFade = clamp((min(min(_e427.x, (1f - _e430.x)), min(_e434.y, (1f - _e437.y))) * 12f), 0f, 1f);
                                    let _e448 = hitUV;
                                    let _e449 = edgeFade;
                                    let _e451 = distance;
                                    let _e452 = global_1.controls;
                                    let _e461 = err;
                                    let _e462 = global_1.controls;
                                    return Hit(_e448, ((_e449 * (1f - clamp((_e451 / _e452.z), 0f, 1f))) * clamp((1f - (_e461 / max(_e462.w, 0.0001f))), 0f, 1f)));
                                }
                            }
                        }
                    }
                }
            }
            let _e473 = endT;
            let _e474 = epsilon;
            t_1 = (_e473 + _e474);
            let _e476 = top;
            let _e477 = level;
            level = min(_e476, (_e477 + 1i));
        }
        continuing {
            let _e149 = i;
            i = (_e149 + 1u);
        }
    }
    let _e481 = miss;
    return _e481;
}

fn main_1() {
    var px: vec2<i32>;
    var hdr: vec3<f32>;
    var surface_1: vec4<f32>;
    var depth_1: f32;
    var props: vec3<f32>;
    var rough: f32;
    var metal: f32;
    var reflectance: f32;
    var albedo: vec3<f32>;
    var uv_2: vec2<f32>;
    var pos: vec3<f32>;
    var N: vec3<f32>;
    var V: vec3<f32>;
    var nv: f32;
    var F0_: vec3<f32>;
    var F: vec3<f32>;
    var origin_2: vec3<f32>;
    var oldSpec: vec4<f32>;
    var oldDiff: vec4<f32>;
    var delta: vec3<f32> = vec3(0f);
    var hit: Hit;
    var brdf: vec2<f32>;
    var fss: vec3<f32>;
    var ems: f32;
    var favg: vec3<f32>;
    var factor: vec3<f32>;
    var reflected: vec3<f32>;
    var local_1: vec3<f32>;
    var tangent: vec3<f32>;
    var bitangent: vec3<f32>;
    var rays: u32;
    var j: u32 = 0u;
    var r: f32;
    var angle: f32;
    var dir: vec3<f32>;
    var hit_1: Hit;
    var diffuse: vec3<f32>;
    var result: vec3<f32>;

    let _e30 = gl_FragCoord_1;
    px = vec2<i32>(_e30.xy);
    let _e34 = px;
    let _e36 = textureLoad(zengy_u_hdr_image, _e34, 0i);
    hdr = _e36.xyz;
    let _e39 = px;
    let _e41 = textureLoad(zengy_u_surface_image, _e39, 0i);
    surface_1 = _e41;
    let _e43 = px;
    let _e45 = textureLoad(zengy_u_depth_image, _e43, 0i);
    depth_1 = _e45.x;
    let _e48 = surface_1;
    let _e52 = depth_1;
    let _e56 = global_1.budget;
    if (((_e48.z < 0f) || (_e52 >= 0.99999f)) || (_e56.x == 0u)) {
        {
            let _e61 = hdr;
            frag_color = vec4<f32>(_e61.x, _e61.y, _e61.z, 1f);
            return;
        }
    }
    let _e68 = surface_1;
    let _e70 = unpackRgb(_e68.z);
    props = _e70;
    let _e72 = props;
    rough = max(_e72.x, 0.045f);
    let _e77 = props;
    metal = _e77.y;
    let _e80 = props;
    reflectance = _e80.z;
    let _e83 = surface_1;
    let _e85 = unpackRgb(_e83.w);
    albedo = _e85;
    let _e87 = px;
    let _e94 = global_1.levels[0];
    uv_2 = ((vec2<f32>(_e87) + vec2(0.5f)) / vec2<f32>(_e94.yz));
    let _e99 = uv_2;
    let _e100 = depth_1;
    let _e101 = worldAt(_e99, _e100);
    pos = _e101;
    let _e103 = surface_1;
    let _e105 = decodeNormal(_e103.xy);
    N = _e105;
    let _e107 = global_1.camera_gain;
    let _e109 = pos;
    let _e111 = safeNormalize((_e107.xyz - _e109));
    V = _e111;
    let _e113 = N;
    let _e114 = V;
    nv = max(dot(_e113, _e114), 0f);
    let _e120 = reflectance;
    let _e122 = reflectance;
    let _e125 = albedo;
    let _e126 = metal;
    F0_ = mix(vec3(((0.16f * _e120) * _e122)), _e125, vec3(_e126));
    let _e130 = F0_;
    let _e132 = rough;
    let _e135 = F0_;
    let _e137 = F0_;
    let _e140 = nv;
    F = (_e130 + ((max(vec3((1f - _e132)), _e135) - _e137) * pow((1f - _e140), 5f)));
    let _e147 = pos;
    let _e148 = N;
    let _e150 = global_1.controls;
    origin_2 = (_e147 + (_e148 * max(0.025f, (_e150.w * 0.4f))));
    let _e158 = px;
    let _e160 = textureLoad(zengy_u_specular_image, _e158, 0i);
    oldSpec = _e160;
    let _e162 = px;
    let _e164 = textureLoad(zengy_u_diffuse_image, _e162, 0i);
    oldDiff = _e164;
    let _e170 = global_1.controls;
    let _e174 = rough;
    if ((_e170.x > 0f) && (_e174 < 0.65f)) {
        {
            let _e178 = origin_2;
            let _e179 = V;
            let _e181 = N;
            let _e183 = traceRay(_e178, reflect(-(_e179), _e181));
            hit = _e183;
            let _e185 = hit;
            if (_e185.confidence > 0f) {
                {
                    let _e189 = nv;
                    let _e190 = rough;
                    let _e193 = textureSampleLevel(zengy_u_brdf_image, zengy_u_brdf_sampler, vec2<f32>(_e189, _e190), 0f);
                    brdf = _e193.xy;
                    let _e196 = F0_;
                    let _e197 = brdf;
                    let _e200 = brdf;
                    fss = ((_e196 * _e197.x) + vec3(_e200.y));
                    let _e206 = brdf;
                    let _e209 = brdf;
                    ems = clamp(((1f - _e206.x) - _e209.y), 0f, 1f);
                    let _e216 = F0_;
                    let _e218 = F0_;
                    favg = (_e216 + ((vec3(1f) - _e218) / vec3(21f)));
                    let _e226 = fss;
                    let _e227 = ems;
                    let _e228 = fss;
                    let _e230 = favg;
                    let _e235 = ems;
                    let _e236 = favg;
                    factor = (_e226 + (((_e227 * _e228) * _e230) / max(vec3(0.0001f), (vec3(1f) - (_e235 * _e236)))));
                    let _e244 = hit;
                    let _e247 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, _e244.uv, 0f);
                    let _e249 = factor;
                    let _e251 = oldSpec;
                    reflected = ((_e247.xyz * _e249) * _e251.w);
                    let _e255 = delta;
                    let _e256 = reflected;
                    let _e257 = oldSpec;
                    let _e260 = hit;
                    let _e262 = global_1.controls;
                    let _e268 = rough;
                    delta = (_e255 + ((_e256 - _e257.xyz) * ((_e260.confidence * _e262.x) * (1f - smoothstep(0.15f, 0.65f, _e268)))));
                }
            }
        }
    }
    let _e274 = global_1.controls;
    let _e278 = metal;
    if ((_e274.y > 0f) && (_e278 < 0.99f)) {
        {
            let _e282 = N;
            if (abs(_e282.y) < 0.99f) {
                local_1 = vec3<f32>(0f, 1f, 0f);
            } else {
                local_1 = vec3<f32>(1f, 0f, 0f);
            }
            let _e302 = local_1;
            let _e303 = N;
            let _e305 = safeNormalize(cross(_e302, _e303));
            tangent = _e305;
            let _e307 = N;
            let _e308 = tangent;
            bitangent = cross(_e307, _e308);
            let _e311 = global_1.budget;
            rays = clamp(_e311.z, 1u, 4u);
            loop {
                let _e319 = j;
                let _e320 = rays;
                if !((_e319 < _e320)) {
                    break;
                }
                {
                    let _e326 = j;
                    let _e330 = rays;
                    r = sqrt(((f32(_e326) + 0.5f) / f32(_e330)));
                    let _e338 = px;
                    let _e340 = hash(vec2<f32>(_e338));
                    let _e341 = j;
                    angle = (6.2831855f * fract((_e340 + (f32(_e341) * 0.618034f))));
                    let _e349 = tangent;
                    let _e350 = r;
                    let _e351 = angle;
                    let _e355 = bitangent;
                    let _e356 = r;
                    let _e357 = angle;
                    let _e362 = N;
                    let _e364 = r;
                    let _e365 = r;
                    let _e371 = safeNormalize((((_e349 * (_e350 * cos(_e351))) + (_e355 * (_e356 * sin(_e357)))) + (_e362 * sqrt((1f - (_e364 * _e365))))));
                    dir = _e371;
                    let _e373 = origin_2;
                    let _e374 = dir;
                    let _e375 = traceRay(_e373, _e374);
                    hit_1 = _e375;
                    let _e377 = hit_1;
                    if (_e377.confidence > 0f) {
                        {
                            let _e381 = hit_1;
                            let _e384 = textureSampleLevel(zengy_u_hdr_image, zengy_u_hdr_sampler, _e381.uv, 0f);
                            let _e387 = F;
                            let _e392 = metal;
                            let _e395 = albedo;
                            let _e397 = oldDiff;
                            diffuse = ((((_e384.xyz * (vec3(1f) - _e387)) * (1f - _e392)) * _e395) * _e397.w);
                            let _e401 = delta;
                            let _e402 = diffuse;
                            let _e403 = oldDiff;
                            let _e406 = global_1.controls;
                            let _e408 = hit_1;
                            let _e411 = rays;
                            delta = (_e401 + ((_e402 - _e403.xyz) * ((_e406.y * _e408.confidence) / f32(_e411))));
                        }
                    }
                }
                continuing {
                    let _e323 = j;
                    j = (_e323 + 1u);
                }
            }
        }
    }
    let _e416 = hdr;
    let _e417 = delta;
    result = max((_e416 + _e417), vec3(0f));
    let _e424 = result;
    let _e425 = zy_isnan_2(_e424);
    let _e427 = result;
    let _e428 = zy_isinf_2(_e427);
    if (any(_e425) || any(_e428)) {
        let _e431 = hdr;
        result = _e431;
    }
    let _e432 = result;
    let _e439 = clamp(_e432, vec3(0f), vec3(65000f));
    frag_color = vec4<f32>(_e439.x, _e439.y, _e439.z, 1f);
    return;
}

@fragment 
fn main(@location(0) v_ndc: vec2<f32>, @builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    v_ndc_1 = v_ndc;
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e49 = frag_color;
    return FragmentOutput(_e49);
}
