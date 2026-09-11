#!/bin/sh
# Run every implemented benchmark on every visible Metal device and collect
# JSON output under build/results/. Intended to be run on a machine with MPX
# hardware; on other machines the tools degrade gracefully and record reduced
# results.
#
# Runtime note: the per-pair peer matrix is by far the longest part (several
# minutes per pair). Set PEER=0 to skip the pairwise matrix, PEER_PATH to
# override the route (default p2p; use e.g. 'both' for the legacy IOSurface
# staging matrix), MTL_BENCH=0 to skip mtl-bench.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/results

PEER=${PEER:-1}
PEER_PATH=${PEER_PATH:-p2p}
MTL_BENCH=${MTL_BENCH:-1}
RUN="swift run --package-path tools"

echo "==> gpu-probe"
$RUN gpu-probe --json > build/results/gpu-probe.json

echo "==> if-bench device list"
$RUN if-bench -- --list-devices --json > build/results/if-bench-devices.json
device_count=$(python3 -c 'import json,sys
print(len(json.load(open("build/results/if-bench-devices.json"))["devices"]))')
echo "found $device_count Metal device(s)"

# Per-device sweeps: local bandwidth/latency + host directions, one file
# per device. --device-b is unset so nothing spills onto a second GPU.
d=0
while [ "$d" -lt "$device_count" ]; do
  echo "==> if-bench dev$d (local bw/latency + host)"
  $RUN if-bench -- --device-a "$d" --mode bw,latency,host --json \
      > build/results/if-bench-dev"$d".json
  d=$((d + 1))
done

# Pairwise peer matrix over all unordered device pairs. Default route is
# peer-group p2p (fastest on MPX hives; pairs outside a common peer group
# note-and-skip inside the tool). Set PEER_PATH=blit (or both/all) to sweep
# the IOSurface staging route instead — that is the fallback for cross-hive
# pairs and where the published staging numbers come from.
if [ "$PEER" = "1" ]; then
  a=0
  while [ "$a" -lt "$device_count" ]; do
    b=$((a + 1))
    while [ "$b" -lt "$device_count" ]; do
      echo "==> if-bench peer ($PEER_PATH) dev$a <-> dev$b"
      $RUN if-bench -- --device-a "$a" --device-b "$b" --mode peer \
          --peer-path "$PEER_PATH" --json \
          > build/results/if-bench-peer-"$PEER_PATH"-"$a"-"$b".json
      b=$((b + 1))
    done
    a=$((a + 1))
  done
else
  echo "==> skipping peer pair matrix (PEER=0)"
fi

if [ "$MTL_BENCH" = "1" ] && [ -x build/tools/mtl-bench/mtl-bench ]; then
  d=0
  while [ "$d" -lt "$device_count" ]; do
    echo "==> mtl-bench dev$d"
    build/tools/mtl-bench/mtl-bench --device "$d" --json \
        > build/results/mtl-bench-dev"$d".json 2>/dev/null
    d=$((d + 1))
  done
else
  echo "==> skipping mtl-bench (run 'make ccpp' first, or unset MTL_BENCH)"
fi

echo "results written to build/results/"
