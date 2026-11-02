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

# Duatic dev container build helpers: `cb` (colcon build) and `cc` (clean).
#
# Loaded the same way as 10-duatic-ros.sh, which must come first — these call
# duatic_source_ros_env to refresh the environment after a build or a clean.
[ -n "${_DUATIC_WORKFLOW_SOURCED:-}" ] && return 0
_DUATIC_WORKFLOW_SOURCED=1

# Remembers whether the last build used --symlink-install: mixing both styles in one build/
# tree yields a broken install/, so cb cleans on a switch. Lives in the workspace root, which
# dev_entrypoint.sh chowns to the host user for exactly this.
_DUATIC_BUILD_MODE_FILE="${ROS_WS:-/ros2_ws}/.colcon_build_mode"

cb() {
    cd "${ROS_WS:-/ros2_ws}" || return 1

    local last_mode=""
    local new_mode="normal"
    local symlink_flag=""
    local select_flag
    local mixin_flags="--mixin release ccache compile-commands"
    local status=0

    if [ -f "$_DUATIC_BUILD_MODE_FILE" ]; then
        last_mode=$(cat "$_DUATIC_BUILD_MODE_FILE")
    fi

    if [ "${1:-}" = "s" ]; then
        new_mode="symlink"
        symlink_flag="--symlink-install"
        shift
    fi

    case "${1:-}" in
        help | -h | --help)
            echo "cb            -> full build"
            echo "cb s          -> full build with symlink-install"
            echo "cb upto P1 .. -> build up to (deps of) package(s)"
            echo "cb s upto P1  -> same, but with symlink-install"
            echo "cb only P1 .. -> build only specified package(s)"
            echo "cb s only P1  -> same, but with symlink-install"
            echo "cb P1 ..      -> (legacy) same as 'cb only'"
            echo ""
            echo "Workspace remembers last build mode (normal vs symlink)."
            echo "If you switch, 'cc' is called to clean build/install/log."
            return 0
            ;;
    esac

    # An empty last_mode means nothing was ever built here — not a mode switch.
    if [ -n "$last_mode" ] && [ "$last_mode" != "$new_mode" ]; then
        echo "Build mode changed ($last_mode → $new_mode)"
        cc
    fi
    echo "$new_mode" >"$_DUATIC_BUILD_MODE_FILE"

    if [ $# -eq 0 ]; then
        colcon build $mixin_flags $symlink_flag
        status=$?
    else
        case "$1" in
            upto)
                shift
                if [ $# -eq 0 ]; then
                    echo "Usage: cb [s] upto <package...>"
                    return 2
                fi
                select_flag='--packages-up-to'
                ;;
            only)
                shift
                if [ $# -eq 0 ]; then
                    echo "Usage: cb [s] only <package...>"
                    return 2
                fi
                select_flag='--packages-select'
                ;;
            *)
                select_flag='--packages-select'
                ;;
        esac

        # Support simple wildcards (*)
        local regex
        local regex_patterns=()
        for wildcard_pattern in "$@"; do
            regex_patterns+=( "${wildcard_pattern//\*/.*}" )
        done
        regex="^($(IFS='|'; printf '%s\n' "${regex_patterns[*]}"))$"

        colcon build "${select_flag}-regex" $regex $mixin_flags $symlink_flag
        status=$?
    fi

    history -a

    if [ "$status" -ne 0 ]; then
        # Refresh the environment so a partially-built workspace is still usable.
        duatic_source_ros_env
        echo "Build failed (exit ${status})."
        return "$status"
    fi

    # Trigger a restart of clangd (via VSCode extension)
    #   so it reads the new compile_commands.json
    pkill clangd || true

    # Replace the shell so the freshly built install/ is picked up cleanly.
    exec bash
}

cc() {
    cd "${ROS_WS:-/ros2_ws}" || return 1
    # build/install/log are bind-mount points — the directories themselves cannot be removed
    # from inside the container, only their contents.
    rm -rf build/* install/* log/*

    unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH
    duatic_source_ros_env

    echo "Workspace ${ROS_WS:-/ros2_ws} cleaned."
}

return 0
