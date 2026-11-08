// Design note: why a broker+shim instead of granting fuse-support/CAP_SYS_ADMIN
// =============================================================================
//
// The confined xdg-document-portal snap needs to create a FUSE mount for its
// document store, but a genuinely confined process must never hold real
// CAP_SYS_ADMIN (granting it, even via a narrowly-scoped snapd interface,
// would let the process perform arbitrary privileged mounts and is
// unacceptable in this project's threat model). Historically the
// "fuse-support" snapd interface solved this for unconfined/classic use by
// granting the capability outright; that is not an option here.
//
// Instead, mount(2)/umount(2) are performed by this program (xdg-fuse-broker),
// a small, separately-confined, socket-activated root daemon. The confined
// portal process talks to it over a UNIX socket (/run/xdg-fuse-broker.sock)
// using SCM_RIGHTS to receive back a live, already-mounted /dev/fuse file
// descriptor; it never gains a capability itself, it just receives a
// filesystem it can serve. This is the same architecture flatpak's
// document portal uses for the equivalent problem -- see
// https://github.com/flatpak/xdg-desktop-portal/issues/695 for prior art and
// the upstream discussion of why a privileged helper is the standard answer
// here.
//
// Getting libfuse to actually talk to this broker instead of the normal
// setuid fusermount3 helper requires two things working together:
//
//  1. A fusermount3-replacing shim (ubuntu-desktop-session-snap's
//     fusermount3-shim) placed at the literal path /usr/bin/fusermount3
//     inside the snap's mount namespace via a snapcraft `layout:` bind-file
//     (libfuse's fuse_mount_sys() tries the absolute path first, only
//     falling back to a $PATH search on failure -- prepending to PATH alone
//     is not sufficient). The shim speaks this broker's wire protocol
//     instead of exec'ing a real, setuid fusermount3.
//  2. libfuse only invokes any fusermount3 fallback at all when its own
//     direct mount(2) attempt fails with errno EPERM specifically -- any
//     other errno (notably EACCES) causes it to give up immediately with no
//     fallback. AppArmor's mount mediation is default-deny, so a profile
//     with *no* mount rule at all for this path causes AppArmor itself to
//     deny with EACCES, never reaching the shim. The fix is a narrowly
//     scoped AppArmor mount-allow rule (present in the `fuse-device` snapd
//     interface, interfaces/builtin/fuse_device.go in
//     ubuntu-core-desktop-snapd) for exactly this one doc-dir path -- this
//     does not grant capability sys_admin, so the kernel's own capability
//     check still denies the mount, but now with EPERM, which is what
//     actually triggers the shim fallback. In other words: the AppArmor
//     rule's job is purely to select which failure mode libfuse sees, not to
//     grant any real access.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"strings"
	"syscall"
)

const (
	socketPathEnv = "XDG_FUSE_BROKER_SOCKET"
	defaultSocket = "/run/xdg-fuse-broker.sock"

	cmdMount   = 'M'
	cmdUnmount = 'U'

	statusOK    = '0'
	statusError = '1'

	maxSubpathLen = 4096
)

// allowedSubpaths is the allowlist of mount subpaths, relative to
// /run/user/<uid>/. The broker never mounts a client-supplied absolute path:
// the real path is always constructed server-side from the verified peer uid.
//
// "doc" (not "snap.ubuntu-desktop-session/doc") is deliberate: xdg-document-
// portal's XDG_RUNTIME_DIR is overridden back to the real, unprivatized
// /run/user/<uid> (see the xdg-document-portal app's `environment:` in
// ubuntu-desktop-session-snap's snapcraft.yaml) specifically so its FUSE
// mount lands at the plain, global path that snapd's own tooling (the
// desktop-launch check and the `desktop` interface's AppArmor bind-mount
// rule) hardcodes for every other snap to find the document portal.
var allowedSubpaths = map[string]bool{
	"doc": true,
}

// request is the wire format a client sends:
//
//	[0]      command byte ('M' mount, 'U' unmount)
//	[1:5]    requested uid (uint32, big endian)
//	[5:7]    subpath length (uint16, big endian)
//	[7:7+n]  subpath (relative to /run/user/<uid>/)
type request struct {
	cmd     byte
	uid     uint32
	subpath string
}

type broker struct {
	logger *slog.Logger
}

func (b *broker) handle(conn *net.UnixConn) {
	defer conn.Close()

	cred, err := peerCred(conn)
	if err != nil {
		b.logger.Error("failed to read peer credentials", "error", err)
		return
	}

	req, err := readRequest(conn)
	if err != nil {
		b.logger.Error("failed to read request",
			"peer_uid", cred.Uid, "peer_pid", cred.Pid, "error", err)
		return
	}

	log := b.logger.With(
		"peer_uid", cred.Uid, "peer_pid", cred.Pid,
		"cmd", string(req.cmd), "requested_uid", req.uid, "subpath", req.subpath)

	if err := validatePeer(cred, req.uid); err != nil {
		log.Warn("rejected request: peer credential mismatch", "error", err)
		writeError(conn, err)
		return
	}

	path, err := mountPathForUID(cred.Uid, req.subpath)
	if err != nil {
		log.Warn("rejected request: invalid subpath", "error", err)
		writeError(conn, err)
		return
	}

	switch req.cmd {
	case cmdMount:
		fd, err := b.mount(cred, path)
		if err != nil {
			log.Error("mount failed", "path", path, "error", err)
			writeError(conn, err)
			return
		}
		if err := sendFD(conn, fd); err != nil {
			log.Error("failed to send fuse fd", "path", path, "error", err)
			syscall.Close(fd)
			return
		}
		// The client now owns a duplicate of the fd; drop ours so the mount
		// is torn down cleanly when the client exits.
		syscall.Close(fd)
		log.Info("mounted fuse filesystem", "path", path)

	case cmdUnmount:
		if err := b.unmount(path); err != nil {
			log.Error("unmount failed", "path", path, "error", err)
			writeError(conn, err)
			return
		}
		writeOK(conn)
		log.Info("unmounted fuse filesystem", "path", path)

	default:
		log.Warn("rejected request: unknown command")
		writeError(conn, fmt.Errorf("unknown command %q", req.cmd))
	}
}

