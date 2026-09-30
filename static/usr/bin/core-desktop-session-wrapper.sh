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

runtime_dir="/run/user/$(id -u)"
if ! manager_environment="$(XDG_RUNTIME_DIR="$runtime_dir" systemctl --user show-environment)"; then
    echo "cannot inspect the user systemd environment" >&2
    exit 1
fi

snap_environment_vars=()
add_snap_environment_var() {
    local name="$1"
    local existing

    for existing in "${snap_environment_vars[@]}"; do
        if [ "$existing" = "$name" ]; then
            return
        fi
    done
    snap_environment_vars+=("$name")
}

stale_environment_vars=()
add_stale_environment_var() {
    local name="$1"
    local existing

    for existing in "${stale_environment_vars[@]}"; do
        if [ "$existing" = "$name" ]; then
            return
        fi
    done
    stale_environment_vars+=("$name")
}

for name in \
    DISPLAY XAUTHORITY WAYLAND_DISPLAY WAYLAND_SOCKET \
    GNOME_SHELL_SESSION_MODE GNOME_SETUP_DISPLAY; do
    add_stale_environment_var "$name"
done

while IFS='=' read -r name _; do
    case "$name" in
        SNAP|SNAP_*) add_snap_environment_var "$name" ;;
        LC_*) add_stale_environment_var "$name" ;;
    esac
done <<< "$manager_environment"

while IFS= read -r name; do
    case "$name" in
        SNAP|SNAP_*) add_snap_environment_var "$name" ;;
        LC_*) add_stale_environment_var "$name" ;;
    esac
done < <(compgen -e)

snap_environment=()
for name in "${snap_environment_vars[@]}"; do
    snap_environment+=("$name=")
done

activation_environment=(
    "DISPLAY=:0"
    "WAYLAND_DISPLAY=wayland-0"
    "XDG_RUNTIME_DIR=$runtime_dir"
    "XAUTHORITY=$runtime_dir/.Xauthority"
    "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
    "GSETTINGS_BACKEND=$GSETTINGS_BACKEND"
    "PATH=$PATH"
)
for name in "${stale_environment_vars[@]}"; do
    if [[ "$name" == LC_* ]] && value="$(printenv "$name" 2>/dev/null)"; then
        activation_environment+=("$name=$value")
    fi
done
for name in \
    DBUS_SESSION_BUS_ADDRESS HOME USER LOGNAME SHELL LANG LANGUAGE XDG_DATA_DIRS \
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_SESSION_CLASS XDG_SEAT XDG_VTNR \
    XDG_MENU_PREFIX XDG_CONFIG_HOME XDG_CONFIG_DIRS XDG_DATA_HOME \
    XDG_CACHE_HOME XDG_STATE_HOME XCURSOR_THEME XCURSOR_SIZE \
    GNOME_SETUP_DISPLAY GTK_IM_MODULE QT_IM_MODULE QT_IM_MODULES \
    XMODIFIERS PULSE_SERVER; do
    if value="$(printenv "$name" 2>/dev/null)"; then
        activation_environment+=("$name=$value")
    fi
done

stale_activation_environment=()
for name in "${stale_environment_vars[@]}"; do
    stale_activation_environment+=("$name=")
done
if ! XDG_RUNTIME_DIR="$runtime_dir" dbus-update-activation-environment \
    "${stale_activation_environment[@]}"; then
    echo "cannot clear stale D-Bus activation environment values" >&2
    exit 1
fi
if ! XDG_RUNTIME_DIR="$runtime_dir" systemctl --user unset-environment \
    "${stale_environment_vars[@]}"; then
    echo "cannot clear stale user systemd environment values" >&2
    exit 1
fi

if ! XDG_RUNTIME_DIR="$runtime_dir" dbus-update-activation-environment --systemd \
    "${snap_environment[@]}" "${activation_environment[@]}"; then
    echo "cannot update the D-Bus activation environment" >&2
    exit 1
fi

if [ "${#snap_environment_vars[@]}" -gt 0 ] &&
    ! XDG_RUNTIME_DIR="$runtime_dir" systemctl --user unset-environment "${snap_environment_vars[@]}"; then
    echo "cannot clear snap variables from the user systemd environment" >&2
    exit 1
fi

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
if [ "$session_type" = "KDE" ] || [ "$session_type" = "ubuntu:GNOME" ]; then
    # Temporary workaround until we have a better way to expose our services and targets
    # Expose the selected content snap's user units to the host user manager.
    if [ "$session_type" = "KDE" ]; then
        user_unit_source=/snap/plasma-core26-desktop/current/usr/lib/systemd/user
    else
        user_unit_source=/snap/gnome-desktop-content/current/usr/lib/systemd/user
    fi
    if [ ! -d "$user_unit_source" ]; then
        echo "missing desktop content user units: $user_unit_source" >&2
        exit 1
    fi
    rm -rf "$XDG_RUNTIME_DIR/systemd/user.control"
    mkdir -p "$XDG_RUNTIME_DIR/systemd"
    ln -sf "$user_unit_source" "$XDG_RUNTIME_DIR/systemd/user.control"
    systemctl --user daemon-reload
    masked_units=$(systemctl --user show --property=Id --value --state=masked)
    for unit in $masked_units; do
        systemctl --user stop "$unit"
    done
    systemctl --user stop xdg-desktop-portal
fi

fixup_xauthority &

# Symlink the Wayland socket from the snap's private directory
ln -sf "snap.$snap_name/wayland-0" $XDG_RUNTIME_DIR/wayland-0
# Symlink sockets for pipewire and pipewire-pulse
ln -sf "snap.gnome-desktop-content/pipewire-0" $XDG_RUNTIME_DIR/pipewire-0
ln -sf "snap.pipewire/pulse" $XDG_RUNTIME_DIR/pulse

exec "/snap/bin/$snap_cmd"
