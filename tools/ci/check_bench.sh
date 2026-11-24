#!/bin/sh
# Fails when a benchmark regresses past a generous threshold (about 8x the measured baseline in
# docs/benchmarks-baseline.md, to absorb noisy shared CI runners). Usage: check_bench.sh bench.txt
set -eu
file="${1:?usage: check_bench.sh <bench-output.txt>}"
status=0

# check <label> <grep pattern> <awk expression extracting a number from the line> <max> <unit>
check() {
    label="$1"; pattern="$2"; expr="$3"; max="$4"; unit="$5"
    line=$(grep -E "$pattern" "$file" | head -n 1 || true)
    if [ -z "$line" ]; then
        echo "FAIL  $label: no benchmark line matching '$pattern'"; status=1; return
    fi
    value=$(echo "$line" | awk "$expr")
    if awk -v v="$value" -v m="$max" 'BEGIN { exit !(v > m) }'; then
        echo "FAIL  $label: $value $unit > $max $unit  ($line)"; status=1
    else
        echo "ok    $label: $value $unit (limit $max)"
    fi
}

check "despawn, 400 registered types"   '^7\. Despawn \(400 '            '{ for (i=1;i<=NF;i++) if ($i=="ns/entity") print $(i-1) }' 200 "ns/entity"
check "propagate, chain depth 8000"      '^8\. Scene2D propagate'         '{ for (i=1;i<=NF;i++) if ($i=="ms") print $(i-1) }' 20 "ms"
check "CommandBuffer.apply"              '^9\. CommandBuffer.apply'       '{ for (i=1;i<=NF;i++) if ($i=="ns/entity") print $(i-1) }' 1500 "ns/entity"
check "incremental propagate, idle"      '^10\. Incremental'              '{ for (i=1;i<=NF;i++) if ($i=="idle") print $(i+1) }' 1 "ms"

# Parallel speedup must be real on a multi-core runner (baseline ~2.5x on 4 cores).
line=$(grep -E '^11\. Parallel' "$file" | head -n 1 || true)
if [ -n "$line" ]; then
    speedup=$(echo "$line" | sed -E 's/.*\(([0-9.]+)x\).*/\1/')
    cores=$(nproc 2>/dev/null || echo 1)
    if [ "$cores" -ge 4 ] && awk -v v="$speedup" 'BEGIN { exit !(v < 1.3) }'; then
        echo "FAIL  parallel speedup ${speedup}x < 1.3x on $cores cores"; status=1
    else
        echo "ok    parallel speedup ${speedup}x ($cores cores)"
    fi
else
    echo "FAIL  parallel benchmark line missing"; status=1
fi
exit "$status"
