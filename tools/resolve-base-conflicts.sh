#!/bin/bash
# chisel-libs (staged into ${CRAFT_STAGE} before any part declaring
# "after: [chisel-libs]" runs its own override-build) can ship files
# under the same path as a package staged by that other part - e.g.
# both sides resolve overlapping core packages such as systemd,
# coreutils, tzdata and xkeyboard-config, because chisel-libs slices a
# moving package archive independently of the plain stage-packages
# used elsewhere. Every part that relocates its apt-staged output into
# base/ (see the "See desktop-packages' override-build..." comment in
# snapcraft.yaml) needs to reconcile any resulting overlap, so that
# logic lives here once instead of being copy-pasted into every part.
#
# Rather than hand-maintaining a list of every individual path this
# happens to affect today - a list that silently goes stale as either
# side's packages/versions change - give chisel-libs unconditional
# priority: drop our copy of any path it already staged, whatever that
# path happens to be. Only step in when the two copies actually
# differ; many overlapping paths come from the very same package
# version on both sides and are already identical, so there's nothing
# to resolve there.
#
# Usage: resolve-base-conflicts.sh <part-install-base-dir>
# e.g. resolve-base-conflicts.sh "${CRAFT_PART_INSTALL}/base"

set -euo pipefail

base_dir="$1"

# Normalize a slash-separated path, resolving "." and ".." segments
# lexically (no filesystem access, just string manipulation) - used to
# compare symlink targets that may be written as relative or absolute
# even when they point at the exact same real file (e.g. systemd's
# usr/sbin/halt -> ../bin/systemctl from a plain .deb vs chisel-libs'
# own usr/sbin/halt -> /usr/bin/systemctl slice).
normalize_path() {
  local path="$1" part result=()
  local IFS='/'
  read -ra parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | ".") continue ;;
      "..") [ "${#result[@]}" -gt 0 ] && unset 'result[-1]' ;;
      *) result+=("$part") ;;
    esac
  done
  echo "${result[*]}"
}

# Resolve a symlink's raw readlink target to a path relative to the
# eventual base/ root, so both an absolute target (meant to be
# relative to the final merged rootfs) and a relative target (relative
# to the symlink's own directory) can be compared on equal footing.
symlink_target_rel_to_base() {
  local rel="$1" raw_target="$2" dir
  case "$raw_target" in
    /*) normalize_path "${raw_target#/}" ;;
    *)
      dir="${rel%/*}"
      [ "$dir" = "$rel" ] && dir=""
      normalize_path "${dir:+$dir/}$raw_target"
      ;;
  esac
}

paths_match() {
  local a="$1" b="$2" rel="$3"
  if [ -L "$a" ] || [ -L "$b" ]; then
    # snapcraft's own stage-conflict check compares the literal
    # symlink target text, not what it resolves to, so only a literal
    # match here is actually a non-issue for it. Two symlinks that
    # merely resolve to the same real file but are written differently
    # (e.g. "../bin/systemctl" vs "/usr/bin/systemctl") still count as
    # a conflict as far as snapcraft is concerned and must still be
    # resolved below - symlink_target_rel_to_base is only used
    # separately, to word the log line, not to decide this.
    [ -L "$a" ] && [ -L "$b" ] && [ "$(readlink "$a")" = "$(readlink "$b")" ]
  elif [ -d "$a" ] && [ -d "$b" ]; then
    [ "$(stat -c%a "$a")" = "$(stat -c%a "$b")" ]
  elif [ -f "$a" ] && [ -f "$b" ]; then
    [ "$(stat -c%a "$a")" = "$(stat -c%a "$b")" ] && cmp -s "$a" "$b"
  else
    false
  fi
}

# Snapcraft keeps each part's downloaded .debs around in a
# "stage_packages" directory next to its install/ dir - build a
# path -> owning-package index from them up front, purely so the
# conflict log below can name the dpkg package involved. Best-effort:
# if the cache or dpkg-deb isn't available for some reason, conflicts
# are still resolved, just without a package name in the log line.
declare -A path_to_pkg
stage_pkgs_dir="$(dirname "${CRAFT_PART_INSTALL:-}")/stage_packages"
if [ -d "$stage_pkgs_dir" ] && command -v dpkg-deb >/dev/null 2>&1; then
  for deb in "$stage_pkgs_dir"/*.deb; do
    [ -e "$deb" ] || continue
    pkg="$(basename "$deb")"
    pkg="${pkg%%_*}"
    while IFS= read -r p; do
      # dpkg-deb -c lists the archive root itself as "./", which
      # normalizes to an empty string here - bash rejects an empty
      # associative-array subscript, and it's not a useful entry to
      # index anyway, so skip it.
      [ -n "$p" ] && path_to_pkg["$p"]="$pkg"
    done < <(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $NF}' | sed 's#^\./##; s#/$##')
  done
fi

while IFS= read -r -d '' f; do
  rel="${f#"$base_dir"/}"
  target="${CRAFT_STAGE}/base/$rel"
  pkg="${path_to_pkg[$rel]:-}"
  pkg_suffix=""
  [ -n "$pkg" ] && pkg_suffix=" (dpkg package: $pkg)"
  # Use -e -o -L rather than just -e: chisel-libs can stage a symlink
  # whose target doesn't exist yet at this point in the build (resolved
  # later, e.g. by the hooks part's Makefile fix-up), and plain -e
  # follows symlinks, so it would report a dangling one as "not
  # present" and miss the conflict entirely.
  if { [ -e "$target" ] || [ -L "$target" ]; } && ! paths_match "$f" "$target" "$rel"; then
    if [ -d "$f" ] && [ ! -L "$f" ] && [ -d "$target" ] && [ ! -L "$target" ]; then
      # Both sides are real directories (not a symlink standing in for
      # one, e.g. var/lock/var/run) that can differ in mode without
      # either side actually owning distinct content underneath -
      # dropping the directory outright could take unique files below
      # it with it, so just align its permissions with chisel-libs'
      # instead of removing it.
      echo "dpkg/chisel conflict detected for $rel$pkg_suffix, aligning directory permissions with chisel version"
      chmod --reference="$target" "$f"
    elif [ -L "$f" ] && [ -L "$target" ] && \
         [ "$(symlink_target_rel_to_base "$rel" "$(readlink "$f")")" = \
           "$(symlink_target_rel_to_base "$rel" "$(readlink "$target")")" ]; then
      # Both sides are symlinks to the same real file, just written
      # differently (relative vs. absolute) - not a real version
      # conflict, but the literal text still has to match for
      # snapcraft's own stage-conflict check, so drop ours anyway.
      echo "dpkg/chisel conflict detected for $rel$pkg_suffix, both resolve to the same target, dropping differently-formatted dpkg version"
      rm -rf "$f"
    else
      # Either a plain file/symlink, or a directory-vs-symlink type
      # mismatch (e.g. a var/lock directory vs chisel-libs' var/lock ->
      # /run/lock symlink) - chisel-libs wins outright, whatever "$f"
      # actually is.
      echo "dpkg/chisel conflict detected for $rel$pkg_suffix, dropping dpkg version"
      rm -rf "$f"
    fi
  fi
done < <(find "$base_dir" -mindepth 1 -print0)
