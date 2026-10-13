#!/bin/bash
# Build the core26-desktop base snap for CI (canonical/core-base-desktop,
# desktop/26). Usage: build-github.sh [plain|cloud-init]
#
# Two variants are built from the same snapcraft.yaml, selected by a
# top-level build-env file that the build-env part's override-pull
# reads (its comment: "can be manually created for local builds") -
# the same mechanism Launchpad recipe builds use via
# SNAPCRAFT_IMAGE_INFO, and the same split upstream canonical/core-base
# release.yaml's `variant: [regular, fips, cloud-init]` matrix uses:
#
#   - plain (default): what the GNOME image consumes. No cloud-init;
#     first-boot account creation is handled by ubuntu-desktop-init's
#     wizard instead (2026-10-09 decision, when GNOME was the only
#     desktop and nothing needed cloud-init).
#   - cloud-init: what the KDE image consumes. KDE has no such wizard
#     yet, so the guest account is created by cloud-init from a
#     companion seed.iso at first boot (see
#     ubuntu-core-desktop/build-cloud-init.sh) - that requires
#     cloud-init actually be present in the base snap, which only this
#     variant includes (snapcraft.yaml: SLICES+=(cloud-init_bins) iff
#     SNAP_BUILD_VARIANT=cloud-init). Discovered missing the hard way:
#     a built KDE image's seed.iso was silently never processed,
#     because the "plain" base snap it was built against has no
#     cloud-init at all to consume it (GH run 38334812565 booted fine
#     but `getpwnam(guest)` failed - no account was ever created).
#
# The fakeroot repack is kept verbatim from
# localdev_patch_built_snap_mksquashfs (local-dev/go-build-lib.sh): it
# normalises meta/snap.yaml's name to core26-desktop, which
# ubuntu-core-desktop's build.sh and the pc-desktop gadget expect.
set -euo pipefail

variant="${1:-plain}"
case "${variant}" in
  plain)
    out="core26-desktop.snap"
    rm -f build-env
    ;;
  cloud-init)
    out="core26-desktop-cloudinit.snap"
    echo "SNAP_BUILD_VARIANT=cloud-init" > build-env
    ;;
  *)
    echo "Unknown variant: ${variant} (expected 'plain' or 'cloud-init')" >&2
    exit 1
    ;;
esac

snapcraft pack

src=$(ls -t core*.snap | head -1)
tmp=$(mktemp -d ./snap-patch-tmp.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fakeroot -- sh -c '
    unsquashfs -d "$1/squashfs-root" -f "$2" >/dev/null
    sed -i "$3" "$1/squashfs-root/meta/snap.yaml"
    mksquashfs "$1/squashfs-root" "$4" -noappend -comp xz -no-fragments -no-progress -xattrs
' -- "$tmp" "$src" 's/^name: core26$/name: core26-desktop/' "${out}"
