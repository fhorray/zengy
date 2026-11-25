#!/usr/bin/env python3
"""Lightweight architecture guard for zengy (see docs/adr/ADR-008-application-package-boundaries.md).

Checks, without modifying any file:
  * core (`src/`) does not import packages/apps/tools/examples through build wiring or relative paths;
  * packages do not depend on apps, tools, examples, projects, benchmarks or tests;
  * apps and tools do not import each other's sources;
  * no production module dependency cycles;
  * every `b.path("....zig")` root and every `addModuleTest("....zig")` root in build.zig and build/*.zig exists;
  * every CLI catalog entry (OFFICIAL_PACKAGES / packageDir) resolves to an existing file.

Limits: only `const x = b.addModule/createModule(...)` roots and `x.addImport("n", y)` edges are
resolved (build.zig and build/*.zig are read together, so local aliases must keep one name).
Imports of locally defined third-party modules (translate-c, dependencies) are treated as external;
imports of names never defined in the build files are printed as "unclassified". Neither fails the run. Test modules
(passed to addModuleTest) are not part of the production graph and may import any layer.

Usage: check_architecture.py [repo_root]    |    check_architecture.py --self-test
"""
import os
import re
import sys
import tempfile

LAYERS = ["src", "packages", "apps", "tools", "examples", "projects", "benchmarks", "tests"]
# layer -> layers it must not depend on in production code
FORBIDDEN = {
    "src": {"packages", "apps", "tools", "examples", "projects", "benchmarks", "tests"},
    "packages": {"apps", "tools", "examples", "projects", "benchmarks", "tests"},
    "apps": {"tools", "examples", "projects", "benchmarks", "tests"},
    "tools": {"apps", "examples", "projects", "benchmarks", "tests"},
}


def layer_of(path):
    """Top-level layer of a repo-relative posix path ('' for build-level files)."""
    top = path.split("/", 1)[0]
    return top if top in LAYERS else ""


def read_build(root):
    """Concatenated text of build.zig and build/*.zig ('' if build.zig is missing)."""
    paths = [os.path.join(root, "build.zig")]
    bdir = os.path.join(root, "build")
    if os.path.isdir(bdir):
        paths += [os.path.join(bdir, f) for f in sorted(os.listdir(bdir)) if f.endswith(".zig")]
    return "\n".join(open(p, encoding="utf-8").read() for p in paths if os.path.isfile(p))


def parse_build(text):
    mods = {}
    known = set(re.findall(r"^\s*const (\w+_mod) = ", text, re.M))
    for m in re.finditer(r"const (\w+) = b\.(?:addModule|createModule)\((?:\"\w+\", )?\.\{(.*?)\n    \}\);", text, re.S):
        r = re.search(r'root_source_file = b\.path\("([^"]+)"\)', m.group(2))
        if r:
            mods[m.group(1)] = r.group(1)
    edges, unclassified = [], []
    for m in re.finditer(r'(\w+)\.addImport\("(\w+)", (\w+)\);', text):
        src, _, dst = m.groups()
        if src in mods and dst in mods:
            edges.append((src, dst))
        elif (src in mods or dst in mods) and not (src in known and dst in known):
            unclassified.append(m.group(0))
    return mods, edges, unclassified


def find_cycle(mods, edges):
    graph = {m: [] for m in mods}
    for a, b in edges:
        graph[a].append(b)
    state, stack = {}, []

    def dfs(n):
        state[n] = 1
        stack.append(n)
        for d in graph[n]:
            if state.get(d) == 1:
                return stack[stack.index(d):] + [d]
            if d not in state:
                c = dfs(d)
                if c:
                    return c
        stack.pop()
        state[n] = 2
        return None

    for n in graph:
        if n not in state:
            c = dfs(n)
            if c:
                return c
    return None


def check_sources(root, errors):
    """Relative `@import("....zig")` that escapes into a forbidden layer (tests dirs excluded)."""
    for layer, forbidden in FORBIDDEN.items():
        base = os.path.join(root, layer)
        for dp, dn, fn in os.walk(base):
            rel_dir = os.path.relpath(dp, root).replace(os.sep, "/")
            if "/tests" in "/" + rel_dir + "/" or "third_party" in rel_dir or ".zig-cache" in rel_dir:
                continue
            for f in fn:
                if not f.endswith(".zig"):
                    continue
                rel = f"{rel_dir}/{f}"
                for i, line in enumerate(open(os.path.join(dp, f), encoding="utf-8", errors="replace"), 1):
                    if line.lstrip().startswith("//"):
                        continue
                    for imp in re.findall(r'@import\("([^"]+\.zig)"\)', line):
                        target = os.path.normpath(os.path.join(rel_dir, imp)).replace(os.sep, "/")
                        tl = layer_of(target)
                        if target.startswith("..") or (tl and tl != layer and tl in forbidden):
                            errors.append(f"{rel}:{i}: '{layer}' source imports '{target}' (layer '{tl or 'outside repo'}')")


