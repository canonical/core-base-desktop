# xdg-fuse-broker source

Privileged FUSE mount broker for the confined `xdg-document-portal`
(see the design note at the top of `broker.go` for why a broker+shim
exists instead of granting the portal `CAP_SYS_ADMIN`).

Provenance: copied verbatim from core-base-desktop's `fuse-broker/`
directory (the fat base built this same source into the same
`/usr/bin/xdg-fuse-broker` payload path; the thin variant keeps the
source in-tree and builds it at snap build time on the build
architecture — there is no vendored ELF).

Built by the `fuse-broker` part of snapcraft.yaml:

    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"

which is a reproducible build for a given Go toolchain: on amd64 this
rebuilds the previously-vendored binary byte-identically (go 1.26.8,
md5 716778a37b5338b72c27e10b5f9893a9).
