#!/usr/bin/env python3
"""Install verified wgpu-native binaries from the pinned upstream release."""
import argparse, hashlib, platform, shutil, stat, tempfile, urllib.request, zipfile
from pathlib import Path, PurePosixPath
VERSION='v27.0.4.1'
ASSETS={
 'windows-x86_64-gnu':'9c6db90b01f45c95d209d33f19d242aa7936cb86956b3d4f6a151bbe3b5cb451',
 'windows-x86_64-msvc':'cbb15ac6499476bd555190922142a466ba91ec9032cc6bef5e59063e829425ea',
 'windows-aarch64-msvc':'c43c0225167ee12a0ed030ea15d7016ac7ee597c0728a2394580f7bf33e0a64d',
 'linux-x86_64':'9385b8a9e4e6f0b00264757577511097104fedf6db7819aa3e34a106c3dc0a42',
 'linux-aarch64':'0d8b0172ccc811a811d6813c2d97e0a7e89926f8f618694b595a8c9f7f89e059',
 'macos-x86_64':'57d87ce7c153623929518f02e176593856a467a8e120dd3354df20804329c63b',
 'macos-aarch64':'214fa6aa3a6d011643f1dcbc5a971db6f9d110f97f94a4c0b7e1e31271ef3b00',
}
def host():
    arch={'AMD64':'x86_64','x86_64':'x86_64','arm64':'aarch64','ARM64':'aarch64','aarch64':'aarch64'}.get(platform.machine(),platform.machine())
    system={'Windows':'windows','Linux':'linux','Darwin':'macos'}.get(platform.system(),platform.system().lower())
    return system+'-'+arch+('-gnu' if system=='windows' and arch=='x86_64' else '-msvc' if system=='windows' else '')
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target',choices=ASSETS,default=host())
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--archive',type=Path,help='Verify a previously downloaded archive instead of using the network')
    args=parser.parse_args(); out=args.output.resolve()
    if args.target not in ASSETS:parser.error('Unsupported host; choose --target explicitly')
    if out.exists():raise FileExistsError(out)
    out.parent.mkdir(parents=True,exist_ok=True)
    name=f'wgpu-{args.target}-release.zip'
    with tempfile.TemporaryDirectory(dir=out.parent,prefix='wgpu-install-') as tmp:
        tmp=Path(tmp); source=args.archive or tmp/name
        if not args.archive:
            url=f'https://github.com/gfx-rs/wgpu-native/releases/download/{VERSION}/{name}'
            print(url)
            with urllib.request.urlopen(url,timeout=120) as response,source.open('wb') as dest:shutil.copyfileobj(response,dest)
        with source.open('rb') as stream:actual=hashlib.file_digest(stream,'sha256').hexdigest()
        if actual!=ASSETS[args.target]:raise ValueError(f'Archive SHA256 mismatch: {actual}')
        stage=tmp/'sdk';stage.mkdir()
        with zipfile.ZipFile(source) as archive:
            if archive.testzip():raise ValueError('Corrupt SDK archive')
            for entry in archive.infolist():
                path=PurePosixPath(entry.filename)
                if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or ':' in entry.filename or stat.S_ISLNK(entry.external_attr>>16):raise ValueError(f'Unsafe SDK entry: {entry.filename}')
                archive.extract(entry,stage)
        for header in ('webgpu.h','wgpu.h'):
            if not (stage/'include'/'webgpu'/header).is_file():raise ValueError(f'Missing expected header {header}; SDK layout differs')
        if not (stage/'lib').is_dir():raise ValueError('Missing SDK lib directory')
        (stage/'zengy-wgpu-version.txt').write_text(f'{VERSION}\n{args.target}\nsha256:{actual}\n')
        stage.rename(out)
    print(f'Installed {VERSION} at {out}')
if __name__=='__main__':main()
