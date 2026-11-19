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

# A fixture cassette with its sidecar, so the test needs no download. The
# installed release is never started here.
cassettes="$work/cassettes"
mkdir "$cassettes"
printf 'fixture cassette for the install test\n' > "$cassettes/$name"
(cd "$cassettes" && shasum -a 256 "$name" > "$name.sha256")

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

# A missing or mismatched pinned cassette fails before anything is built.
missing="$work/missing"
mkdir -p "$missing/absent" "$missing/nosidecar" "$missing/mismatch" "$missing/other"
cp "$cassettes/$name" "$missing/nosidecar/$name"
cp "$cassettes/$name" "$cassettes/$name.sha256" "$missing/mismatch/"
printf 'tampered\n' >> "$missing/mismatch/$name"
cp "$cassettes/$name" "$missing/other/opsmaru_incus-0.0.1.tama-cassette"
for cassette in "$missing/absent/$name" "$missing/nosidecar/$name" "$missing/mismatch/$name" \
                "$missing/other/opsmaru_incus-0.0.1.tama-cassette"; do
  refused "$work/empty" "pinned opsmaru_incus $locked cassette" --prefix "$work/empty" --cassette "$cassette"
done

# The complete install: Swift executable and release, one identity.
sh Packaging/install-local.sh --prefix "$prefix" --cassette "$cassettes/$name"
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
