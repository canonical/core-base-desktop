UCD PPA patches, applied at build time
======================================

These are the Ubuntu Core Desktop specific patches from the 22.04-era
desktop-snappers/core-desktop PPA (forward-ported to resolute; see
~/git/ucd-ppa and ~/notes/ucd-ppa-status.txt), committed here as plain
patches instead of binary packages.

The `ucd-ppa-overlays` snapcraft part fetches the matching resolute
source packages with `apt-get source`, applies these patches, builds the
debs, and stages the resulting code paths under overlay/ -- the hooks
part Makefile then copies them over the assembled rootfs (see the
"Overlay the UCD PPA builds" step in the Makefile).

Why the first-boot wizard needs them:

- shadow (1017): `chpasswd` must work against /var/lib/extrausers, or
  the wizard's password step would target the read-only /etc/shadow.
  NOTE: as of 2026-10 the resolute archive's shadow has ABSORBED the
  rest of the extrausers series (1010 usermod/commonio, 1011, 1012
  chfn, 1013 deluser, 1014 delgroup, 1016 gpasswd are all in the
  archive's own debian/patches/series), so usermod is already
  extrausers-aware and only 1017 remains ours. ~/git/ucd-ppa still
  carries the older copies of all seven if a re-port is ever needed.

- adduser: its extrausers mode called `usermod --extrausers` -- a flag
  that has never existed -- so every group add failed. The patch drops
  that branch; plain usermod works because the archive's shadow build
  is extrausers-aware. (Still needed: the archive adduser has the bug.)

The remaining PPA packages are NOT needed: provd (stock resolute is
byte-identical to the PPA build), gnome-shell and gnome-session
(unrelated to extrausers; not used by this image's design).

If a future archive update breaks a patch's application, the build
fails loudly at the `patch` step -- re-port the affected patch the same
way the PPA port did (~/notes/ucd-ppa-status.txt documents the method).
