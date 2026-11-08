# ARM64 (arm64/aarch64) enablement recon — thin-variant Ubuntu Core Desktop images

Status (2026-11-08): the Phase-1 amd64 parameterization from §6 has
landed in this repository (the @MULTIARCH@ payload placeholder, hook 995
triplet derivation, the snapcraft.yaml platforms declaration and the
tools/build-variant.sh arch guard). The arm64 build itself is DEFERRED
until an arm64 build environment/hardware is available — TCG emulation
was evaluated and rejected for builds and boot verification alike.
Everything below is the roadmap reference for that work.

Status update (2026-11-08, later): §2's option (b) landed — the
build-snap-variant.yml workflow now builds the variant natively on
GitHub's ubuntu-24.04-arm hosted runner, and this branch declares
`platforms: amd64: arm64:`. §1.4's payload ELF re-sourcing is done the
maintainer-endorsed way: the PAM/NSS modules are staged from archive
debs at build time (the desktop-payload-debs part — the debs resolve
natively per build architecture) and xdg-fuse-broker is built from the
in-tree fuse-broker/ source (the fuse-broker part); no vendored ELFs
remain. Still open from this roadmap: the arm64 IMAGE (build.sh model
defaults, gadget-arm64.yaml seed size/defaults port, §3's content-snap
arm64 platform entries) and the §5 boot verification.

Scope: parameterize arch-hardcoded content, build an arm64 thin-variant base + GNOME
image, boot-verify under qemu-system-aarch64. READ-ONLY recon, 2026-11-08.
Repos inspected: `~/git/worktrees/core-base-variant` (thin core26-desktop variant,
branch of `~/git/core-base`), `~/git/worktrees/ubuntu-core-desktop-base-swap`
(image build), `~/git/pc-amd64-gadget-desktop` (gadget), local snap repos.

## 1. Parameterization sites (complete list)

Headline: **16 tracked text/config sites, 7 real ELF payload binaries, one
triplet-named payload dir holding 10 triplet-target symlinks.**

### core-base-variant (base snap) — 6 sites

1. `hooks/995-gnome-content-lib-symlinks.chroot` L26-27: `libdir=/usr/lib/x86_64-linux-gnu`,
   `content=/snap/gnome-desktop-runtime/current/usr/lib/x86_64-linux-gnu` (both must
   become `aarch64-linux-gnu` on arm64). Everything else in the hook (gbm/dri dirs,
   share links) derives from those two vars — fix the vars, the rest follows.
2. `variants/desktop/static/usr/lib/systemd/user/gnome-initial-setup.service` L25:
   ExecStart embeds the literal triplet **4 times** (LD_LIBRARY_PATH ×2 targets,
   GIO_EXTRA_MODULES, GDK_PIXBUF_MODULE_FILE).
3. `variants/desktop/static/usr/lib/x86_64-linux-gnu/` — the directory itself is
   triplet-named; contains 10 symlinks whose *targets* embed the triplet
   (7 libs + dri/gbm/mutter-18 dirs → `/snap/gnome-desktop-runtime/current/usr/lib/<triplet>/...`).
   The other ~116 payload symlinks are triplet-free (share/ paths).
4. Real ELF binaries in the variant payload, all x86-64, need arm64 re-sourcing
   (none in the base `static/` — all 7 are desktop-variant payload):
   - `variants/desktop/static/usr/bin/xdg-fuse-broker` (static Go; cross-builds via
     GOARCH=arm64 — source repo per session-brokers.txt)
   - `variants/desktop/static/usr/lib/security/pam_gdm.so` (from gdm3 deb)
   - `variants/desktop/static/usr/lib/x86_64-linux-gnu/libnss_systemd.so.2` (systemd deb)
   - `variants/desktop/static/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so`,
     `pam_gnome_keyring.so`, `pam_systemd_loadkey.so` (fprintd / gnome-keyring /
     systemd debs)
   - `variants/desktop/static/usr/sbin/chpasswd` (UCD passwd overlay).
   Preferred fix: extract at build time from arm64 debs inside the arm64 build
   container (the fat base's `ucd-ppa-overlays` part already builds shadow/adduser
   from source with `-a"$(dpkg --print-architecture)"` — reuse that pattern); or
   per-arch payload dirs.
