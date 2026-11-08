# Build variants of the core26 base snap

This repository builds several variants of the core26 base snap. All
variants share the same snapcraft project and build pipeline; a variant
only changes what the name implies (extra packages, extra files, extra
wiring), never the build system itself.

# Selecting a variant

The selected variant is communicated to the build through the
`SNAP_BUILD_VARIANT` variable, which the `build-env` part picks up:

* **Local builds**: write a `build-env` file into the project root
  containing a single line, e.g. `SNAP_BUILD_VARIANT=desktop`, before
  running `snapcraft pack` (or use `tools/build-variant.sh`, which
  does this for you and removes the file afterwards).
* **Launchpad builds**: nothing to do. The `build-env` part parses
  `SNAPCRAFT_IMAGE_INFO` for the recipe build URL
  (`.../core26-<variant>/+build/<id>`) and derives the variant name
  from it. The Launchpad recipe must be named `core26-<variant>`.

Consequences of a selected variant (all handled by existing machinery,
no per-variant code needed):

* the snap version becomes `<date>+<variant>`;
* `SNAP_BUILD_NAME` (staged `build-env` file) becomes
  `core26-<variant>`;
* parts and hooks can branch on `$SNAP_BUILD_VARIANT` (e.g. the
  `chisel-libs` part adds the `cloud-init_bins` slice for the
  `cloud-init` variant, hooks `005`/`011` do cloud-init wiring).

# Variant payload

A variant may carry a payload directory, `variants/<variant>/`, whose
contents are applied to the rootfs during the build (see the `install`
target in the Makefile, which calls `tools/apply-variant-payload.sh`
after the base `static/` files are copied and before the hooks run):

| knob | path | effect |
|---|---|---|
| extra files | `variants/<v>/static/` | copied verbatim into the rootfs, on top of the base `static/` files (same-path variant file wins). Top-level hidden files are not copied, mirroring the base `static/` copy. |
| fstab | `variants/<v>/fstab.d/*.conf` | appended to `/etc/fstab`, in glob order |
| tmpfiles.d | `variants/<v>/writable.conf.d/*.conf` | appended to `/usr/lib/tmpfiles.d/core-writable.conf`, in glob order |

Rules for the fragment knobs:

* `fstab.d/` entries follow the same conventions as `static/etc/fstab`
  (see the "Writable paths" section of the top-level README): bind
  mounts of `/writable/system-data/...`, with `x-initrd.mount` for
  `/etc` paths.
* every `C` line added through `writable.conf.d/` needs a matching
  fstab entry and matching template data in `/usr/share/factory`
  (ship the latter through the `static/` knob); the
  `993-factory-files` build-time test enforces this.
* `d` lines may additionally target paths nested under an existing
  mount (no fstab entry of their own), to pin individual skeleton
  entries inside a mounted tree — e.g. the desktop variant's
  `writable.conf.d/snapd-skeleton.conf` re-asserts
  `/var/lib/snapd/{void,cache,lib/*}` in the writable layer, because
  snapd's initrd can create the `/var/lib/snapd` destination (writable
  defaults / kernel drivers tree) before the factory `C` copy runs,
  and systemd-tmpfiles never populates an existing destination.
* fragment files must be complete lines; a comment-only or empty file
  is valid and changes nothing.

A variant without a payload directory is fine — the `cloud-init`
variant predates this mechanism and lives entirely in part/hook
branches on `$SNAP_BUILD_VARIANT`.

# Snap naming

`snapcraft.yaml` keeps the static project name `core26` (changing it
would swap snapcraft's project-keyed LXD build instance and lose the
incremental build state). `tools/build-variant.sh` therefore packs the
build result a second time from the build instance's prime directory
with `meta/snap.yaml`'s `name:` patched to `core26-<variant>`, done as
real root inside the LXD container so file ownership and the `/dev`
device nodes survive the round trip. The result is
`core26-<variant>_<version>_<arch>.snap`.

# Existing variants

* `desktop` — adds the custom core26-desktop base's writable-mount
  set: fstab bind mounts + core-writable.conf C-lines for
  `/etc/colord`, `/etc/firefox`, `/var/lib/AccountsService`,
  `/var/lib/gdm3`, `/usr/share/wayland-sessions`,
  `/usr/share/polkit-1`, `/var/lib/colord` and `/var/lib/fprint`, plus
  a tmpfs on `/var/cache/colord` (see `fstab.d/`, `writable.conf.d/`
  and the mount-point directories in `static/`; factory templates are
  copied from the rootfs itself by `hooks-build/100-factory-files.build`
  when `SNAP_BUILD_VARIANT=desktop`).
* `cloud-init` — adds cloud-init (no payload directory; see the
  `chisel-libs` part and hooks `005`/`011`).
