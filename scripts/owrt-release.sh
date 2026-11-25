#!/usr/bin/env bash
# Assemble the release folder for tag vX.Y.Z from the build outputs.
#
#   scripts/owrt-release.sh --version X.Y.Z --tools DIR --guest DIR [--out DIR] [--min-plugin V]
#   scripts/owrt-release.sh --verify DIR [--version X.Y.Z]
#
#   --tools DIR  output of: owrt-build.sh tools host   (cloud-hypervisor, owrt-kvmprobe, owrt-fwd)
#   --guest DIR  output of: owrt-build.sh guest        (Image, rootfs.img)
#   --out DIR    release folder (default dist/release)
#
# Release assets (names are a contract with the plugin):
#   Image, rootfs.img.gz, cloud-hypervisor, owrt-vm.sh, owrt-vm.conf.example,
#   owrt-kvmprobe, owrt-fwd (only when tools/owrt-fwd exists), owrt-manifest.json, SHA256SUMS
#
# SHA256SUMS lists every file except itself (the manifest included). The manifest lists
# every file except itself and SHA256SUMS, with size, sha256 and "required"; rootfs.img.gz also
# carries the size and sha256 of the unpacked rootfs.img. The plugin pins the sha256 of
# owrt-manifest.json, so the manifest bytes must not change once published.
# Both inputs are verified first; the finished folder is verified again before the script ends.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/dist/release"
VERSION=""
MIN_PLUGIN="1.0.0"
TOOLS="" GUEST="" VERIFY=""
MARK=.owrt-release
# Tools that go into a release (the plugin install set). Other owrt-* tools are not shipped.
SHIP_TOOLS=(cloud-hypervisor owrt-kvmprobe owrt-fwd)

die() { echo "owrt-release: $*" >&2; exit 1; }
log() { echo "==> $*"; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

semver_ok() { [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

list_files() { ( cd "$1" && find . -type f ! -name SHA256SUMS ! -name "$MARK" -printf '%P\n' | LC_ALL=C sort ); }

# SHA256SUMS check + manifest check (needs python3). $2 = expected version or empty.
release_verify() {
  local d=$1 want=${2:-} listed present
  [ -f "$d/SHA256SUMS" ] || die "$d/SHA256SUMS missing"
  [ -f "$d/owrt-manifest.json" ] || die "$d/owrt-manifest.json missing"
  ( cd "$d" && sha256sum --quiet -c SHA256SUMS ) || die "checksum mismatch in $d"
  listed=$(sed 's/^[0-9a-f]*[ *]*//' "$d/SHA256SUMS" | LC_ALL=C sort)
  present=$(list_files "$d")
  [ "$listed" = "$present" ] || die "files in $d differ from SHA256SUMS (extra or missing files)"
  python3 -I - "$d" "$want" <<'PY' || die "manifest check failed"
import gzip, hashlib, json, os, re, sys
d, want = sys.argv[1], sys.argv[2]
REQUIRED = {"Image", "rootfs.img.gz", "cloud-hypervisor", "owrt-vm.sh", "owrt-kvmprobe"}
META = {"SHA256SUMS", "owrt-manifest.json", ".owrt-release"}
def fail(m):
    print("manifest: " + m, file=sys.stderr); sys.exit(1)
def sha(stream):
    h = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1 << 20), b""):
        h.update(chunk)
    return h.hexdigest()
try:
    m = json.load(open(os.path.join(d, "owrt-manifest.json")))
except Exception as e:
    fail("not valid JSON: %s" % e)
if m.get("schema") != 1: fail("schema is not 1")
ver = m.get("version", "")
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", str(ver)): fail("bad version %r" % ver)
if want and ver != want: fail("version %s, expected %s" % (ver, want))
if not re.fullmatch(r"\d+\.\d+\.\d+", str(m.get("min_plugin", ""))): fail("bad min_plugin")
files = m.get("files")
if not isinstance(files, list) or not files: fail("files is empty")
names = []
for f in files:
    n = f.get("name", "")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", n) or n in META: fail("bad file name %r" % n)
    names.append(n)
    p = os.path.join(d, n)
    if not os.path.isfile(p): fail("%s is listed but missing" % n)
    if os.path.getsize(p) != f.get("size"): fail("%s: size differs" % n)
    if not re.fullmatch(r"[0-9a-f]{64}", str(f.get("sha256", ""))): fail("%s: bad sha256" % n)
    with open(p, "rb") as fh:
        if sha(fh) != f["sha256"]: fail("%s: sha256 differs" % n)
    if not isinstance(f.get("required"), bool): fail("%s: required is not true/false" % n)
    u = f.get("unpack")
    if u is not None:
        if not n.endswith(".gz"): fail("%s: unpack on a non-gz file" % n)
        with gzip.open(p, "rb") as g:
            h = hashlib.sha256(); size = 0
            for chunk in iter(lambda: g.read(1 << 20), b""):
                h.update(chunk); size += len(chunk)
        if h.hexdigest() != u.get("sha256") or size != u.get("size"):
            fail("%s: unpacked content differs from the manifest" % n)
if len(set(names)) != len(names): fail("duplicate file name")
present = {n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))} - META
if present != set(names): fail("files on disk and in the manifest differ: %s" % sorted(present ^ set(names)))
req = {f["name"] for f in files if f["required"]}
if not REQUIRED <= req: fail("required files missing: %s" % sorted(REQUIRED - req))
rg = [f for f in files if f["name"] == "rootfs.img.gz"]
if not rg or "unpack" not in rg[0]: fail("rootfs.img.gz has no unpack entry")
print("manifest OK: version %s, %d files" % (ver, len(files)))
PY
}