5. `tools/build-variant.sh` L54: `arch=$(dpkg --print-architecture)` + L99 instance
   grep `snapcraft-core26-${arch}-`. Works unchanged in an arm64-native build env;
   only needs an explicit `--arch`/env override if cross-building is ever attempted.
6. `hook-tests/001-foreign-libc6.test`: amd64 bi-arch assertion — silently no-ops on
   arm64 (dir check fails → pass). Optionally gate on arch; not a blocker.

Arch-clean already (no change needed): hooks 005 (uname-m→ARCH map incl. arm64),
031 (all-arch ld.so list), 017 (arm64 fw_env.config), snapcraft.yaml's
`case "$(dpkg --print-architecture)"` slice blocks (arm64 gets
secureboot-db/nvidia slices; i386 foreign cut is amd64-only, correct), Makefile,
apply-variant-payload.sh. Caveat: `snapd-files` part copies the *build env's*
`/usr/lib/systemd/system-generators/snapd-generator` — right arch only when the
whole build runs in an arm64 environment (another reason cross-build is out).

### build.sh (ubuntu-core-desktop-base-swap) — 8 sites

7. `kde_sddm_integration()` L417 and `kde_plasma_setup_integration()` L753:
   `triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"` — returns the *host*
   triplet; on an amd64 host building an arm64 image every downstream use
   (dri/gbm symlinks, sddm-helper wrapper, plasma-setup libexec, kauth symlink,
   SDDM/plasma-setup env blocks at L553-559/581-584/667-670/895-898/904-937) is
   wrong. Fix: one `TARGET_TRIPLET` computed from a new `--arch` (map amd64→
   x86_64-linux-gnu, arm64→aarch64-linux-gnu, or `dpkg-architecture -a <arch>
   -qDEB_HOST_MULTIARCH`) and pass down. The GNOME branch of build.sh itself is
   triplet-free (its triplet paths live in the base payload/hook — items 1-3).
8. `cmdline_extra` hardcodes `console=ttyS0,115200n8` twice (L1088 default, L1236
   `--debug`). arm64 QEMU virt serial is **ttyAMA0**; without this the serial
   console (the primary boot-diagnosis channel) is silent. Parameterize on arch.
9-10. Default model JSONs are amd64-named: L1145 `ubuntu-core-desktop-26-amd64-dangerous.json`
   (gnome), L1149 `ubuntu-core-desktop-kde-26-amd64-dangerous.json` (kde); need
   arch-aware defaults or a new arm64 pair.
11-13. Repo-root model JSONs (3 files) + `ci/*.model` (3 pre-signed files): each is
   a per-arch file (`"architecture": "amd64"`). Snap-ids are arch-independent, so an
   arm64 model = copy with `architecture: arm64`, new model name, same snap-ids and
   channels; re-sign via `snap sign -k test`. `--model` already overrides.
- `ubuntu-image snap -v ...` (L1749) takes NO arch flag — it derives arch from the
  model assertion; correct arm64 behavior falls out of item 9-13. Gadget
  repack/connections/cmdline.extra baking is arch-neutral otherwise.

### gadget (pc-amd64-gadget-desktop) — 2 sites

14. `snapcraft.yaml` L10-12 `platforms: amd64:` only — add `arm64:`. Everything
    else is already arch-conditional upstream: `boot-assets` part switches to
    grub-efi-arm64-signed/shimaa64/fbaa64/BOOTAA64.CSV, `mbr` part exits on
    non-amd64, and the `gadget` part installs `gadget-${CRAFT_ARCH_BUILD_FOR}.yaml`.
15. `gadget/gadget-arm64.yaml` exists (upstream pc-gadget lineage, present since
    origin/26) but is the vanilla shape, missing the amd64 file's desktop additions:
    `defaults:` block (experimental.user-daemons, experimental.dbus-activation,
    refresh.retain: 2, service.ssh.listen-address — build.sh L1255 seds that value,
    so it must exist), and the seed partition is 1200M vs amd64's **7000M** — the
    thin seed (base+kernel+snapd+gadget+session+content+wizard snaps, pc-kernel
    arm64 alone is 387MB) will not fit 1200M; port the size (+edition) and the
    defaults. `connections:` are baked by build.sh at image time (arch-neutral).

