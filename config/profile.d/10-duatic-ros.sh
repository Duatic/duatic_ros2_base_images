# shellcheck shell=bash
# Duatic dev container shell environment — the ROS chain and the global pip venv.
#
# Installed to /etc/profile.d/ (read by login shells) AND sourced from /etc/bash.bashrc
# (read by interactive non-login shells, e.g. `docker exec -it <container> bash`). A login shell reaches it both ways, hence the guard
# below. The guard is deliberately NOT exported: `cb` ends with `exec bash`, and that fresh
# process must source this again.
[ -n "${_DUATIC_ROS_ENV_SOURCED:-}" ] && return 0
_DUATIC_ROS_ENV_SOURCED=1

# duatic_source_ros_env — source the full overlay chain, last one wins:
#   /opt/ros/$ROS_DISTRO       the distro itself
#   /opt/duatic/ws/install     optional prebuilt underlay, added by images built on top of this one
#   $ROS_WS/install            the developer's own workspace, usually bind-mounted
#                              — sourced last so it always wins
# Kept as a function because cb/cc re-invoke it to refresh the environment after a build or
# a clean (see 20-duatic-workflow.sh).
# shellcheck source=/dev/null
duatic_source_ros_env() {
    [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ] && source "/opt/ros/${ROS_DISTRO}/setup.bash"
    [ -f /opt/duatic/ws/install/setup.bash ] && source /opt/duatic/ws/install/setup.bash
    [ -f "${ROS_WS:-/ros2_ws}/install/setup.bash" ] && source "${ROS_WS:-/ros2_ws}/install/setup.bash"
    return 0
}

duatic_source_ros_env

# Re-assert the global venv on PATH. The image ENV already covers `docker exec`, the
# entrypoint and setpriv; `su -` / `login` rebuild PATH from /etc/login.defs (ENV_PATH /
# ENV_SUPATH) and would otherwise leave VIRTUAL_ENV set with the venv off PATH.
case ":$PATH:" in
    *:/opt/duatic/venv/bin:*) ;;
    *) PATH="/opt/duatic/venv/bin:$PATH" ;;
esac

# colcon tab-completion. Best effort — not packaged on every distro.
[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ] &&
    source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash

return 0
