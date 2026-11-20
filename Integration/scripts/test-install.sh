#!/bin/sh
# Verifies the source install command in isolated prefixes: both components
# are staged and verified, unsafe destinations, a mismatched Macus identity
# and a missing pinned dependency are refused before anything is installed,
# and installation stays passive.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
work=$(mktemp -d "${TMPDIR:-/tmp}/macus-install-test.XXXXXX")
sentinel=$(mktemp -d "${TMPDIR:-/tmp}/macus-state.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work" "$sentinel"' EXIT INT TERM
prefix="$work/prefix"
mkdir "$prefix"
printf 'keep\n' > "$sentinel/marker"
chmod 700 "$sentinel"
before=$(stat -f '%m %z' "$sentinel/marker")
home_state_absent=0
if [ ! -e "${HOME}/.tama/incus-mac" ]; then
  home_state_absent=1
fi
agents_before=$(ls "${HOME}/Library/LaunchAgents" 2>/dev/null || true)
revision=$(git rev-parse HEAD)
locked=$(sed -n 's/.*"opsmaru_incus": {:hex, :opsmaru_incus, "\([^"]*\)".*/\1/p' server/mix.lock)
name="opsmaru_incus-$locked.tama-cassette"

# A fixture cassette with its sidecar, served by a stand-in GitHub CLI so the
# test needs no network: FAKE_GH_RELEASES/<tag>/ holds each release's assets,
# FAKE_GH_ATTESTED lists the SHA-256 of every attested file, and FAKE_GH_LOG
# records each call. The installed release is never started here.
cassettes="$work/cassettes"
mkdir "$cassettes"
printf 'fixture cassette for the install test\n' > "$cassettes/$name"
(cd "$cassettes" && shasum -a 256 "$name" > "$name.sha256")
fakebin="$work/fakebin"
mkdir "$fakebin"
cat > "$fakebin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "release download")
    tag=$3
    shift 3
    dir=
    patterns=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) dir=$2; shift 2 ;;
        --pattern) patterns="$patterns $2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -d "$FAKE_GH_RELEASES/$tag" ] || { echo "release not found" >&2; exit 1; }
    found=0
    for pattern in $patterns; do
      if [ -f "$FAKE_GH_RELEASES/$tag/$pattern" ]; then
        cp "$FAKE_GH_RELEASES/$tag/$pattern" "$dir/"
        found=1
      fi
    done
    [ "$found" -eq 1 ] || { echo "no assets match the file pattern" >&2; exit 1; }
    ;;
  "attestation verify")
    sum=$(shasum -a 256 "$3" | cut -d ' ' -f 1)
    grep -qx "$sum" "$FAKE_GH_ATTESTED" || { echo "no attestation matched the artifact" >&2; exit 1; }
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$fakebin/gh"
export FAKE_GH_RELEASES="$work/releases" FAKE_GH_ATTESTED="$work/attested" FAKE_GH_LOG="$work/gh.log"
mkdir "$FAKE_GH_RELEASES"
cut -d ' ' -f 1 "$cassettes/$name.sha256" > "$FAKE_GH_ATTESTED"
: > "$FAKE_GH_LOG"
system_path=$PATH
PATH="$fakebin:$PATH"
# Publishes the fixture assets in $2 (or nothing) as the release tagged $1.
publish() {
  tag=$1
  shift
  rm -rf "${FAKE_GH_RELEASES:?}/$tag"
  mkdir "$FAKE_GH_RELEASES/$tag"
  for asset in "$@"; do
    cp "$asset" "$FAKE_GH_RELEASES/$tag/"
  done
}

# Expects a refusal mentioning $2 that leaves the prefix $1 empty or absent.
refused() {
  target=$1
  pattern=$2
  shift 2
  if sh Packaging/install-local.sh "$@" > "$work/refused.out" 2>&1; then
    echo "accepted: $*" >&2
    exit 1
  fi
  if ! grep -q "$pattern" "$work/refused.out"; then
    echo "refusal without '$pattern': $*" >&2
    cat "$work/refused.out" >&2
    exit 1
  fi
  if [ -n "$target" ] && [ -e "$target" ] && [ -n "$(ls -A "$target")" ]; then
    echo "a refused install changed $target: $*" >&2
    exit 1
  fi
}

for option in --prefix --cassette --release; do
  refused "" 'must be an absolute path' "$option" relative
done

