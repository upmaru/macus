#!/bin/sh
# Install Macus from this checkout into one prefix:
#   prefix/bin/macus           the entitled Swift executable
#   prefix/libexec/macus/      the matching bundled-ERTS server release
# Both are built, staged and verified before anything in the prefix changes.
# Requires Swift, and Elixir/Erlang (through mise when available) unless
# --release names an already assembled release. A release built here bundles
# the opsmaru_incus cassette for the version server/mix.lock locks: it is
# downloaded from that upmaru/opsmaru-incus GitHub Release (or taken from
# --cassette, beside its .sha256), and its hash and attestation are verified
# with the GitHub CLI before anything is built. Ad-hoc signatures are
# development signatures, not notarization. Does not create runtime state,
# register or activate launch agents, or install the Incus CLI.
set -eu

usage() {
  echo "usage: Packaging/install-local.sh [--prefix ABSOLUTE_PATH] [--cassette ABSOLUTE_PATH | --release ABSOLUTE_PATH]" >&2
  exit 2
}

fail() {
  echo "$*" >&2
  exit 1
}

prefix="${HOME}/.local"
cassette=
release=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix | --cassette | --release)
      [ "$#" -ge 2 ] || usage
      case "$2" in
        /*) ;;
        *)
          echo "${1#--} must be an absolute path" >&2
          exit 2
          ;;
      esac
      case "$1" in
        --prefix) prefix=$2 ;;
        --cassette) cassette=$2 ;;
        --release) release=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done
if [ -n "$cassette" ] && [ -n "$release" ]; then
  usage
fi
if [ -L "$prefix" ]; then
  fail "Refusing to install through a symlink prefix"
fi

validate_destinations() {
  for destination in "$prefix/bin" "$prefix/bin/macus" "$prefix/libexec" "$prefix/libexec/macus"; do
    if [ -L "$destination" ]; then
      fail "Refusing to install through symlink destinations"
    fi
  done
  for directory in "$prefix/bin" "$prefix/libexec"; do
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
      fail "Refusing a non-directory destination: $directory"
    fi
  done
  if [ -e "$prefix/bin/macus" ] && [ ! -f "$prefix/bin/macus" ]; then
    fail "Refusing a non-file executable destination"
  fi
  # Only an earlier Macus server release is ever replaced.
  existing="$prefix/libexec/macus"
  if [ -e "$existing" ]; then
    if [ ! -d "$existing" ]; then
      fail "Refusing a non-directory server release destination"
    fi
    if [ -L "$existing/macus-build.json" ] || [ ! -f "$existing/macus-build.json" ]; then
      fail "Refusing to replace $existing: it is not a Macus server release"
    fi
  fi
}
validate_destinations

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

# One Macus identity for both components: the package version in
# server/mix.exs and this checkout's commit.
version=$(sed -n 's/^ *version: "\([^"]*\)",$/\1/p' server/mix.exs | head -n 1)
if ! printf '%s' "$version" | grep -Eq '^[0-9A-Za-z.+_-]{1,64}$'; then
  fail "server/mix.exs records no valid package version"
fi
revision=$(git rev-parse --verify HEAD 2>/dev/null) ||
  fail "Refusing to install without a source revision: run it from a git checkout"
if ! printf '%s' "$revision" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'; then
  fail "Refusing to install with a malformed source revision: $revision"
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Warning: the checkout has uncommitted changes; both components record $revision." >&2
fi
locked=$(sed -n 's/.*"opsmaru_incus": {:hex, :opsmaru_incus, "\([^"]*\)".*/\1/p' server/mix.lock)
if ! printf '%s' "$locked" | grep -Eq '^[0-9A-Za-z.+_-]{1,64}$'; then
  fail "server/mix.lock does not lock opsmaru_incus from Hex"
fi
cassette_name="opsmaru_incus-$locked.tama-cassette"

sha256() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

stage=$(mktemp -d "${TMPDIR:-/tmp}/macus-install.XXXXXX")
new_release=
cleanup() {
  rm -rf "$stage"
  if [ -n "$new_release" ]; then
    rm -rf "$new_release"
  fi
}
trap cleanup EXIT INT TERM

