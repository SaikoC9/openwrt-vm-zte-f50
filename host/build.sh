#!/usr/bin/env bash
# Host-side binaries (VMM and helpers). Usage: host/build.sh OUTDIR
# Runs every host/<component>/build.sh OUTDIR. A component builds itself,
# static aarch64, and copies its binaries into OUTDIR (vmm/ = cloud-hypervisor).
set -euo pipefail
OUTDIR=${1:?usage: host/build.sh OUTDIR}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
found=0
for s in "$HERE"/*/build.sh; do
  [ -f "$s" ] || continue
  found=1
  echo "==> host/$(basename "$(dirname "$s")")"
  bash "$s" "$OUTDIR"
done
[ "$found" = 1 ] || echo "host: no components yet"
