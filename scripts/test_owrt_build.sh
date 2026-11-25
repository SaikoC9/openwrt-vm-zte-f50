#!/usr/bin/env bash
# Tests scripts/owrt-build.sh against a fake root: fake go, fake host and
# guest components, hand-made ELF files. Needs bash, python3, readelf.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in python3 readelf sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "skipped: owrt build test ($t missing)"; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

python3 - "$T" <<'PY'
import struct, sys
t = sys.argv[1]
def elf(machine, interp):
    ph = struct.pack('<IIQQQQQQ', 3, 4, 0, 0, 0, 0, 0, 1) if interp else b''
    hdr = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + b'\0' * 9, 2, machine, 1,
                      0, 64 if interp else 0, 0, 0, 64, 56, 1 if interp else 0, 64, 0, 0)
    return hdr + ph
open(t + '/arm64-static', 'wb').write(elf(0xB7, False))
open(t + '/arm64-dynamic', 'wb').write(elf(0xB7, True))
open(t + '/x86-static', 'wb').write(elf(0x3E, False))
PY

mkdir -p "$T/bin"
cat > "$T/bin/go" <<'FAKE'
#!/usr/bin/env bash
echo "$1 GOOS=${GOOS:-} GOARCH=${GOARCH:-} CGO=${CGO_ENABLED:-} $*" >> "$FAKE_GO_LOG"
case $1 in
  test) [ -z "${FAKE_GO_FAIL_TEST:-}" ] || exit 1 ;;
  build) out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
         cp "${FAKE_ELF:?}" "$out" ;;
esac
exit 0
FAKE
chmod +x "$T/bin/go"
export PATH="$T/bin:$PATH" FAKE_GO_LOG="$T/go.log" FAKE_ELF="$T/arm64-static"

mkroot() { # dir [with_guest]
  local r=$1
  rm -rf "$r"; mkdir -p "$r/scripts" "$r/tools/owrt-fake" "$r/host/demo"
  cp "$HERE/owrt-build.sh" "$r/scripts/"
  cp "$HERE/../host/build.sh" "$r/host/"
  echo 'module owrt-fake' > "$r/tools/owrt-fake/go.mod"
  printf '#!/bin/sh\ncp "%s" "$1/demo-vmm"\n' "$T/arm64-static" > "$r/host/demo/build.sh"
  if [ "${2:-}" = guest ]; then
    mkdir -p "$r/guest"
    printf '#!/bin/sh\necho kernel > "$1/Image"; echo disk > "$1/rootfs.img"\n' > "$r/guest/build.sh"
  fi
}
B() { bash "$R/scripts/owrt-build.sh" "$@"; }

# 1. full build
R=$T/r1; mkroot "$R" guest; : > "$FAKE_GO_LOG"
B --version 9.9.9 >"$T/o1" 2>&1; rc=$?
check "full build succeeds" "[ $rc = 0 ]"
check "all artifacts present" "[ -f $R/dist/owrt/owrt-fake ] && [ -f $R/dist/owrt/demo-vmm ] && [ -f $R/dist/owrt/Image ] && [ -f $R/dist/owrt/rootfs.img ]"
check "SHA256SUMS verifies" "(cd $R/dist/owrt && sha256sum --quiet -c SHA256SUMS)"
check "SHA256SUMS lists 4 files, not itself" "[ \$(wc -l < $R/dist/owrt/SHA256SUMS) = 4 ] && ! grep -q 'SHA256SUMS\|owrt-out' $R/dist/owrt/SHA256SUMS"
check "go build env is linux/arm64 CGO=0" "grep -q 'build GOOS=linux GOARCH=arm64 CGO=0' $FAKE_GO_LOG"
check "version reaches ldflags" "grep -q 'main.version=9.9.9' $FAKE_GO_LOG"
check "host tests and arm64 vet both ran" "grep -q '^test ' $FAKE_GO_LOG && grep -q 'vet GOOS=linux GOARCH=arm64' $FAKE_GO_LOG"
check "--verify passes" "B --verify $R/dist/owrt >/dev/null 2>&1"

# 2. verify catches tamper, extra file
echo x >> "$R/dist/owrt/Image"
check "--verify catches changed file" "! B --verify $R/dist/owrt >/dev/null 2>&1"
B >/dev/null 2>&1
echo x > "$R/dist/owrt/stray"
check "--verify catches extra file" "! B --verify $R/dist/owrt >/dev/null 2>&1"
B >/dev/null 2>&1
check "rebuild clears stray file" "[ ! -e $R/dist/owrt/stray ]"

# 3. binary checks
for kind in arm64-dynamic x86-static; do
  R=$T/r3; mkroot "$R"; FAKE_ELF=$T/$kind B tools >"$T/o3" 2>&1; rc=$?
  check "$kind rejected, no SHA256SUMS" "[ $rc != 0 ] && [ ! -e $R/dist/owrt/SHA256SUMS ]"
done

# 4. tests
R=$T/r4; mkroot "$R"; FAKE_GO_FAIL_TEST=1 B tools >"$T/o4" 2>&1; rc=$?
check "failing go test aborts, no SHA256SUMS" "[ $rc != 0 ] && [ ! -e $R/dist/owrt/SHA256SUMS ]"
R=$T/r4b; mkroot "$R"; : > "$FAKE_GO_LOG"; FAKE_GO_FAIL_TEST=1 B --no-test tools >"$T/o4" 2>&1; rc=$?
check "--no-test skips go test" "[ $rc = 0 ] && ! grep -q '^test ' $FAKE_GO_LOG"

# 5. stages
R=$T/r5; mkroot "$R"; B >"$T/o5" 2>&1; rc=$?
check "missing guest/ is skipped by default" "[ $rc = 0 ] && grep -q 'guest: .* skipped' $T/o5"
B guest >"$T/o5" 2>&1; rc=$?
check "explicit guest stage without guest/ fails" "[ $rc != 0 ]"
B bogus >"$T/o5" 2>&1; rc=$?
check "unknown stage rejected" "[ $rc != 0 ]"

# 6. foreign output folder
R=$T/r6; mkroot "$R"; mkdir -p "$T/foreign"; echo keep > "$T/foreign/file"
B --out "$T/foreign" >"$T/o6" 2>&1; rc=$?
check "refuses to clear a foreign folder" "[ $rc != 0 ] && [ -f $T/foreign/file ]"
B --out "$T/own" >/dev/null 2>&1
check "--out outside the repo works" "[ -f $T/own/SHA256SUMS ]"

# 7. smoke script
S="$HERE/owrt-qemu-smoke.sh"
mkdir -p "$T/empty"
bash "$S" --dir "$T/empty" >"$T/o7" 2>&1; rc=$?
check "smoke: SKIP without guest" "[ $rc = 0 ] && grep -q '^SKIP' $T/o7"
bash "$S" --dir "$T/empty" --require >"$T/o7" 2>&1; rc=$?
check "smoke: --require fails without guest" "[ $rc != 0 ]"
bash "$S" --timeout abc >"$T/o7" 2>&1; rc=$?
check "smoke: bad number rejected" "[ $rc != 0 ]"
bash -n "$S" && ok "smoke script parses" || bad "smoke script parses"

[ "$fails" = 0 ] && { echo "owrt build tests: all passed"; exit 0; }
echo "owrt build tests: $fails failed"; exit 1