def check_catalog(root, errors):
    p = os.path.join(root, "tools/cli/catalog.zig")
    if not os.path.isfile(p):
        return
    text = open(p, encoding="utf-8").read()
    dirs = dict(re.findall(r'\.\{ "([\w-]+)", "([\w/]+)" \},', text))
    for name, entry in re.findall(r'\.name = "([\w-]+)", \.entry = "([^"]+)"', text):
        f = f"packages/{dirs.get(name, name)}/{entry}"
        if not os.path.isfile(os.path.join(root, f)):
            errors.append(f"tools/cli/catalog.zig: official package '{name}' maps to missing file {f}")


def check(root):
    errors, notes = [], []
    text = read_build(root)
    if text:
        roots = set(re.findall(r'b\.path\("([^"]+\.zig)"\)', text))
        roots |= set(re.findall(r'addModuleTest\(b, \w+, "([^"]+\.zig)"', text))
        for path in sorted(roots):
            if not os.path.isfile(os.path.join(root, path)):
                errors.append(f"build: root '{path}' does not exist")
        mods, edges, unclassified = parse_build(text)
        notes += [f"unclassified edge: {u}" for u in unclassified]
        for a, b in edges:
            la, lb = layer_of(mods[a]), layer_of(mods[b])
            if la in FORBIDDEN and lb in FORBIDDEN[la]:
                errors.append(f"build: {la} module '{a}' ({mods[a]}) imports {lb} module '{b}' ({mods[b]})")
        cyc = find_cycle(mods, edges)
        if cyc:
            errors.append("build: module dependency cycle: " + " -> ".join(cyc))
    check_sources(root, errors)
    check_catalog(root, errors)
    return errors, notes


def self_test():
    def make(files):
        d = tempfile.mkdtemp()
        for p, c in files.items():
            fp = os.path.join(d, p)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            open(fp, "w").write(c)
        return d

    def build(extra=""):
        return (
            'const engine_mod = b.addModule("engine", .{\n        .root_source_file = b.path("src/engine.zig"),\n    });\n'
            'const pkg_mod = b.addModule("pkg", .{\n        .root_source_file = b.path("packages/pkg/src/pkg.zig"),\n    });\n'
            'const app_mod = b.createModule(.{\n        .root_source_file = b.path("apps/ed/src/app.zig"),\n    });\n'
            'pkg_mod.addImport("engine", engine_mod);\napp_mod.addImport("pkg", pkg_mod);\n' + extra
        )

    base = {"src/engine.zig": "", "packages/pkg/src/pkg.zig": "", "apps/ed/src/app.zig": "",
            "apps/ed/tests/int_tests.zig": '@import("../../../packages/pkg/src/pkg.zig")'}
    cases = [
        ("valid graph and legitimate app integration test", dict(base, **{"build.zig": build()}), False),
        ("package imports application", dict(base, **{"build.zig": build('pkg_mod.addImport("app", app_mod);\n')}), True),
        ("core imports package", dict(base, **{"build.zig": build('engine_mod.addImport("pkg", pkg_mod);\n')}), True),
        ("missing build root", dict(base, **{"build.zig": build('const x = b.path("apps/gone/main.zig");\n')}), True),
        ("package source escapes into apps", dict(base, **{"build.zig": build(), "packages/pkg/src/pkg.zig": '@import("../../../apps/ed/src/app.zig")'}), True),
        ("split build layout: package imports application", dict(base, **{"build.zig": "", "build/modules.zig": build('pkg_mod.addImport("app", app_mod);\n')}), True),
        ("split build layout: valid", dict(base, **{"build.zig": "", "build/modules.zig": build()}), False),
        ("external third-party import is not a violation", dict(base, **{"build.zig": build('const c_mod = b.createModule(.{});\npkg_mod.addImport("c", c_mod);\n')}), False),
        ("missing test root", dict(base, **{"build.zig": build('addModuleTest(b, test_step, "apps/gone/tests/x_tests.zig", target)\n')}), True),
        ("dependency cycle", dict(base, **{"build.zig": build('pkg_mod.addImport("x", app_mod);\n')}), True),
    ]
    failed = 0
    for name, files, expect_fail in cases:
        errs, _ = check(make(files))
        ok = bool(errs) == expect_fail
        failed += not ok
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f" -> {errs}"))
    return 1 if failed else 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    errors, notes = check(os.path.abspath(root))
    for n in notes:
        print("note:", n)
    for e in errors:
        print("error:", e)
    print(f"architecture check: {len(errors)} violation(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
