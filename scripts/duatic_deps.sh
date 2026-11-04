#!/bin/bash
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

# duatic-deps — install every dependency a workspace's src/ declares (rosdep keys, every
# Aptfile, every requirements.txt, at any depth), leniently, into the RUNNING container.
#
# The entry point for duatic-rosdep-install and duatic-install-extra-deps in a running
# container. Not persisted across container recreation: re-run it after recreating the
# container, or whenever src/ gains a new dependency.
#
# Usage: duatic-deps [--if-changed | --list | --gate] [src_dir]   (default: $ROS_WS/src, e.g. /ros2_ws/src)
#   --if-changed  skip the install when every manifest in src_dir is already in /etc/duatic/deps.stamp
#   --list        print the checksum and path of every manifest in src_dir and exit
#   --gate        fail, listing them, when the image holds unresolved dependencies: the strict
#                 gate the robot image and CI hold
#
# The stamp lists every manifest already installed. An image that installs a workspace's
# dependencies at build time writes it with --list, and each complete install adds to it, so a
# container whose src/ holds no new or changed manifest skips.

STAMP=/etc/duatic/deps.stamp
mode=install
case "${1:-}" in
    --if-changed | --list | --gate)
        mode="${1#--}"
        shift
        ;;
esac
SRC="${1:-${ROS_WS:-/ros2_ws}/src}"

# Print every unresolved dependency the lenient installers recorded; false when there is none.
unresolved() {
    local m found=1
    for m in /etc/duatic/unresolved-rosdep.txt /etc/duatic/unresolved-deps.txt; do
        if [[ -s "$m" ]]; then
            echo "${m}:"
            cat "$m"
            found=0
        fi
    done
    return "$found"
}

if [[ "$mode" == gate ]]; then
    if unresolved >&2; then
        echo "duatic-deps: dependencies are unresolved; robots must not ship incomplete." >&2
        exit 1
    fi
    exit 0
fi

# Checksum and path of every package.xml, Aptfile and requirements.txt the installers read.
manifest_list() {
    (cd "$SRC" && find . \( -name build -o -name install -o -name log -o -name .venv -o -name node_modules \) -prune \
        -o -type f \( -name package.xml -o -name Aptfile -o -name requirements.txt \) -print0 |
        xargs -0 -r sha256sum | LC_ALL=C sort)
}

manifests=$(manifest_list)
if [[ "$mode" == list ]]; then
    echo "$manifests"
    exit 0
fi
if [[ "$mode" == if-changed && -z "$(LC_ALL=C comm -23 <(echo "$manifests") <(LC_ALL=C sort "$STAMP" 2>/dev/null || true))" ]]; then
    echo "duatic-deps: every manifest in $SRC is already installed, nothing to do."
    exit 0
fi

: "${ROS_DISTRO:?ROS_DISTRO not set}"

sudo apt-get update
sudo duatic-rosdep-install "$SRC" "$ROS_DISTRO"
sudo duatic-install-extra-deps "$SRC" --lenient
# No apt-get clean: a container may mount apt lists and downloaded packages as a cache.

# Only a complete install is recorded, so --if-changed retries anything that failed.
if unresolved >/dev/null; then
    echo "duatic-deps: some dependencies are unresolved (see duatic-doctor); not updating $STAMP." >&2
    exit 0
fi
{
    [[ -z "$manifests" ]] || echo "$manifests"
    cat "$STAMP" 2>/dev/null || true
} | LC_ALL=C sort -u | sudo tee "$STAMP.new" >/dev/null
sudo mv "$STAMP.new" "$STAMP"
