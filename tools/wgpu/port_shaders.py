#!/usr/bin/env python3
"""Port the legacy GLSL renderer shaders to the WGSL files the engine ships.

Pipeline per shader: GLSL -> (convert_shaders: split samplers, NaN predicates) -> Naga -> WGSL -> bind group
remap. The remap moves the legacy SDL_GPU binding slots (set 2 = fragment resources, set 3 = fragment uniforms)
onto the engine's WebGPU layout:

* fullscreen fragment shaders: group 0 = textures/samplers/buffers, group 1 = uniforms
* pbr.frag: group 0 = material textures, group 1 = vertex uniforms, group 2 = frame resources, group 3 = fragment uniforms

The generated WGSL is checked in and becomes the source of truth; this script documents and reproduces the port.
Requires naga-cli 27.0.0 on PATH.
"""
from __future__ import annotations
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_shaders as cs  # noqa: E402

SRC = 'packages/graphics/sdlgpu/src/shaders'
OUT = 'packages/render/3d/src/gpu/shaders'
SUFFIX = {'.vert': '_vs', '.frag': '_fs', '.comp': '_cs'}
STAGE = {'.vert': 'vert', '.frag': 'frag', '.comp': 'comp'}
DECL = re.compile(r'@group\((\d+)\)\s*@binding\((\d+)\)')

# Material textures and their samplers move out of the frame group so they can be cached per material.
PBR_MATERIAL = {0, 1, 2, 8, 9, 32, 33, 34, 40, 41}


def remap_fullscreen(group: int, binding: int):
    return {2: 0, 3: 1}.get(group, group), binding


def remap_pbr(group: int, binding: int):
    if group == 2 and binding in PBR_MATERIAL:
        return 0, binding
    return group, binding


def remap_identity(group: int, binding: int):
    return group, binding


# Shaders that keep the legacy numbering (their vertex stage already occupies group 1).
REMAPS = {
    'pbr.frag': remap_pbr,
    'pbr.vert': remap_identity,
    'shadow.vert': remap_identity,
    'shadow.frag': remap_identity,
    'shadow_mask.frag': remap_identity,
    'auto_exposure_adapt.comp': remap_identity,
    'hiz_reduce.comp': remap_identity,
    'dynamic_gi.comp': remap_identity,
}

# Shaders the 2D/unlit/gizmo renderers replace with hand-written WGSL, or that need a manual port.
SKIP = {'auto_exposure_hist.comp', 'textured.vert', 'textured.frag', 'pos_color.vert', 'pos_color.frag',
        'mesh_unlit.vert', 'mesh_unlit.frag', 'gizmo.vert', 'gizmo.frag'}


def port_one(repo: Path, src: Path, naga: str) -> tuple[str, list]:
    text, bindings = cs.split_samplers(cs.replace_nan_checks(src.read_text(encoding='utf-8')))
    with tempfile.TemporaryDirectory() as tmp:
        glsl = Path(tmp) / src.name
        glsl.write_text(text, encoding='utf-8')
        wgsl = Path(tmp) / (src.name + '.wgsl')
        for command in ([naga, '--input-kind', 'glsl', '--shader-stage', STAGE[src.suffix], str(glsl), str(wgsl)], [naga, str(wgsl)]):
            result = subprocess.run(command, text=True, capture_output=True, timeout=120)
            if result.returncode:
                raise RuntimeError((result.stdout + '\n' + result.stderr).strip())
        out = wgsl.read_text(encoding='utf-8')
    remap = REMAPS.get(src.name, remap_fullscreen)
    used = []

    def sub(match):
        g, b = remap(int(match[1]), int(match[2]))
        used.append((int(match[1]), int(match[2]), g, b))
        return f'@group({g}) @binding({b})'

    out = DECL.sub(sub, out)
    # Naga maps GLSL barrier() to subgroupBarrier(), which needs the optional Subgroups feature. GLSL's barrier()
    # is a workgroup barrier, so emit the portable WGSL equivalent.
    out = out.replace('subgroupBarrier();', 'workgroupBarrier();')
    # Fail loudly if the remap produced two variables with the same slot.
    slots = [(g, b) for _, _, g, b in used]
    if len(slots) != len(set(slots)):
        raise RuntimeError(f'{src.name}: bind group remap collided: {sorted(slots)}')
    header = f'// Ported from {src.name} (GLSL) with Naga 27.0.0; bind groups remapped by tools/wgpu/port_shaders.py.\n'
    return header + out, used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path('.'))
    parser.add_argument('--naga', default='naga')
    parser.add_argument('--only', nargs='*', help='Port only these source file names')
    args = parser.parse_args()
    if not shutil.which(args.naga):
        parser.error('Install naga-cli 27.0.0: cargo install naga-cli --version 27.0.0 --locked')
    repo = args.repo.resolve()
    out_dir = repo / OUT
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {}
    failures = 0
    for src in sorted((repo / SRC).iterdir()):
        if src.suffix not in SUFFIX or src.name in SKIP or (args.only and src.name not in args.only):
            continue
        name = src.stem + SUFFIX[src.suffix] + '.wgsl'
        try:
            text, used = port_one(repo, src, args.naga)
            (out_dir / name).write_text(text, encoding='utf-8', newline='\n')
            report[name] = [{'from': [a, b], 'to': [c, d]} for a, b, c, d in used]
            print('ported', src.name, '->', name)
        except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            failures += 1
            print('FAILED', src.name, str(exc)[:300].replace('\x1b', ''))
    (out_dir / 'bindings.json').write_text(json.dumps(report, indent=1), encoding='utf-8', newline='\n')
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
