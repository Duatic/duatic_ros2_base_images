#!/bin/bash
set -e

# Entrypoint of the dev image. Remaps the container user to the
# host UID/GID so bind-mounted files keep host ownership, then hands off to duatic-exec,
# which syncs device-owning groups and drops root via setpriv, giving the process ambient
# CAP_NET_RAW so EtherCAT works without being root. duatic-exec is also how every later
# `docker exec` (and duatic-shell, the VSCode/Remote-SSH path) enters this container — this
# is the SAME call, just made once here for PID 1 instead of per-shell.

HOST_USER="${HOST_USER:-developer}"
HOST_GID="${HOST_GID:-${HOST_UID:-}}"

# Enable multicast on loopback if DDS is configured for lo
if [ "${CYCLONEDDS_IFACE:-lo}" = "lo" ]; then
    ifconfig lo multicast 2>/dev/null || true
    route add -net 224.0.0.0 netmask 240.0.0.0 dev lo 2>/dev/null || true
fi

# Only attempt user modification if we are actually running as root inside the container
if [ "$(id -u)" = "0" ]; then
    if [ -n "${HOST_UID:-}" ] && [ "$HOST_UID" != "0" ]; then

        # Only create/modify if the user doesn't perfectly exist yet
        if ! id "$HOST_USER" >/dev/null 2>&1 || [ "$(id -u "$HOST_USER")" != "$HOST_UID" ]; then

            # Free up the UID/GID if taken
            if getent passwd "$HOST_UID" > /dev/null 2>&1; then
                existing_user=$(getent passwd "$HOST_UID" | cut -d: -f1)
                usermod -u 9999 "$existing_user" 2>/dev/null || true
            fi

            # Free up the GID if already taken — move the conflicting group to GID 9999
            if getent group "$HOST_GID" > /dev/null 2>&1; then
                _conflict_group=$(getent group "$HOST_GID" | cut -d: -f1)
                if [[ "$_conflict_group" != "$HOST_USER" ]]; then
                    groupmod -g 9999 "$_conflict_group" 2>/dev/null || true
                fi
            fi

            # Create group and user. Login shell is duatic-shell, not /bin/bash directly:
            # that is what gives a VSCode devcontainer terminal / Remote-SSH / `su -` the
            # same ambient CAP_NET_RAW this entrypoint is about to hand PID 1 (see its
            # header comment for why a fresh exec session can't just inherit it).
            getent group "$HOST_USER" > /dev/null 2>&1 || groupadd -g "$HOST_GID" "$HOST_USER"
            id "$HOST_USER" >/dev/null 2>&1 || useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /usr/local/bin/duatic-shell "$HOST_USER"

            echo "$HOST_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$HOST_USER"
            chmod 0440 "/etc/sudoers.d/$HOST_USER"
        fi

        export HOME="/home/$HOST_USER"

        # Give the user ownership of the workspace root so they can write
        # files like .colcon_build_mode (bind-mounted subdirs are unaffected).
        chown "${HOST_UID}:${HOST_GID}" /ros2_ws 2>/dev/null || true

        # Convenience shortcut to the robot config directory
        install -d -o "$HOST_UID" -g "$HOST_GID" "/home/$HOST_USER/.config/duatic" 2>/dev/null || true
        ln -sfn "/home/$HOST_USER/.config/duatic" "${ROS_WS:-/ros2_ws}/robot_config" 2>/dev/null || true
        chown -h "${HOST_UID}:${HOST_GID}" "${ROS_WS:-/ros2_ws}/robot_config" 2>/dev/null || true

        # duatic-exec syncs device-owning groups and setpriv-drops to HOST_UID/HOST_GID with
        # ambient CAP_NET_RAW — the exact same call a later `docker exec duatic-exec` or
        # duatic-shell makes, just made once here for PID 1.
        exec duatic-exec "$@"
    else
        # Running as root, but no HOST_UID provided. Just execute.
        exec "$@"
    fi
else
    # We are already NOT root (e.g. Podman with --userns=keep-id)
    # Nothing to drop, so just execute the command directly. Note this path cannot grant
    # CAP_NET_RAW either — inside a rootless user namespace it would not authorise AF_PACKET
    # on a host-netns interface anyway, so EtherCAT is Docker-only.
    exec "$@"
fi
