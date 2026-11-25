#!/usr/bin/env python3
"""Inventory direct SDL GPU dependencies and shaders in the actual checkout."""
import argparse, json, re, subprocess
from pathlib import Path
PATTERNS={'sdl_gpu_api':r'\bSDL_[A-Za-z0-9_]*GPU[A-Za-z0-9_]*\b','sdlgpu_module':r'\bgraphics_sdlgpu\b|official\.graphics\.sdlgpu|graphics/sdlgpu','spirv':r'\.spv\b|SHADERFORMAT_SPIRV','render_contract':r'\b(?:PbrBackendVTable|GizmoBackendVTable|BackendVTable)\b'}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--repo',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args();repo=a.repo.resolve()
    paths=subprocess.check_output(['git','ls-files','-z'],cwd=repo).decode().split('\0'); results=[]
    for relative in paths:
        file=repo/relative
        if file.suffix not in {'.zig','.zon','.c','.h','.md','.yml','.yaml','.py','.json','.toml','.vert','.frag','.comp'} or relative.startswith('packages/sdl3/') or relative.startswith('packages/graphics/wgpu/') or not file.is_file():continue
        if file.stat().st_size>4*1024*1024:continue
        text=file.read_text(encoding='utf-8',errors='replace');match={}
        for key,pat in PATTERNS.items():
            lines=[i for i,line in enumerate(text.splitlines(),1) if re.search(pat,line)]
            if lines:match[key]=lines
        if match or file.suffix in {'.vert','.frag','.comp'}:results.append({'path':relative,'matches':match,'shader':file.suffix in {'.vert','.frag','.comp'}})
    with a.output.open('x',encoding='utf-8') as out:json.dump(results,out,indent=2)
    print(f'{len(results)} tracked migration candidates; report: {a.output}')
if __name__=='__main__':main()