# Redirected or non-file destinations fail before copying or building.
for kind in bin executable dangling directory libexec release release-file foreign; do
  unsafe="$work/unsafe-$kind"
  outside="$sentinel/outside-$kind"
  mkdir -p "$unsafe" "$outside"
  printf 'outside macus\n' > "$outside/macus"
  case "$kind" in
    bin) ln -s "$outside" "$unsafe/bin" ;;
    executable | dangling | directory)
      mkdir "$unsafe/bin"
      case "$kind" in
        executable) ln -s "$outside/macus" "$unsafe/bin/macus" ;;
        dangling) ln -s "$outside/missing" "$unsafe/bin/macus" ;;
        directory) mkdir "$unsafe/bin/macus" ;;
      esac
      ;;
    libexec) ln -s "$outside" "$unsafe/libexec" ;;
    release)
      mkdir "$unsafe/libexec"
      ln -s "$outside" "$unsafe/libexec/macus"
      ;;
    release-file)
      mkdir "$unsafe/libexec"
      printf 'not a release\n' > "$unsafe/libexec/macus"
      ;;
    foreign)
      # A directory that is not a Macus release is never replaced.
      mkdir -p "$unsafe/libexec/macus"
      printf 'user data\n' > "$unsafe/libexec/macus/data"
      ;;
  esac
  refused "" 'Refusing' --prefix "$unsafe" --cassette "$cassettes/$name"
  test "$(cat "$outside/macus")" = 'outside macus'
  test ! -e "$outside/missing"
  test -z "$(ls -A "$outside" | grep -v '^macus$' || true)"
done
test "$(cat "$work/unsafe-foreign/libexec/macus/data")" = 'user data'
test "$(cat "$work/unsafe-release-file/libexec/macus")" = 'not a release'

# A missing, mismatched or unattested pinned cassette fails before anything is built.
missing="$work/missing"
mkdir -p "$missing/absent" "$missing/nosidecar" "$missing/mismatch" "$missing/other" "$missing/unattested"
cp "$cassettes/$name" "$missing/nosidecar/$name"
cp "$cassettes/$name" "$cassettes/$name.sha256" "$missing/mismatch/"
printf 'tampered\n' >> "$missing/mismatch/$name"
cp "$cassettes/$name" "$missing/other/opsmaru_incus-0.0.1.tama-cassette"
printf 'unattested cassette\n' > "$missing/unattested/$name"
(cd "$missing/unattested" && shasum -a 256 "$name" > "$name.sha256")
for cassette in "$missing/absent/$name" "$missing/nosidecar/$name" "$missing/mismatch/$name" \
                "$missing/other/opsmaru_incus-0.0.1.tama-cassette" "$missing/unattested/$name"; do
  refused "$work/empty" "pinned opsmaru_incus $locked cassette" --prefix "$work/empty" --cassette "$cassette"
done
grep -q 'attestation' "$work/refused.out"

# Downloaded from the release for the locked version: a missing release or
# asset, a missing sidecar, a hash mismatch or a failed attestation is refused.
refused "$work/empty" "release does not provide $name" --prefix "$work/empty"
publish "v0.0.1" "$missing/other/opsmaru_incus-0.0.1.tama-cassette"
refused "$work/empty" "release does not provide $name" --prefix "$work/empty"
publish "v$locked"
refused "$work/empty" "release does not provide $name" --prefix "$work/empty"
publish "v$locked" "$cassettes/$name"
refused "$work/empty" '.sha256 is missing' --prefix "$work/empty"
publish "v$locked" "$missing/mismatch/$name" "$missing/mismatch/$name.sha256"
refused "$work/empty" 'does not match its .sha256' --prefix "$work/empty"
publish "v$locked" "$missing/unattested/$name" "$missing/unattested/$name.sha256"
refused "$work/empty" "no valid upmaru/opsmaru-incus attestation" --prefix "$work/empty"
# Without the GitHub CLI there is no download or verification, so nothing is built.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
if ! command -v gh >/dev/null 2>&1; then
  refused "$work/empty" 'GitHub CLI (gh) is required' --prefix "$work/empty" --cassette "$cassettes/$name"
fi
PATH="$fakebin:$system_path"
# Only the locked version's release and the opsmaru-incus repository were asked for.
test -z "$(grep '^release download' "$FAKE_GH_LOG" | grep -v "^release download v$locked --repo upmaru/opsmaru-incus " | grep -v '^release download v0.0.1' || true)"
test -z "$(grep '^attestation verify' "$FAKE_GH_LOG" | grep -v -- '--repo upmaru/opsmaru-incus$' || true)"