assemble() {
  local f need
  semver_ok "$VERSION" || die "--version must be MAJOR.MINOR.PATCH (got '$VERSION')"
  semver_ok "$MIN_PLUGIN" || die "--min-plugin must be MAJOR.MINOR.PATCH"
  [ -d "$TOOLS" ] || die "--tools DIR is required and must exist"
  [ -d "$GUEST" ] || die "--guest DIR is required and must exist"
  for f in python3 gzip sha256sum sh; do command -v "$f" >/dev/null 2>&1 || die "$f not found"; done

  log "check the inputs"
  bash "$HERE/owrt-build.sh" --verify "$TOOLS" >/dev/null || die "tools folder $TOOLS does not verify"
  bash "$HERE/owrt-build.sh" --verify "$GUEST" >/dev/null || die "guest folder $GUEST does not verify"
  for need in cloud-hypervisor owrt-kvmprobe; do
    [ -s "$TOOLS/$need" ] || die "$TOOLS/$need missing"
  done
  for need in Image rootfs.img; do
    [ -s "$GUEST/$need" ] || die "$GUEST/$need missing"
  done
  for need in owrt-vm.sh owrt-vm.conf.example; do
    [ -s "$HERE/$need" ] || die "scripts/$need missing (the manager script must be in the repo)"
  done
  sh -n "$HERE/owrt-vm.sh" || die "scripts/owrt-vm.sh has a syntax error"

  case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac
  mkdir -p "$OUT"
  if [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/$MARK" ]; then
    die "$OUT is not empty and was not made by owrt-release; refusing to clear it"
  fi
  find "$OUT" -mindepth 1 -delete
  : > "$OUT/$MARK"

  log "collect"
  cp "$GUEST/Image" "$OUT/Image"
  gzip -n -9 -c "$GUEST/rootfs.img" > "$OUT/rootfs.img.gz"   # -n: no name or time, same bytes every run
  for f in "${SHIP_TOOLS[@]}"; do
    [ -f "$TOOLS/$f" ] && cp "$TOOLS/$f" "$OUT/$f"
  done
  cp "$HERE/owrt-vm.sh" "$HERE/owrt-vm.conf.example" "$OUT/"
  chmod 644 "$OUT"/*

  log "manifest"
  python3 -I - "$OUT" "$VERSION" "$MIN_PLUGIN" "$GUEST/rootfs.img" <<'PY'
import hashlib, json, os, sys
out, version, min_plugin, raw = sys.argv[1:5]
ORDER = ["Image", "rootfs.img.gz", "cloud-hypervisor", "owrt-vm.sh", "owrt-vm.conf.example",
         "owrt-kvmprobe", "owrt-fwd"]
OPTIONAL = {"owrt-vm.conf.example": False}      # everything else listed is required
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
files = []
for n in ORDER:
    p = os.path.join(out, n)
    if not os.path.isfile(p):
        continue
    e = {"name": n, "size": os.path.getsize(p), "sha256": sha(p), "required": OPTIONAL.get(n, True)}
    if n == "rootfs.img.gz":
        e["unpack"] = {"name": "rootfs.img", "size": os.path.getsize(raw), "sha256": sha(raw)}
    files.append(e)
m = {"schema": 1, "version": version, "min_plugin": min_plugin, "files": files}
with open(os.path.join(out, "owrt-manifest.json"), "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY

  log "SHA256SUMS"
  ( cd "$OUT" && list_files . | tr '\n' '\0' | xargs -0 sha256sum > SHA256SUMS )
  release_verify "$OUT" "$VERSION"
  cat "$OUT/SHA256SUMS"
  echo "pin (owrt-manifest.json sha256): $(sha256sum "$OUT/owrt-manifest.json" | cut -d' ' -f1)"
}

while [ $# -gt 0 ]; do
  case $1 in
    --version)    VERSION=${2:?--version needs a value}; shift 2 ;;
    --tools)      TOOLS=${2:?--tools needs a folder}; shift 2 ;;
    --guest)      GUEST=${2:?--guest needs a folder}; shift 2 ;;
    --out)        OUT=${2:?--out needs a path}; shift 2 ;;
    --min-plugin) MIN_PLUGIN=${2:?--min-plugin needs a value}; shift 2 ;;
    --verify)     VERIFY=${2:?--verify needs a folder}; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "$VERIFY" ]; then
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  [ -z "$VERSION" ] || semver_ok "$VERSION" || die "--version must be MAJOR.MINOR.PATCH"
  release_verify "$VERIFY" "$VERSION"
  exit 0
fi
assemble
