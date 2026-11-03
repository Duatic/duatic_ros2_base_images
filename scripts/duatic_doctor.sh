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

# duatic-doctor — one-command diagnosis for the dev container: capabilities, groups,
# device access, the prebuilt underlay, DDS config, and any dependency that failed to
# resolve when this image was built. Point developers here first for "gamepad doesn't
# work", "EtherCAT says no socket connection", or "why is my container missing X" — this is
# the single place all of that gets checked instead of re-deriving it from the README.
#
# Deliberately does not use `set -e`: a diagnostic that stops at the first failed check is
# useless. Every check is self-contained and always reports something.

_ok() { printf '  [ OK ] %s\n' "$1"; }
_warn() { printf '  [WARN] %s\n' "$1"; }
_bad() { printf '  [FAIL] %s\n' "$1"; }
_info() { printf '  %s\n' "$1"; }

echo "=== Image ==="
_info "image:       ${DUATIC_IMAGE_NAME:-<unset>}"
_info "ros distro:  ${ROS_DISTRO:-<unset>}"
_info "image version: ${DUATIC_IMAGE_VERSION:-<unset>}"
if [ -f /opt/duatic/ws/install/setup.bash ]; then
    _ok "prebuilt underlay present (/opt/duatic/ws/install)"
else
    _info "no prebuilt underlay (/opt/duatic/ws/install absent)"
fi

echo ""
echo "=== Identity ==="
_info "$(id)"
[ "$(id -u)" = "0" ] && _warn "running as root — expected only for a deliberate root shell, not the normal dev flow"

echo ""
echo "=== EtherCAT (CAP_NET_RAW) ==="
if capsh --has-a=cap_net_raw 2>/dev/null; then
    _ok "held by this shell — EtherCAT should work"
elif (( (0x$(awk '/^CapBnd:/ {print $2}' /proc/self/status) >> 13) & 1 )); then  # CAP_NET_RAW in the bounding set
    _bad "available but NOT held by this shell — re-enter via duatic-exec/duatic-shell; a raw 'docker exec -u' bypasses it"
else
    _bad "not in the bounding set — EtherCAT will need root. Container needs --cap-add=SYS_NICE and no --cap-drop that removes NET_RAW"
fi

echo ""
echo "=== Gamepad / input devices ==="
if [ -d /run/udev/data ] && [ -n "$(ls -A /run/udev/data 2>/dev/null)" ]; then
    _ok "/run/udev is mounted and populated — libudev enumeration (SDL2/joy) should work"
else
    _bad "/run/udev missing or empty — SDL2-based nodes (joy's game_controller_node) may fail to enumerate controllers even with correct device permissions. Mount it: -v /run/udev:/run/udev:ro"
fi
if [ -e /dev/input ]; then
    _n=0
    # id -G prints one space-separated line, not one GID per line — mapfile would put the
    # whole line in a single array element and every membership check below would silently
    # never match.
    read -ra _my_gids <<<"$(id -G)"
    for f in /dev/input/js* /dev/input/event*; do
        [ -e "$f" ] || continue
        _n=$((_n + 1))
        gid=$(stat -c '%g' "$f")
        _member=false
        for g in "${_my_gids[@]}"; do
            [ "$g" = "$gid" ] && _member=true && break
        done
        if $_member; then
            _ok "$f (gid $gid) — readable"
        else
            _bad "$f (gid $gid) — not in this shell's groups; open a new shell (duatic-exec re-syncs groups on every entry) or check DUATIC_EXTRA_GIDS"
        fi
    done
    [ "$_n" = 0 ] && _warn "no /dev/input/{js*,event*} nodes visible — is /dev/input bind-mounted, and is a device connected?"
else
    _bad "/dev/input not present in this container — bind-mount it: -v /dev/input:/dev/input"
fi

echo ""
echo "=== ROS / DDS ==="
_info "RMW_IMPLEMENTATION: ${RMW_IMPLEMENTATION:-<unset>}"
_info "CYCLONEDDS_URI:     ${CYCLONEDDS_URI:-<unset>}"
_info "CYCLONEDDS_IFACE:   ${CYCLONEDDS_IFACE:-lo (default)}"
_info "ROS_DOMAIN_ID:      ${ROS_DOMAIN_ID:-<unset>}"

echo ""
echo "=== Dependency resolution (recorded when this image was built) ==="
for f in /etc/duatic/unresolved-rosdep.txt /etc/duatic/unresolved-deps.txt; do
    if [ -s "$f" ]; then
        _bad "$f is non-empty:"
        sed 's/^/         - /' "$f"
    else
        _ok "$f empty"
    fi
done

if [ -f /etc/duatic/sources.lock.repos ]; then
    echo ""
    echo "=== Source lock ==="
    # No `|| echo` fallback: grep -c exits 1 on zero matches while still printing "0".
    _n=$(grep -cE '^  [A-Za-z0-9_.-]+:$' /etc/duatic/sources.lock.repos 2>/dev/null)
    _ok "/etc/duatic/sources.lock.repos present (${_n} repos pinned)"
fi