### local snap repos — 3 sites (+1 already done)

16. `platforms:` blocks: `ubuntu-desktop-session-snap` (amd64 only; body is fully
    `$CRAFT_ARCH_TRIPLET_BUILD_FOR`-generic, no ELF shipped), `gnome-desktop-runtime`
    (amd64 only; layout/env already triplet-variable; apt stage-packages), `pipewire-snap`
    (no platforms block at all → host-arch naming). Add arm64 entries to all three.
    Already multi-arch: `ubuntu-desktop-provision` (amd64+arm64 — and store
    ubuntu-desktop-init has an arm64 revision), snapd fork's build-aux snapcraft.yaml
    (upstream per-arch DYNAMIC_LINKER anchors incl. arm64; libseccomp built from
    source, cgo — needs a native arm64 build env, not GOARCH cross).

## 2. The variant build for arm64

- Upstream core26 does NOT cross-build: `tests.yaml` builds arm64 by running the
  same spread build task on an arm64 openstack cloud (`openstack-arm-ext`),
  artifacts named `core26_arm64.artifact`; daily releases go through
  `snapcore/system-snaps-cicd-tools/action-rebase-base` → **Launchpad recipes**
  (native arm64 LP builders; the `build-env` part already parses LP's
  SNAPCRAFT_IMAGE_INFO to detect variants). No `--target-arch` anywhere.
- `tools/build-variant.sh <variant>` takes no arch; `tools/build-github.sh` does
  not exist in this repo (only build-snap-variant.yml, which runs on amd64 GH
  runners).
- snapcraft `--target-arch` is NOT viable here: the build runs chroot hooks that
  execute the target arch's binaries (`systemctl preset-all`, ldconfig,
  python3-compile, systemd-tmpfiles...), copies host-arch snapd-generator, and the
  chisel slice selection keys off the build env's dpkg arch. Cross would need
  binfmt everywhere plus per-part fixes; the honest answer is **an arm64 build
  environment**:
  - (a) **qemu-user + binfmt LXD container on this host**: qemu-user-static is NOT
    installed (binfmt_misc has only python3.14 registered, no qemu-aarch64
    interpreter present). `apt install qemu-user-static` + register, then
    `lxc launch images:ubuntu/26.04/arm64 ...` and run snapcraft inside; LXD 5.21
    supports foreign-arch containers via binfmt. Everything under TCG: expect the
    ~10-15 min amd64 base build to become ~1-3 h (chisel/apt staging is IO-bound
    and fares best; the Rust `generators` part is the compile long pole).
  - (b) remote arm64 LXD machine / GH arm64 runner (`ubuntu-24.04-arm` is free for
    public repos) — fastest, matches the upstream GH-workflow shape
    (build-snap-variant.yml moves to an arm64 runner + `build-variant.sh desktop`).
  - (c) Launchpad recipe named `core26-desktop-thin` style — the zero-code path
    the variant machinery already supports (SNAPCRAFT_IMAGE_INFO parsing), but
    needs LP setup and is slower to iterate.

## 3. The snap set for arm64

Store snaps — **all confirmed arm64-ready** (checked api.snapcraft.io v2/info with
X-Ubuntu-Architecture: arm64, identical 26-track revisions on both arches):

| snap | channel | arm64 revision |
|---|---|---|
| pc-kernel | 26/stable | r3755 (same as amd64) |
| network-manager | 26/stable | r1074 |
| udisks2 | 26/stable | r126 |
| upower | 26/stable | r17 |
| avahi | 26/stable | r890 |
| bluez | 26/stable | r410 |
| snap-store | 2/stable | r1468 |
| core26 / core24 / bare / gtk-common-themes / snapd / ubuntu-desktop-init / gnome-46-2404 / mesa-2404 / pc-desktop | latest/2/26 | arm64 revisions present |

(the model's gnome-46-2404/mesa-2404 are fat-image leftovers, likely unmounted in
the thin image, but they exist for arm64 if seeded.)

Local snaps and their arm64 story:
- **core26-desktop thin base** — arm64 build env (§2); the ELF payload is the main
  arch work (§1.4).