// mount performs the privileged mount(2) and returns the live /dev/fuse fd.
func (b *broker) mount(cred *syscall.Ucred, path string) (int, error) {
	// Clear any stale mount left behind by a previous crash (a SIGKILLed
	// xdg-document-portal leaves a zombie mount otherwise). This is expected
	// to fail when nothing is mounted, so the error is deliberately ignored.
	if err := syscall.Unmount(path, syscall.MNT_DETACH); err == nil {
		b.logger.Info("cleared stale mount", "path", path)
	}

	if err := os.MkdirAll(path, 0755); err != nil {
		return -1, fmt.Errorf("create mountpoint: %w", err)
	}

	fd, err := syscall.Open("/dev/fuse", syscall.O_RDWR, 0)
	if err != nil {
		return -1, fmt.Errorf("open /dev/fuse: %w", err)
	}

	data := fmt.Sprintf("fd=%d,rootmode=40000,user_id=%d,group_id=%d",
		fd, cred.Uid, cred.Gid)
	if err := syscall.Mount("xdg-document-portal", path, "fuse",
		syscall.MS_NOSUID|syscall.MS_NODEV, data); err != nil {
		syscall.Close(fd)
		return -1, fmt.Errorf("mount %s: %w", path, err)
	}
	return fd, nil
}

// unmount performs a real unmount, falling back to a lazy detach if the
// filesystem is still busy.
func (b *broker) unmount(path string) error {
	if err := syscall.Unmount(path, 0); err != nil {
		if err2 := syscall.Unmount(path, syscall.MNT_DETACH); err2 != nil {
			return fmt.Errorf("unmount %s: %w", path, err)
		}
	}
	return nil
}

// mountPathForUID constructs the canonical mount path for a uid. The subpath
// must be a clean relative path and present in the allowlist; the client can
// never influence the /run/user/<uid> prefix.
func mountPathForUID(uid uint32, subpath string) (string, error) {
	if !isCleanRelative(subpath) {
		return "", fmt.Errorf("subpath %q is not a clean relative path", subpath)
	}
	if !allowedSubpaths[subpath] {
		return "", fmt.Errorf("subpath %q is not allowed", subpath)
	}
	return fmt.Sprintf("/run/user/%d/%s", uid, subpath), nil
}

// validatePeer verifies that the connecting process's uid matches the uid the
// mount path is being constructed for.
func validatePeer(cred *syscall.Ucred, requestedUID uint32) error {
	if cred == nil {
		return errors.New("no peer credentials available")
	}
	if cred.Uid != requestedUID {
		return fmt.Errorf("peer uid %d does not match requested uid %d",
			cred.Uid, requestedUID)
	}
	return nil
}

func isCleanRelative(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "//") {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func peerCred(conn *net.UnixConn) (*syscall.Ucred, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return nil, err
	}
	var cred *syscall.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = syscall.GetsockoptUcred(int(fd),
			syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return nil, err
	}
	return cred, credErr
}

func readRequest(conn *net.UnixConn) (*request, error) {
	header := make([]byte, 7)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, err
	}
	req := &request{
		cmd: header[0],
		uid: binary.BigEndian.Uint32(header[1:5]),
	}
	n := int(binary.BigEndian.Uint16(header[5:7]))
	if n > maxSubpathLen {
		return nil, fmt.Errorf("subpath length %d exceeds maximum %d", n, maxSubpathLen)
	}
	if n > 0 {
		buf := make([]byte, n)
		if _, err := io.ReadFull(conn, buf); err != nil {
			return nil, err
		}
		req.subpath = string(buf)
	}
	return req, nil
}

func writeOK(conn *net.UnixConn) error {
	_, err := conn.Write([]byte{statusOK})
	return err
}

func writeError(conn *net.UnixConn, err error) {
	msg := []byte(err.Error())
	if len(msg) > maxSubpathLen {
		msg = msg[:maxSubpathLen]
	}
	conn.Write(append([]byte{statusError}, msg...))
}

// sendFD sends the status byte and the fuse fd in a single SCM_RIGHTS message.
func sendFD(conn *net.UnixConn, fd int) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var sendErr error
	if err := raw.Control(func(cfd uintptr) {
		sendErr = syscall.Sendmsg(int(cfd), []byte{statusOK},
			syscall.UnixRights(fd), nil, 0)
	}); err != nil {
		return err
	}
	return sendErr
}
