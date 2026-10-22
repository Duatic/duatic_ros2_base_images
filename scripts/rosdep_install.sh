#!/usr/bin/env bash
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

set -euo pipefail

# Resolve rosdep dependencies for a workspace, degrading gracefully.
#
# Installs every dependency rosdep *can* resolve, records the keys it *cannot*
# (no rosdep rule for this distro) to /etc/duatic/unresolved-rosdep.txt, and prints
# a prominent warning. Completeness is auto-detected: an EMPTY manifest == complete.
#
#   rosdep_install.sh <src_path> <ros_distro> [--strict]
#
#   --strict   exit non-zero if anything is unresolved or an install fails. Used by
#              robot/runtime builds — the quality gate. Robots never ship incomplete.
#   (lenient)  always exit 0. Used by dev images: developers must never be blocked.

SRC="${1:-src}"
ROS_DISTRO_ARG="${2:-${ROS_DISTRO:-}}"
STRICT=0
[[ "${3:-}" == "--strict" ]] && STRICT=1

if [[ -z "$ROS_DISTRO_ARG" ]]; then
    echo "rosdep_install: ROS distro not given (arg 2 or \$ROS_DISTRO)" >&2
    exit 2
fi

MANIFEST=/etc/duatic/unresolved-rosdep.txt
mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"

ERR_LOG="$(mktemp)"
trap 'rm -f "$ERR_LOG"' EXIT

rosdep update

# Install everything resolvable. -r continues past unresolvable keys; we capture
# stderr to discover which keys had no rosdep rule for this distro.
set +e
rosdep install -r --from-paths "$SRC" --ignore-src --rosdistro "$ROS_DISTRO_ARG" -y 2>"$ERR_LOG"
rc=$?
set -e
cat "$ERR_LOG" >&2   # surface rosdep's stderr in the build log

# Keys with no rosdep rule for this distro — the ones a developer must fix.
mapfile -t unresolved < <(
    grep -oE 'Cannot locate rosdep definition for \[[^]]+\]' "$ERR_LOG" \
        | sed -E 's/.*\[([^]]+)\].*/\1/' | sort -u
)

if [[ ${#unresolved[@]} -gt 0 ]]; then
    printf '%s\n' "${unresolved[@]}" > "$MANIFEST"
    echo ""
    echo "=================================================================="
    echo "WARNING: unresolved rosdep keys for '${ROS_DISTRO_ARG}':"
    printf '  - %s\n' "${unresolved[@]}"
    echo "recorded in ${MANIFEST}"
    echo "=================================================================="
    echo ""
fi

if [[ "$STRICT" == "1" ]]; then
    if [[ ${#unresolved[@]} -gt 0 || $rc -ne 0 ]]; then
        echo "rosdep_install: strict mode — dependencies incomplete (rc=${rc}, unresolved=${#unresolved[@]})." >&2
        exit 1
    fi
fi

exit 0
