#!/bin/bash
# Build the core26-desktop base snap for CI (canonical/core-base-desktop,
# desktop/26).
#
# Mirrors the local go-build recipe MINUS the SNAP_BUILD_VARIANT=cloud-init
# opt-in (2026-10-09 decision: the published core-desktop image has no
# pre-created account and no seed.iso, so nothing consumes cloud-init;
# snapcraft.yaml's build-env part treats a missing build-env file as
# variant-less).  The fakeroot repack is kept verbatim from
# localdev_patch_built_snap_mksquashfs (local-dev/go-build-lib.sh): it
# normalises meta/snap.yaml's name to core26-desktop, which
# ubuntu-core-desktop's build.sh and the pc-desktop gadget expect.
set -euo pipefail

snapcraft pack

src=$(ls -t core*.snap | head -1)
tmp=$(mktemp -d ./snap-patch-tmp.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fakeroot -- sh -c '
    unsquashfs -d "$1/squashfs-root" -f "$2" >/dev/null
    sed -i "$3" "$1/squashfs-root/meta/snap.yaml"
    mksquashfs "$1/squashfs-root" "$4" -noappend -comp xz -no-fragments -no-progress -xattrs
' -- "$tmp" "$src" 's/^name: core26$/name: core26-desktop/' core26-desktop.snap