# The pinned opsmaru_incus cassette, obtained and checked before anything is
# built. Only the release build fetches it; installed startup never does.
cassette_repo=upmaru/opsmaru-incus
pin=
if [ -z "$release" ]; then
  missing_cassette() {
    fail "Refusing to install without the pinned opsmaru_incus $locked cassette: $1."
  }
  if ! command -v gh >/dev/null 2>&1; then
    missing_cassette "the GitHub CLI (gh) is required to download it and verify its attestation; install it and sign in with 'gh auth login'"
  fi
  if [ -z "$cassette" ]; then
    # The release for exactly the locked version, so a lock change fetches its own cassette.
    mkdir "$stage/cassette"
    if ! gh release download "v$locked" --repo "$cassette_repo" --dir "$stage/cassette" \
           --pattern "$cassette_name" --pattern "$cassette_name.sha256" </dev/null >"$stage/download.log" 2>&1; then
      missing_cassette "the $cassette_repo v$locked release does not provide $cassette_name and its .sha256 ($(tail -n 1 "$stage/download.log"))"
    fi
    cassette="$stage/cassette/$cassette_name"
  fi
  if [ "$(basename "$cassette")" != "$cassette_name" ]; then
    missing_cassette "$cassette is not $cassette_name, the version server/mix.lock locks"
  fi
  if [ -L "$cassette" ] || [ ! -f "$cassette" ]; then
    missing_cassette "$cassette is not a regular file"
  fi
  if [ -L "$cassette.sha256" ] || [ ! -f "$cassette.sha256" ]; then
    missing_cassette "$cassette.sha256 is missing"
  fi
  read -r pin pinned_name <"$cassette.sha256" || true
  if ! printf '%s' "$pin" | grep -Eq '^[0-9a-f]{64}$' || [ "${pinned_name:-}" != "$cassette_name" ]; then
    missing_cassette "$cassette.sha256 does not record $cassette_name"
  fi
  if [ "$(sha256 "$cassette")" != "$pin" ]; then
    missing_cassette "$cassette does not match its .sha256"
  fi
  # Provenance: built and attested by the opsmaru-incus release workflow.
  if ! gh attestation verify "$cassette" --repo "$cassette_repo" </dev/null >"$stage/attestation.log" 2>&1; then
    missing_cassette "$cassette has no valid $cassette_repo attestation ($(tail -n 1 "$stage/attestation.log"))"
  fi
  if command -v mise >/dev/null 2>&1; then
    set -- mise exec -- mix
  elif command -v mix >/dev/null 2>&1; then
    set -- mix
  else
    fail "Building the Macus server release requires Elixir and Erlang; run 'mise install' (see docs/development.md) or pass --release"
  fi
elif [ -L "$release" ] || [ ! -d "$release" ]; then
  fail "Refusing --release $release: it is not a release directory"
fi

# Swift: embed the identity in the executable's Info.plist. The file name
# carries the identity, so a different identity always relinks.
identity_dir="$root/.build/macus-identity"
mkdir -p "$identity_dir"
plist="$identity_dir/$version-$revision.plist"
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>MacusVersion</key>
  <string>$version</string>
  <key>MacusSourceRevision</key>
  <string>$revision</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null
swift build -c release -Xswiftc -warnings-as-errors \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"

binary_src=.build/release/macus
if [ ! -x "$binary_src" ]; then
  fail "Release build did not produce macus"
fi
cp "$binary_src" "$stage/macus"
chmod 755 "$stage/macus"
codesign --force --sign - --entitlements Packaging/virtualization.entitlements "$stage/macus"

# Reads the identity an executable embeds: "<version> <revision>".
embedded_identity() {
  rm -f "$stage/identity.plist"
  segedit "$1" -extract __TEXT __info_plist "$stage/identity.plist" 2>/dev/null ||
    fail "$1 embeds no Macus identity"
  printf '%s %s' \
    "$(plutil -extract MacusVersion raw -o - "$stage/identity.plist")" \
    "$(plutil -extract MacusSourceRevision raw -o - "$stage/identity.plist")"
}

verify_executable() {
  codesign --verify --strict "$1"
  entitlements=$(codesign -d --entitlements :- "$1" 2>/dev/null || true)
  case "$entitlements" in
    *com.apple.security.virtualization*) ;;
    *) fail "$1 is missing the virtualization entitlement" ;;
  esac
  if [ "$(embedded_identity "$1")" != "$version $revision" ]; then
    fail "$1 does not embed Macus $version ($revision)"
  fi
}
verify_executable "$stage/macus"

# The server release: assembled here from this checkout, or copied from
# --release, then verified from the staged copy.
if [ -z "$release" ]; then
  (
    cd server
    export MIX_ENV=prod MACUS_SOURCE_REVISION="$revision" \
      MACUS_CASSETTE_SHA256="$pin" MACUS_CASSETTE_PATH="$cassette"
    "$@" deps.get </dev/null
    "$@" release macus --path "$stage/release" </dev/null
  )
