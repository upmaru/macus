#!/bin/sh
set -eu
umask 077

boot=${TAMA_BOOT_ROOT:-}
expected=$boot/etc/macus-appliance-expected
record=$boot/etc/macus-appliance-image

mismatch() {
    echo 'MACUS_OBSERVATION v1 stage=failed code=image_mismatch' >&2
    printf 'TAMA_APPLIANCE_IMAGE_MISMATCH: %s\n' "$1" >&2
    exit 1
}

echo 'MACUS_OBSERVATION v1 stage=image'
# The host renders the exact supported format from pinned metadata.
[ "$(sed -n '1p' "$expected" 2>/dev/null)" = format=1 ] &&
    cmp -s "$expected" "$record" || mismatch 'image record differs from the seed'
kernel=$(sed -n 's/^kernel_release=//p' "$expected")
[ -n "$kernel" ] && [ "$(uname -r)" = "$kernel" ] &&
    printf '%s\n' "$kernel" | cmp -s - "$boot/etc/tama-zfs-qualified-kernel" ||
    mismatch 'booted kernel or qualified-kernel record differs from the seed'

manifest=$(mktemp "$boot/run/macus-manifest.XXXXXX") || mismatch 'cannot stage installed manifest'
trap 'rm -f "$manifest"' EXIT
apk info -v > "$manifest" && [ -s "$manifest" ] || mismatch 'cannot read installed packages'
actual=$(LC_ALL=C sort "$manifest" | sha256sum) || mismatch 'cannot hash installed manifest'
expected_digest=$(sed -n 's/^manifest_sha256=//p' "$expected")
[ "${actual%% *}" = "$expected_digest" ] || mismatch 'installed manifest digest differs from the seed'
echo 'MACUS_OBSERVATION v1 stage=image state=verified'
