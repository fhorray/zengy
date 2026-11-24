#version 450

layout(location = 0) in vec2 v_ndc;

layout(set = 2, binding = 0) uniform sampler2D u_src;

layout(std140, set = 3, binding = 0) uniform BloomUpParams {
    vec4 texel_scatter; // xy=1/src_size, z=scatter
};

layout(location = 0) out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_ndc.x * 0.5 + 0.5, 0.5 - v_ndc.y * 0.5);
    vec2 t = texel_scatter.xy * texel_scatter.z;

    vec3 s = vec3(0.0);
    s += texture(u_src, uv + vec2(-t.x, -t.y)).rgb * 1.0;
    s += texture(u_src, uv + vec2( 0.0, -t.y)).rgb * 2.0;
    s += texture(u_src, uv + vec2( t.x, -t.y)).rgb * 1.0;
    s += texture(u_src, uv + vec2(-t.x,  0.0)).rgb * 2.0;
    s += texture(u_src, uv).rgb * 4.0;
    s += texture(u_src, uv + vec2( t.x,  0.0)).rgb * 2.0;
    s += texture(u_src, uv + vec2(-t.x,  t.y)).rgb * 1.0;
    s += texture(u_src, uv + vec2( 0.0,  t.y)).rgb * 2.0;
    s += texture(u_src, uv + vec2( t.x,  t.y)).rgb * 1.0;
    frag_color = vec4(s / 16.0, 1.0);
}