# The complete install: Swift executable and release, one identity, with the
# cassette downloaded from the locked version's release and verified.
publish "v$locked" "$cassettes/$name" "$cassettes/$name.sha256"
: > "$FAKE_GH_LOG"
sh Packaging/install-local.sh --prefix "$prefix"
grep -qx "release download v$locked --repo upmaru/opsmaru-incus --dir .* --pattern $name --pattern $name.sha256" "$FAKE_GH_LOG"
grep -q "^attestation verify .*/$name --repo upmaru/opsmaru-incus$" "$FAKE_GH_LOG"
test -x "$prefix/bin/macus"
test ! -e "$prefix/bin/tama-incus-mac"
test ! -e "$prefix/bin/tim"
codesign --verify --strict "$prefix/bin/macus"
codesign -d --entitlements :- "$prefix/bin/macus" 2>/dev/null | grep -q 'com.apple.security.virtualization'
segedit "$prefix/bin/macus" -extract __TEXT __info_plist "$work/identity.plist"
test "$(plutil -extract MacusSourceRevision raw -o - "$work/identity.plist")" = "$revision"
manifest="$prefix/libexec/macus/macus-build.json"
test "$(plutil -extract revision raw -o - "$manifest")" = "$revision"
test "$(plutil -extract version raw -o - "$manifest")" = \
  "$(plutil -extract MacusVersion raw -o - "$work/identity.plist")"
test "$(plutil -extract opsmaru_incus.version raw -o - "$manifest")" = "$locked"
test "$(plutil -extract opsmaru_incus.cassette.sha256 raw -o - "$manifest")" = \
  "$(cut -d ' ' -f 1 "$cassettes/$name.sha256")"
test -x "$prefix/libexec/macus/bin/macus"
ls -d "$prefix"/libexec/macus/erts-* >/dev/null
test -z "$(ls -A "$prefix/libexec" | grep -v '^macus$' || true)"
"$prefix/bin/macus" --help | grep -q 'runtime status'
"$prefix/bin/macus" --help | grep -q 'serve'
"$prefix/bin/macus" capabilities --json | grep -q 'apple-vz'
python3 Integration/scripts/presentation-acceptance.py --binary "$prefix/bin/macus"

# Prebuilt releases: a copy of the installed one, then tampered copies.
good="$work/release"
cp -R -p "$prefix/libexec/macus" "$good"
tampered() {
  rm -rf "$work/tampered"
  cp -R -p "$good" "$work/tampered"
  chmod u+w "$work/tampered/macus-build.json"
}
tampered
other=$(printf '%s' "$revision" | tr '0-9a-f' '1-9a-f0')
sed "s/$revision/$other/" "$good/macus-build.json" > "$work/tampered/macus-build.json"
chmod 444 "$work/tampered/macus-build.json"
refused "$work/empty" 'built as Macus' --prefix "$work/empty" --release "$work/tampered"
tampered
rm -rf "$work/tampered"/lib/opsmaru_incus-*
chmod 444 "$work/tampered/macus-build.json"
refused "$work/empty" "pinned opsmaru_incus $locked" --prefix "$work/empty" --release "$work/tampered"
tampered
rm -f "$work/tampered"/lib/macus-*/priv/cassettes/*
chmod 444 "$work/tampered/macus-build.json"
refused "$work/empty" "pinned opsmaru_incus $locked cassette" --prefix "$work/empty" --release "$work/tampered"

# A refused reinstall leaves the existing installation as it was.
installed_before=$(shasum -a 256 "$prefix/bin/macus" "$manifest")
tampered
rm -rf "$work/tampered"/lib/opsmaru_incus-*
chmod 444 "$work/tampered/macus-build.json"
refused "" "pinned opsmaru_incus $locked" --prefix "$prefix" --release "$work/tampered"
test "$(shasum -a 256 "$prefix/bin/macus" "$manifest")" = "$installed_before"

# Reinstalling replaces the earlier release entirely.
printf 'stale\n' > "$prefix/libexec/macus/stale"
sh Packaging/install-local.sh --prefix "$prefix" --release "$good"
test ! -e "$prefix/libexec/macus/stale"
test -z "$(ls -A "$prefix/libexec" | grep -v '^macus$' || true)"
test "$(plutil -extract revision raw -o - "$manifest")" = "$revision"

# Passive: no runtime state, no launch agent.
after=$(stat -f '%m %z' "$sentinel/marker")
test "$before" = "$after"
if [ "$home_state_absent" -eq 1 ] && [ -e "${HOME}/.tama/incus-mac" ]; then
  echo "install created the normal state directory" >&2
  exit 1
fi
test "$(ls "${HOME}/Library/LaunchAgents" 2>/dev/null || true)" = "$agents_before"
echo "isolated prefix install verified"
