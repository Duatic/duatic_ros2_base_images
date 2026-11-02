# shellcheck shell=bash
# Copyright 2026 Duatic AG
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that
# the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and
#    the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and
#    the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or
#    promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

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