else
  cp -R -p "$release" "$stage/release"
fi

field() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

verify_release() {
  dir=$1
  manifest="$dir/macus-build.json"
  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
    fail "Refusing a server release without macus-build.json: $dir"
  fi
  if [ "$(stat -f '%Lp' "$manifest")" != 444 ]; then
    fail "Refusing a server release whose macus-build.json is not read-only: $dir"
  fi
  if [ "$(field schema_version "$manifest")" != 1 ]; then
    fail "Refusing a server release with an unknown macus-build.json: $dir"
  fi
  release_version=$(field version "$manifest")
  release_revision=$(field revision "$manifest")
  if [ "$release_version $release_revision" != "$version $revision" ]; then
    fail "Refusing a server release built as Macus $release_version ($release_revision): this checkout's macus is $version ($revision). Rebuild the release from this checkout; nothing was installed."
  fi
  if [ "$(field opsmaru_incus.version "$manifest")" != "$locked" ] ||
     [ "$(cd "$dir/lib" && ls -d opsmaru_incus-* 2>/dev/null)" != "opsmaru_incus-$locked" ] ||
     [ ! -f "$dir/lib/opsmaru_incus-$locked/ebin/opsmaru_incus.app" ]; then
    fail "Refusing a server release that does not bundle the pinned opsmaru_incus $locked: $dir"
  fi
  cassette_dir=$(ls -d "$dir"/lib/macus-*/priv/cassettes 2>/dev/null || true)
  recorded=$(field opsmaru_incus.cassette.sha256 "$manifest")
  if [ -z "$cassette_dir" ] || [ ! -d "$cassette_dir" ] ||
     [ "$(ls "$cassette_dir")" != "$cassette_name" ] ||
     [ -L "$cassette_dir/$cassette_name" ] || [ ! -f "$cassette_dir/$cassette_name" ] ||
     [ "$(sha256 "$cassette_dir/$cassette_name")" != "$recorded" ] ||
     { [ -n "$pin" ] && [ "$recorded" != "$pin" ]; }; then
    fail "Refusing a server release that does not bundle the pinned opsmaru_incus $locked cassette: $dir"
  fi
  erts=$(cd "$dir" && ls -d erts-* 2>/dev/null || true)
  if [ "$(printf '%s\n' "$erts" | grep -c .)" -ne 1 ] || [ ! -x "$dir/$erts/bin/erl" ] ||
     [ -L "$dir/bin/macus" ] || [ ! -x "$dir/bin/macus" ]; then
    fail "Refusing a server release without exactly one bundled ERTS and its launcher: $dir"
  fi
  if [ "$(field distribution "$manifest")" != none ] ||
     ! grep -qx 'export RELEASE_DISTRIBUTION=none' "$dir"/releases/*/env.sh; then
    fail "Refusing a server release that does not keep Erlang distribution off: $dir"
  fi
}
verify_release "$stage/release"

# Install: the release beside the executable, each replaced by a rename.
mkdir -p "$prefix/bin" "$prefix/libexec"
validate_destinations
new_release=$(mktemp -d "$prefix/libexec/.macus-new.XXXXXX")
cp -R -p "$stage/release/." "$new_release/"
chmod 755 "$new_release"
verify_release "$new_release"
if [ -e "$prefix/libexec/macus" ]; then
  previous="$new_release.previous"
  mv "$prefix/libexec/macus" "$previous"
  mv "$new_release" "$prefix/libexec/macus"
  new_release=
  rm -rf "$previous"
else
  mv "$new_release" "$prefix/libexec/macus"
  new_release=
fi
cp "$stage/macus" "$prefix/bin/.macus.new.$$"
chmod 755 "$prefix/bin/.macus.new.$$"
mv -f "$prefix/bin/.macus.new.$$" "$prefix/bin/macus"

verify_executable "$prefix/bin/macus"
verify_release "$prefix/libexec/macus"
"$prefix/bin/macus" --help >/dev/null
"$prefix/libexec/macus/bin/macus" version >/dev/null

echo "Installed macus $version ($revision) into $prefix/bin and its server release into $prefix/libexec/macus"
echo "Local source installation requires Swift and Elixir/Erlang. These ad-hoc signatures are not notarized."
echo "Runtime state was not modified. Launchd installation remains explicit."
