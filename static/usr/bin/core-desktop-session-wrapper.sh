#!/bin/bash

# This script runs outside of snap confinement as a wrapper around the
# confined desktop session.
snap_cmd="$1"
snap_name="$(echo "$snap_cmd" | cut -d . -f 1)"

session_type=$2

# Set up PATH and XDG_DATA_DIRS to allow calling snaps
if [ -f /snap/snapd/current/etc/profile.d/apps-bin-path.sh ]; then
    source /snap/snapd/current/etc/profile.d/apps-bin-path.sh
fi

export XDG_CURRENT_DESKTOP=$session_type
export GSETTINGS_BACKEND=keyfile

dbus-update-activation-environment --systemd --all

# Don't set this in our own environment, since it will make
# the session believe it is running in X mode
dbus-update-activation-environment --systemd DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XAUTHORITY=$XDG_RUNTIME_DIR/.Xauthority

# Set up a background task to wait for gnome-session to create its
# Xauthority file, and copy it to a location snaps will be able to
# see.
function fixup_xauthority() {
    while :; do
        sleep 1s
        if [ "$session_type" = "KDE" ]; then
            xauth_file="$(ls -1t $XDG_RUNTIME_DIR/snap.$snap_name/xauth_* | head -n1)"
        else
            xauth_file="$(ls -1t $XDG_RUNTIME_DIR/snap.$snap_name/.mutter-Xwaylandauth.* | head -n1)"
        fi
        if [ -f "$xauth_file" ]; then
            cp "$xauth_file" $XDG_RUNTIME_DIR/.Xauthority
            return
        fi
    done
}
if [ "$session_type" = "KDE" ]; then
    # Temporary workaround until we have a better way to expose our services and targets
    # 1. Expose our targets, services and overloads
    rm -rf $XDG_RUNTIME_DIR/systemd/user.control
    mkdir -p $XDG_RUNTIME_DIR/systemd
    ln -sf /snap/plasma-core24-desktop/current/usr/lib/systemd/user $XDG_RUNTIME_DIR/systemd/user.control
    # 2. Reload the daemon so that it picks up our changes
    systemctl --user daemon-reload
    # 3. Stop anything now masked which might have been already started
    masked_units=`systemctl --user show --property=Id --value --state=masked`
    for unit in $masked_units ; do
      systemctl --user stop $unit
    done
    # 4. Stop the xdg-desktop-portal in case it was started before the override was set
    systemctl --user stop xdg-desktop-portal
fi

fixup_xauthority &

# Symlink the Wayland socket from the snap's private directory
ln -sf "snap.$snap_name/wayland-0" $XDG_RUNTIME_DIR/wayland-0
# Symlink sockets for pipewire and pipewire-pulse
ln -sf "snap.pipewire/pipewire-0" $XDG_RUNTIME_DIR/pipewire-0
mkdir -p $XDG_RUNTIME_DIR/pulse
ln -sf "../snap.pipewire/pulse/native" $XDG_RUNTIME_DIR/pulse/native

exec "/snap/bin/$snap_cmd"
