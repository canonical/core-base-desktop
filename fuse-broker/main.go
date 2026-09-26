// Command xdg-fuse-broker is a privileged, socket-activated FUSE mount broker.
//
// It runs as root in the host mount namespace. Confined clients (the
// xdg-document-portal snap app) cannot call mount(2) themselves, so they ask
// this broker to perform the mount and hand back the live /dev/fuse fd over a
// UNIX domain socket using SCM_RIGHTS. The client then speaks the FUSE
// protocol directly; the broker never touches the FUSE traffic.
package main

import (
	"log/slog"
	"net"
	"os"
	"strconv"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	l, err := listenSocket()
	if err != nil {
		slog.Error("failed to acquire listening socket", "error", err)
		os.Exit(1)
	}
	slog.Info("xdg-fuse-broker listening", "addr", l.Addr().String())

	b := &broker{logger: slog.Default()}
	for {
		conn, err := l.Accept()
		if err != nil {
			slog.Error("accept failed", "error", err)
			continue
		}
		uc, ok := conn.(*net.UnixConn)
		if !ok {
			slog.Error("accepted non-unix connection")
			conn.Close()
			continue
		}
		go b.handle(uc)
	}
}

// listenSocket returns the systemd socket-activation listener when running
// under systemd, otherwise falls back to creating the socket itself. The
// fallback exists so the broker can be exercised manually outside systemd.
func listenSocket() (net.Listener, error) {
	if os.Getenv("LISTEN_PID") == strconv.Itoa(os.Getpid()) {
		if n, err := strconv.Atoi(os.Getenv("LISTEN_FDS")); err == nil && n >= 1 {
			f := os.NewFile(3, "systemd-listener")
			l, err := net.FileListener(f)
			f.Close()
			return l, err
		}
	}

	path := os.Getenv(socketPathEnv)
	if path == "" {
		path = defaultSocket
	}
	os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0666); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}
