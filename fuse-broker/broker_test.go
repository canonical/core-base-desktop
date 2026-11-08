package main

import (
	"syscall"
	"testing"
)

func TestMountPathForUID(t *testing.T) {
	tests := []struct {
		name    string
		uid     uint32
		subpath string
		want    string
		wantErr bool
	}{
		{
			name:    "document portal path",
			uid:     1000,
			subpath: "doc",
			want:    "/run/user/1000/doc",
		},
		{
			name:    "other uid",
			uid:     42,
			subpath: "doc",
			want:    "/run/user/42/doc",
		},
		{
			name:    "absolute path rejected",
			uid:     1000,
			subpath: "/etc/passwd",
			wantErr: true,
		},
		{
			name:    "traversal rejected",
			uid:     1000,
			subpath: "doc/../../etc",
			wantErr: true,
		},
		{
			name:    "unknown subpath rejected",
			uid:     1000,
			subpath: "some/other/path",
			wantErr: true,
		},
		{
			name:    "empty subpath rejected",
			uid:     1000,
			subpath: "",
			wantErr: true,
		},
		{
			name:    "double slash rejected",
			uid:     1000,
			subpath: "snap.ubuntu-desktop-session//doc",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := mountPathForUID(tt.uid, tt.subpath)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("mountPathForUID(%d, %q) = %q, want error",
						tt.uid, tt.subpath, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("mountPathForUID(%d, %q) unexpected error: %v",
					tt.uid, tt.subpath, err)
			}
			if got != tt.want {
				t.Fatalf("mountPathForUID(%d, %q) = %q, want %q",
					tt.uid, tt.subpath, got, tt.want)
			}
		})
	}
}

func TestValidatePeer(t *testing.T) {
	tests := []struct {
		name         string
		cred         *syscall.Ucred
		requestedUID uint32
		wantErr      bool
	}{
		{
			name:         "matching uid",
			cred:         &syscall.Ucred{Pid: 123, Uid: 1000, Gid: 1000},
			requestedUID: 1000,
		},
		{
			name:         "mismatched uid",
			cred:         &syscall.Ucred{Pid: 123, Uid: 1000, Gid: 1000},
			requestedUID: 0,
			wantErr:      true,
		},
		{
			name:         "root requesting user uid",
			cred:         &syscall.Ucred{Pid: 1, Uid: 0, Gid: 0},
			requestedUID: 1000,
			wantErr:      true,
		},
		{
			name:         "nil credentials",
			cred:         nil,
			requestedUID: 1000,
			wantErr:      true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePeer(tt.cred, tt.requestedUID)
			if tt.wantErr && err == nil {
				t.Fatalf("validatePeer(%+v, %d) = nil, want error",
					tt.cred, tt.requestedUID)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("validatePeer(%+v, %d) unexpected error: %v",
					tt.cred, tt.requestedUID, err)
			}
		})
	}
}

func TestIsCleanRelative(t *testing.T) {
	clean := []string{"a", "a/b", "snap.ubuntu-desktop-session/doc"}
	dirty := []string{"", "/a", "a/", "a//b", "a/../b", "./a", "a/./b", ".."}
	for _, p := range clean {
		if !isCleanRelative(p) {
			t.Errorf("isCleanRelative(%q) = false, want true", p)
		}
	}
	for _, p := range dirty {
		if isCleanRelative(p) {
			t.Errorf("isCleanRelative(%q) = true, want false", p)
		}
	}
}
