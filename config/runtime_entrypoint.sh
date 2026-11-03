#!/bin/bash

# Defaults only — an operator's `docker run -e ROS_DOMAIN_ID=...` (or any of these three)
# must win. A prior unconditional `export ROS_DOMAIN_ID=42` here clobbered that override
# before this same fallback ever ran, making it dead code; don't reintroduce that.
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
export ROS_AUTOMATIC_DISCOVERY_RANGE="${ROS_AUTOMATIC_DISCOVERY_RANGE:-LOCALHOST}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

# Source ROS distro environment
if [ -f "/opt/ros/$ROS_DISTRO/setup.bash" ]; then
  # shellcheck source=/dev/null.
  source "/opt/ros/$ROS_DISTRO/setup.bash"
fi

# Source the prebuilt product workspace
if [ -f "${ROS_WS}/install/setup.bash" ]; then
  # shellcheck source=/dev/null.
  source "${ROS_WS}/install/setup.bash"
fi

exec "$@"
