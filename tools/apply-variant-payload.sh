#!/bin/bash
#
# Apply a build variant's payload to a rootfs that is being assembled.
#
# Usage: apply-variant-payload.sh <rootfs> <variant>
#
# Called from the Makefile "install" target (and exercised by
# hook-tests/995-variant-payload.test). <rootfs> is the rootfs the base
# snap is assembled into, <variant> the value of SNAP_BUILD_VARIANT.
# See variants/README.md for the payload layout.
#
# Runs inside the snapcraft build environment as root, with the current
# directory set to the project source tree.

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <rootfs> <variant>" >&2
    exit 1
fi

rootfs="$1"
variant="$2"

case "$variant" in
    *[!a-z0-9-]*)
        echo "E: invalid variant name '$variant'" >&2
        exit 1
        ;;
esac

payload="$(cd "$(dirname "$0")/.." && pwd)/variants/$variant"

if [ ! -d "$payload" ]; then
    echo "I: variant '$variant' has no payload directory, nothing to apply"
    exit 0
fi

echo "I: applying variant payload from $payload"

# (a) extra files, copied verbatim into the rootfs on top of the base
# static/ files (a same-path variant file wins). Top-level hidden
# files are skipped, mirroring the base "cp -a static/*" copy.
if [ -d "$payload/static" ]; then
    for entry in "$payload"/static/*; do
        [ -e "$entry" ] || continue
        echo "I: copying $(basename "$entry") into the rootfs"
        cp -a "$entry" "$rootfs/"
    done
fi

# Append a fragment to a file, keeping the file's trailing newline
# intact so appended fragments stay complete lines.
append_fragment() {
    target="$1"
    fragment="$2"
    if [ -s "$target" ] && [ -n "$(tail -c 1 "$target")" ]; then
        printf '\n' >> "$target"
    fi
    cat "$fragment" >> "$target"
}

# (b) fstab fragments appended to /etc/fstab, in glob order.
for f in "$payload"/fstab.d/*.conf; do
    [ -e "$f" ] || continue
    echo "I: appending $(basename "$f") to /etc/fstab"
    append_fragment "$rootfs/etc/fstab" "$f"
done

# (c) tmpfiles.d fragments appended to core-writable.conf, in glob
# order. Every C line added here needs a matching fstab entry (knob b)
# and template data under /usr/share/factory (knob a); the
# 993-factory-files build-time test enforces this.
for f in "$payload"/writable.conf.d/*.conf; do
    [ -e "$f" ] || continue
    echo "I: appending $(basename "$f") to core-writable.conf"
    append_fragment "$rootfs/usr/lib/tmpfiles.d/core-writable.conf" "$f"
done
