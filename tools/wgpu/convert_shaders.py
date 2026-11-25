#!/usr/bin/env python3
"""Generate validated WGSL candidates, never overwrite live renderer shaders.

Requires Naga CLI 27.0.3. GLSL combined samplers are split into image/sampler
pairs before parsing. The emitted binding map is a contract for the host port,
not a claim that the old SDL binding code can be reused unchanged.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

COMBINED = re.compile(r"layout\s*\((?P<layout>[^()]+)\)\s*uniform\s+(?P<kind>sampler2DShadow|sampler2D|samplerCubeShadow|samplerCube|sampler2DArrayShadow|sampler2DArray)\s+(?P<name>[A-Za-z_]\w*)\s*;")
BINDING = re.compile(r"\bbinding\s*=\s*(\d+)")
GROUP = re.compile(r"\bset\s*=\s*(\d+)")
COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
STAGES = {".vert", ".frag", ".comp"}

def split_samplers(source: str):
    # Leave comments intact, but mask them while finding declarations.
    masked = COMMENTS.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), source)
    occupied = set()
    for layout in re.findall(r"layout\s*\(([^()]+)\)", masked):
        group, binding = GROUP.search(layout), BINDING.search(layout)
        if group and binding:
            occupied.add((int(group[1]), int(binding[1])))
    edits, bindings = [], []
    for match in COMBINED.finditer(masked):
        group, binding = GROUP.search(match['layout']), BINDING.search(match['layout'])
        if not group or not binding:
            raise ValueError("Combined sampler lacks explicit set/binding")
        g, b = int(group[1]), int(binding[1]); name, kind = match['name'], match['kind']
        sampler_b = 32 + b
        while (g, sampler_b) in occupied:
            sampler_b += 1
        if sampler_b > 999:
            raise ValueError("Binding allocation exceeded WebGPU candidate range")
        occupied.add((g,sampler_b))
        shadow = kind.endswith("Shadow")
        shape = kind.removeprefix('sampler').removesuffix('Shadow')
        image = f"zengy_{name}_image"; sampler = f"zengy_{name}_sampler"
        if re.search(rf"\b(?:{image}|{sampler})\b", masked):
            raise ValueError(f"Generated name collision: {name}")
        # GLSL separate shadow samplers still use the sampler type; the constructor
        # carries the comparison semantics. Naga decides the resulting WGSL type.
        replacement = (f"\nlayout(set={g}, binding={b}) uniform texture{shape} {image};\n"
                       f"layout(set={g}, binding={sampler_b}) uniform sampler {sampler};\n"
                       f"#define {name} {kind}({image}, {sampler})\n")
        edits.append((match.start(),match.end(),replacement))
        bindings.append(dict(name=name,group=g,texture_binding=b,sampler_binding=sampler_b,comparison=shadow))
    for start,end,replacement in reversed(edits):
        source=source[:start]+replacement+source[end:]
    return source,bindings

def convert(repo: Path, output: Path, naga: str):
    shaders=repo/'packages/graphics/sdlgpu/src/shaders'
    if not shaders.is_dir(): raise ValueError(f"Missing shader directory: {shaders}")
    if output.exists(): raise FileExistsError(f"Output already exists: {output}")
    output.mkdir(parents=True)
    report=[]
    for src in sorted(shaders.iterdir()):
        if src.suffix not in STAGES or not src.is_file(): continue
        entry={'source':src.relative_to(repo).as_posix(),'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest()}
        dest=output/(src.name+'.wgsl')
        try:
            text,bindings=split_samplers(src.read_text(encoding='utf-8'))
            entry['bindings']=bindings
            with tempfile.TemporaryDirectory() as tmp:
                intermediate=Path(tmp)/src.name
                intermediate.write_text(text,encoding='utf-8')
                candidate=Path(tmp)/dest.name
                for command in ([naga,str(intermediate),str(candidate)],[naga,str(candidate)]):
                    result=subprocess.run(command,text=True,capture_output=True,timeout=120)
                    if result.returncode: raise RuntimeError((result.stdout+'\n'+result.stderr).strip())
                shutil.copyfile(candidate,dest)
            entry['status']='validated_candidate'
        except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as exc:
            entry.update(status='manual_port_required',error=str(exc))
        report.append(entry)
    (output/'migration-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    failed=sum(e['status']!='validated_candidate' for e in report)
    print(f"{len(report)-failed}/{len(report)} shaders converted; {failed} require manual work")
    return int(not report or failed>0)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--naga',default='naga')
    args=parser.parse_args()
    if not shutil.which(args.naga): parser.error('Install naga-cli 27.0.3 or pass --naga')
    return convert(args.repo.resolve(),args.output.resolve(),args.naga)
if __name__=='__main__': raise SystemExit(main())
