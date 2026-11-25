#!/usr/bin/env bash
# One command: build every OpenWrt-VM artifact for the F50 and write SHA256SUMS.
#
#   scripts/owrt-build.sh [--version V] [--out DIR] [--no-test] [stage ...]
#   scripts/owrt-build.sh --verify DIR
#
# Stages (default: every stage that exists):
#   tools  tools/owrt-*/   Go, static linux/arm64, vet + test + build
#   host   host/build.sh   VMM and other host binaries (Rust, static aarch64)
#   guest  guest/build.sh  OpenWrt kernel Image + rootfs.img (long build)
#
# Output: dist/owrt/ (override with --out). SHA256SUMS is written last, so a
# directory without it is an incomplete build. Linux only (GNU find/xargs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/owrt"
VERSION="${OWRT_VERSION:-dev}"
RUN_TESTS=1
VERIFY=""
STAGES=()

die() { echo "owrt-build: $*" >&2; exit 1; }
log() { echo "==> $*"; }
usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ELF files must be AArch64 and static (no INTERP, no NEEDED). Other files
# (Image, rootfs.img) are not checked here.
elf_check() {
  local f=$1 magic out
  magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
  [ "$magic" = 7f454c46 ] || return 0
  out=$(readelf -h "$f" 2>/dev/null) || { echo "$f: readelf cannot read it"; return 1; }
  case $out in *"Machine:"*AArch64*) ;; *) echo "$f: not AArch64"; return 1 ;; esac
  out=$(readelf -lW "$f" 2>/dev/null || true)
  case $out in *" INTERP "*) echo "$f: dynamically linked (has INTERP)"; return 1 ;; esac
  out=$(readelf -dW "$f" 2>/dev/null || true)
  case $out in *"(NEEDED)"*) echo "$f: needs shared libraries"; return 1 ;; esac
  return 0
}

list_files() { ( cd "$1" && find . -type f ! -name SHA256SUMS ! -name .owrt-out -printf '%P\n' | LC_ALL=C sort ); }

sums_write() {
  [ -n "$(list_files "$1")" ] || die "nothing was built"
  ( cd "$1" && list_files . | tr '\n' '\0' | xargs -0 -r sha256sum > SHA256SUMS )
}

sums_verify() {
  local d=$1 listed present
  [ -f "$d/SHA256SUMS" ] || die "$d/SHA256SUMS missing (incomplete build?)"
  ( cd "$d" && sha256sum --quiet -c SHA256SUMS ) || die "checksum mismatch in $d"
  listed=$(sed 's/^[0-9a-f]*[ *]*//' "$d/SHA256SUMS" | LC_ALL=C sort)
  present=$(list_files "$d")
  [ "$listed" = "$present" ] || die "files in $d differ from SHA256SUMS (extra or missing files)"
  echo "OK: $(echo "$present" | wc -l) files match SHA256SUMS"
}

prepare_out() {
  mkdir -p "$OUT"
  if [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/.owrt-out" ]; then
    die "$OUT is not empty and was not made by owrt-build; refusing to clear it"
  fi
  find "$OUT" -mindepth 1 ! -name .owrt-out -delete
  : > "$OUT/.owrt-out"
}

stage_tools() {
  local d name found=0
  for d in "$ROOT"/tools/owrt-*/; do
    [ -f "$d/go.mod" ] || continue
    name=$(basename "$d"); found=1
    log "tools/$name"
    (
      cd "$d"
      export GOFLAGS=-buildvcs=false
      if [ "$RUN_TESTS" = 1 ]; then go vet ./...; go test ./...; fi
      # arm64-only files are only vetted with the target set
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go vet ./...
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
        go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o "$OUT/$name" .
    )
  done
  [ "$found" = 1 ] || die "no tools/owrt-*/ with go.mod"
}

stage_script() { # stage name, script path, explicit?
  if [ -f "$2" ]; then
    log "$1"
    bash "$2" "$OUT"
  elif [ "$3" = 1 ]; then
    die "stage $1 requested but $2 does not exist"
  else
    echo "-- $1: $2 not present, skipped"
  fi
}

while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=${2:?--version needs a value}; shift 2 ;;
    --out)     OUT=${2:?--out needs a path}; shift 2 ;;
    --no-test) RUN_TESTS=0; shift ;;
    --verify)  VERIFY=${2:?--verify needs a directory}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    tools|host|guest) STAGES+=("$1"); shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "$VERIFY" ]; then sums_verify "$VERIFY"; exit 0; fi

command -v readelf >/dev/null 2>&1 || die "readelf not found (binutils)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"

explicit=1
if [ ${#STAGES[@]} -eq 0 ]; then STAGES=(tools host guest); explicit=0; fi
case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac
prepare_out
OUT="$(cd "$OUT" && pwd)"

for s in "${STAGES[@]}"; do
  case $s in
    tools) command -v go >/dev/null 2>&1 || die "go not found"; stage_tools ;;
    host)  stage_script host  "$ROOT/host/build.sh"  "$explicit" ;;
    guest) stage_script guest "$ROOT/guest/build.sh" "$explicit" ;;
  esac
done

bad=0
while IFS= read -r f; do
  elf_check "$OUT/$f" || bad=1
done < <(list_files "$OUT")
[ "$bad" = 0 ] || die "binary check failed, no SHA256SUMS written"

sums_write "$OUT"
log "SHA256SUMS ($OUT)"
cat "$OUT/SHA256SUMS"
