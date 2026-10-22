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
# The entry point for duatic-rosdep-install and duatic-install-product-deps in a running
# container. Not persisted across container recreation: re-run it after recreating the
# container, or whenever src/ gains a new dependency.
#
# Usage: duatic-deps [src_dir]   (default: $ROS_WS/src, e.g. /ros2_ws/src)

SRC="${1:-${ROS_WS:-/ros2_ws}/src}"
: "${ROS_DISTRO:?ROS_DISTRO not set}"

sudo apt-get update
sudo duatic-rosdep-install "$SRC" "$ROS_DISTRO"
sudo duatic-install-product-deps "$SRC" --lenient
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
