# Shaders (`packages/graphics/sdlgpu/src/shaders/`)

All shaders are authored in GLSL 450 and precompiled offline to SPIR-V (`.spv`) using `glslangValidator` and validated with `spirv-val`.

## Compiling SPIR-V

```bash
glslangValidator -V pos_color.vert -o pos_color.vert.spv
glslangValidator -V pos_color.frag -o pos_color.frag.spv
glslangValidator -V textured.vert -o textured.vert.spv
glslangValidator -V textured.frag -o textured.frag.spv
glslangValidator -V mesh_unlit.vert -o mesh_unlit.vert.spv
glslangValidator -V mesh_unlit.frag -o mesh_unlit.frag.spv
```

## Cross-compiling for D3D12 (DXIL) and Metal (MSL)

When targeting Windows machines without Vulkan drivers or macOS Metal, use [`SDL_shadercross`](https://github.com/libsdl-org/SDL_shadercross):

```bash
shadercross pos_color.vert.spv -o pos_color.vert.dxil
shadercross pos_color.vert.spv -o pos_color.vert.msl
```
