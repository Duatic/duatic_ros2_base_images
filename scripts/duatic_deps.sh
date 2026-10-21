#!/bin/bash
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