- **pc-desktop gadget** — repo is arch-ready (arm64 grub/shim handling + arm64
  gadget.yaml shipped upstream since the 26 branch); add the arm64 platform, port
  seed-size + defaults into gadget-arm64.yaml, build in arm64 env. No separate arm
  gadget source needed — this is THE gadget for both arches.
- **snapd fork** — pure Go + self-built libseccomp (cgo): build in arm64 env
  (native), or store snapd arm64 as fallback.
- **ubuntu-desktop-session** — scripts only, add platform, rebuild (or verify no
  ELF) — trivial.
- **gnome-desktop-runtime / pipewire** — apt stage-packages from resolute (arm64
  exists); add platform entries; rebuild in arm64 env. Mutually version-matched —
  rebuild both together.
- **ubuntu-desktop-init (provision/provd)** — platforms already amd64+arm64;
  store arm64 candidate r133 exists → for a first arm64 image, take the store
  revision instead of building Flutter locally (Flutter arm64 cross-build is a
  project of its own).
- **KDE set (kf6-core26, plasma-core26-desktop, plasma-desktop-session)** —
  BLOCKED for arm64: the deb-repack pipeline is amd64-only (Neon release/resolute
  has no kwin/plasma arm64 binaries), and the from-source pipeline would require
  arm64 Qt6/KF6 SDK snaps that don't exist. ARM is GNOME-thin only for now; keep
  build.sh's kde branch compiling (triplet param is still worth doing) but don't
  gate arm64 delivery on KDE.

## 4. The image build for arm64

- build.sh needs no ubuntu-image changes: arch comes from the model; all local
  snaps are passed explicitly (`--snap`), so store per-arch resolution only hits
  pc-kernel/network-manager/udisks2/upower/avahi/bluez/snap-store/core26/core24/bare
  — all arm64-available. Keep local gadget/base/snapd/session/content snap names
  identical to the model entries (the known "store gadget sneaks in" trap).
- New `ubuntu-core-desktop-26-arm64-dangerous.json` + signed `ci/...-arm64-dangerous.model`
  (+ optional non-dangerous) with `"architecture": "arm64"`; build.sh model defaults
  per §1.9-13. Same account-key assertion works (arch-neutral brand key).
- Kernel: pc-kernel 26/stable arm64 r3755 — exists, generic ubuntu kernel with
  virtio + initramfs; no kernel-side work expected.
- `--image-size 20G`, fakeroot flow, gadget repack: arch-neutral except the
  cmdline.extra console= (§1.8).

## 5. QEMU verification setup (host facts verified)

Available NOW:
- qemu-system-aarch64 10.2.1 (+ qemu-system-arm), qemu-efi-aarch64 2025.11 with
  `/usr/share/AAVMF/AAVMF_CODE.fd` (→ no-secboot, 2MB code pflash) and
  `AAVMF_VARS.fd` (64MB vars pflash) — UEFI boot chain matches the gadget's
  grubaa64/shimaa64 EFI payload.
- `/dev/kvm` present but useless for aarch64 (TCG only); 32-core/119GB host — give
  the VM `-smp 16 -m 8192` (MTTCG scales per-vCPU).
- NOT available: qemu-user / qemu-user-static (no binfmt arm64 handler — matters
  for §2a only, not for booting).
Proposed boot command (go-run-gnome pattern, arm64 form):

```
cp /usr/share/AAVMF/AAVMF_VARS.fd /tmp/AAVMF_VARS.fd   # writable vars, once
qemu-system-aarch64 \
  -M virt,gic-version=3 -cpu max -accel tcg,thread=multi \
  -smp 16 -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/tmp/AAVMF_VARS.fd \
  -drive file=build/pc.img,if=none,format=raw,id=hd0 \
  -device virtio-blk-pci,drive=hd0 \
  -device virtio-gpu-pci,edid=on -vnc 127.0.0.1:1 \
  -netdev bridge,br=qemubr0,id=net0 \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:a1:b2:c7 \
  -serial unix:/tmp/arm-serial.sock,server=on,wait=off
# serial: nc -U /tmp/arm-serial.sock  (display: -display none under TCG is kinder;
# add -device virtio-gpu-gl-pci only if interactive GL is actually attempted)
```
Keep the flock/lockfile + bridge-helper setuid gotchas from go-run-gnome
(qemu-bridge-helper setuid + `/etc/qemu/bridge.conf` allow line; or slirp
`-netdev user` for a sandboxed first pass).

