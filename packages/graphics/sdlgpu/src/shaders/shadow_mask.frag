#version 450

layout(location = 0) in vec2 v_uv;

layout(set = 2, binding = 0) uniform sampler2D u_base_color_tex;

layout(std140, set = 3, binding = 0) uniform ShadowMaskParams {
    vec4 base_color; // material base color factor (tint included); alpha multiplies the texture alpha
    vec4 params;     // x = alpha cutoff
};

// Same alpha rule as pbr.frag so casters and shaded surfaces agree on which texels are holes.
void main() {
    float alpha = texture(u_base_color_tex, v_uv).a * base_color.a;
    if (alpha < params.x) {
        discard;
    }
}
