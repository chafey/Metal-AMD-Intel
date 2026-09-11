#!/bin/sh
# Run every implemented benchmark and collect JSON output under build/results/.
# Intended to be run on a machine with MPX hardware; on other machines the
# tools degrade gracefully and record reduced results.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/results

echo "==> gpu-probe"
swift run --package-path tools gpu-probe --json > build/results/gpu-probe.json

echo "==> if-bench"
swift run --package-path tools if-bench -- --json > build/results/if-bench.json

if [ -x build/tools/mtl-bench/mtl-bench ]; then
  echo "==> mtl-bench"
  build/tools/mtl-bench/mtl-bench --json > build/results/mtl-bench.json 2>/dev/null
else
  echo "==> skipping mtl-bench (run 'make ccpp' first)"
fi

echo "results written to build/results/"
