#!/bin/sh
# Sandbox test for zengy on macOS/Linux (POSIX counterpart of project.bat).
#
#   sh project.sh <project> [ticks] [--nobuild]
#
# Steps:
#   1. zig build -Doptimize=ReleaseSafe            (CLI + runtime; plugins are built in ReleaseSafe too)
#   2. zengy add --fork=<root> <spec>             for each line of projects/<project>/plugins.txt
#   3. zengy install                              reads projects/<project>/game.toml (second install path)
#   4. zengy-runtime --headless --ticks N         must print status ok and physics_backend true
# Exit code 0 only if every step passes.
set -eu

# `pwd -W` gives a Windows path under Git Bash (the zengy CLI cannot open /f/... paths); plain pwd elsewhere.
ROOT=$(cd "$(dirname "$0")" && { pwd -W 2>/dev/null || pwd; })
BIN="$ROOT/zig-out/bin"
NAME=${1:-}
TICKS=${2:-60}
NOBUILD=${3:-}

usage() {
    echo "Usage: sh project.sh <project> [ticks] [--nobuild]"
    echo "Projects:"
    for d in "$ROOT"/projects/*/; do
        [ -f "$d/game.toml" ] && echo "  $(basename "$d")"
    done
    exit 1
}

[ -n "$NAME" ] || usage
PROJ="$ROOT/projects/$NAME"
[ -f "$PROJ/game.toml" ] || { echo "[test] '$NAME' is not a project (no game.toml in $PROJ)"; usage; }

if [ "$NOBUILD" != "--nobuild" ]; then
    echo "[test] zig build -Doptimize=ReleaseSafe"
    (cd "$ROOT" && zig build -Doptimize=ReleaseSafe) || { echo "[test] FAILED: build"; exit 1; }
fi

cd "$PROJ"

if [ -f plugins.txt ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')   # tolerate CRLF files (Windows checkouts)
        case "$line" in ''|\#*) continue ;; esac
        echo "[test] zengy add $line"
        "$BIN/zengy" add --fork="$ROOT" "$line" || { echo "[test] FAILED: zengy add $line"; exit 1; }
    done < plugins.txt
fi

echo "[test] zengy install (from game.toml)"
"$BIN/zengy" install --fork="$ROOT" || { echo "[test] FAILED: zengy install"; exit 1; }

echo "[test] zengy-runtime --headless --ticks $TICKS"
# The runtime reports its JSON on stderr (std.debug.print), so capture both streams.
OUT=$("$BIN/zengy-runtime" --headless --ticks "$TICKS" 2>&1) || { echo "[test] FAILED: runtime exited non-zero"; echo "$OUT"; exit 1; }
echo "$OUT"

# Field order in the runtime JSON is not guaranteed, so check each field on its own.
case "$OUT" in *'"status":"ok"'*) ;; *) echo "[test] FAILED: runtime status is not ok"; exit 1 ;; esac
case "$OUT" in *'"physics_backend":true'*) ;; *) echo "[test] FAILED: no active physics backend"; exit 1 ;; esac
echo "[test] OK"