Performance honesty: TCG is ~10-20× slower than the KVM x86 loop the gates were
designed around. Expect: install-mode first boot (snapd seeding, mksquashfs of the
seed set, apparmor load, wizard) **30-90 min, possibly worse**; reboot-to-greeter
**10-30 min**. Measure once with the real image and re-estimate before scheduling
gate runs. Scale the gates: must-pass under emulation = seeded boot, run-mode
transition, GDM greeter or wizard UI reachable via VNC, SSH in, `snap list`
complete, no snapd failure loop; full interactive desktop session is stretch
(VNC + patience), and GL/wayland rendering under virtio-gpu+virgl is explicitly
NOT a gate (TCG GL is miserable and tells you nothing about real arm64 GPUs).

## 6. Sequenced implementation plan

Phase 0 — decide the build-env route (qemu-user LXD vs arm64 runner vs LP recipe).
Recommended: install qemu-user-static locally for iteration; stand up an arm64 GH
runner workflow for repeatable builds (mirrors upstream's native-arch pattern).

Phase 1 — parameterization (pure amd64-refactor, verified by an amd64 image that
must boot identically):
1. core-base-variant: triplet via `dpkg-architecture`/CRAFT var in hook 995 +
   gnome-initial-setup.service (sed at build time or template); rename payload dir
   to a triplet-variable layout (apply-variant-payload.sh can rewrite symlink
   targets from a manifest, or ship `static/usr/lib/<triplet>` generated at build).
2. Replace the 7 payload ELFs with build-time deb extraction (gdm3, systemd,
   fprintd, gnome-keyring, UCD passwd) or per-arch payload dirs; xdg-fuse-broker
   via GOARCH.
3. build.sh: `--arch` flag → TARGET_TRIPLET (fix both kde functions), console=
   per-arch in both cmdline_extra literals, arch-aware model defaults.
4. Gadget: add arm64 platform; port seed size (7000M + edition) + defaults into
   gadget-arm64.yaml; add the three local snaps' arm64 platform entries.
5. Gate: rebuild amd64 thin image, boot under existing go-run-gnome, confirm
   nothing regressed.

Phase 2 — arm64 variant build:
6. Arm64 build env; `tools/build-variant.sh desktop` → core26-desktop_arm64.snap.
7. Build gadget arm64, snapd arm64, session/content/pipewire arm64; take
   ubuntu-desktop-init from store arm64.

Phase 3 — image:
8. arm64 model JSON + ci model; build.sh --desktop gnome --arch arm64 with all
   local snaps; ubuntu-image builds pc.img (arch from model).

Phase 4 — qemu verification (scaled gates, §5): serial console (ttyAMA0) +
VNC; seeded boot → run-mode → GDM/wizard → SSH → snap set sanity → session stretch.

## Top risks

1. **Emulation speed / build env** (biggest schedule risk): no arm64 hardware;
   every arm64 snap+base build and every boot verification runs under TCG —
   base build ~1-3h, first boot ~1h+, and qemu-user-static must be installed
   before any of it works. Mitigate with GH arm64 runners for builds and
   one-shot boot evidence rather than interactive QA.
2. **Thin-base payload on arm64**: the 7 payload ELFs + 10 content-snap symlinks
   + hook 995 were hand-carried from the fat base; on arm64 they must be
   re-extracted from arm64 debs (gdm3/systemd/fprintd/gnome-keyring/UCD passwd —
   PPA has arm64 builders, verified) and the gnome-desktop-runtime arm64 content
   snap must actually ship dri/gbm/mutter-18/glvnd/xkb paths the symlinks and
   hook target. A mismatch shows up as mutter "GPU not supported by EGL" /
   missing-loader failures at first GDM start.
3. **Gadget/seed fit + boot chain**: gadget-arm64.yaml is vanilla upstream — the
   1200M ubuntu-seed cannot hold the thin desktop seed set (pc-kernel arm64 alone
   is ~390MB); forgetting the size/defaults port produces an ubuntu-image failure
   or an unbootable ssh-locked image. UEFI+shim under AAVMF is the second-order
   boot risk (use AAVMF_CODE.secboot.fd + snakeoil keys if shim validation bites).
