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

# Install a workspace's declared extra dependencies: Aptfile (apt) + requirements.txt (pip).
# These are packages rosdep can't express; run this after rosdep_install.sh.
#
#   install_product_deps.sh <src_dir> [--lenient|--strict]
#
# Scans every Aptfile/requirements.txt under <src_dir> at ANY depth (pruning
# build/install/log/.venv/node_modules) — this is what actually covers a product: the stack
# declares its python deps per ROS PACKAGE (e.g.
# duatic_helpers/duatic_kinematics/requirements.txt), not per repo.
#
# Aptfiles are installed before requirements.txt: pip builds routinely need system libraries
# that an Aptfile provides.
#
# All requirements.txt files are resolved together in a single pip install, so that dependency
# crashes will be seen and noted.
#
# A missing Aptfile/requirements.txt, or one containing only comments/blank lines, is a no-op
# (exit 0) — a comment-only manifest must never fail the build.
#
#   --strict   (default) exit non-zero if any apt/pip install failed. Used by robot/runtime
#              builds — the quality gate. Robots never ship incomplete. Installs everything it
#              can before failing, so the recorded manifest lists every problem, then exits 1.
#   --lenient  log a warning but always exit 0. Used by dev images: developers must never
#              be blocked.
#
# Every failed manifest is recorded in /etc/duatic/unresolved-deps.txt as "<apt|pip>: <path>",
# mirroring rosdep_install.sh's /etc/duatic/unresolved-rosdep.txt (duatic-doctor reports
# both). The manifest is TRUNCATED at the start of every run.
#
# NOTE: pip installs into the global venv (/opt/duatic/venv, first on PATH — see docker/Dockerfile's
# base stage). It is created with --system-site-packages, so a requirement apt already satisfies
# is deliberately SKIPPED rather than reinstalled: that is what keeps ROS's C-extension ABI (numpy
# above all) intact, and what lets pip shadow a too-old apt version without having to uninstall
# debian-owned files (which it cannot do — "Cannot uninstall X, RECORD file not found").
#
# NOTE: assumes `apt-get update` already ran earlier in the same RUN layer — this script only
# installs, it does not update/clean package indexes (the caller owns that).

MANIFEST=/etc/duatic/unresolved-deps.txt

SRC=""
LENIENT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lenient)
            LENIENT=1
            shift
            ;;
        --strict)
            LENIENT=0
            shift
            ;;
        -h | --help)
            echo "Usage: $(basename "$0") <src_dir> [--lenient|--strict]"
            echo "  --lenient     warn instead of failing; always exit 0"
            echo "Failed manifests are recorded in ${MANIFEST}."
            exit 0
            ;;
        -*)
            echo "install_product_deps: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            SRC="$1"
            shift
            ;;
    esac
done

SRC="${SRC:-src}"

if [[ ! -d "$SRC" ]]; then
    echo "install_product_deps: '${SRC}' is not a directory — nothing to install."
    exit 0
fi

mkdir -p "$(dirname "$MANIFEST")"
: >"$MANIFEST"

FAILED=0

# discover <filename> — manifests to install, one path per line, deterministic order.
discover() {
    local name="$1"
    find "$SRC" \
        \( -name build -o -name install -o -name log -o -name .venv -o -name node_modules \) -prune \
        -o -type f -name "$name" -print |
        LC_ALL=C sort || true
}

# has_content <file> — false when the file holds nothing but comments and blank lines.
has_content() { grep -qvE '^[[:space:]]*(#|$)' "$1"; }

# note_failure <apt|pip> <manifest_path> <message>
note_failure() {
    printf '%s: %s\n' "$1" "$2" >>"$MANIFEST"
    if [[ "$LENIENT" == "1" ]]; then
        echo "WARNING: install_product_deps: $3 (lenient mode — continuing)" >&2
    else
        echo "install_product_deps: $3" >&2
        FAILED=1
    fi
}

mapfile -t aptfiles < <(discover Aptfile)
mapfile -t requirements < <(discover requirements.txt)

for f in "${aptfiles[@]}"; do
    has_content "$f" || continue
    mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$f")
    echo ">>> Installing Aptfile packages from ${f}: ${pkgs[*]}"
    apt-get install -y --no-install-recommends "${pkgs[@]}" ||
        note_failure apt "$f" "apt-get install failed for ${f}"
done

# Merges all requirements.txt to resolve them through pip install in a single pass.
pip_args=()
pip_files=()
for f in "${requirements[@]}"; do
    has_content "$f" || continue
    pip_args+=(-r "$f")
    pip_files+=("$f")
done

if [[ ${#pip_files[@]} -gt 0 ]]; then
    echo ">>> Installing requirements.txt packages from: ${pip_files[*]}"
    if ! pip3 install --no-cache-dir "${pip_args[@]}"; then
        for f in "${pip_files[@]}"; do
            note_failure pip "$f" "pip install failed for ${f} (combined resolve)"
        done
    fi
fi

if [[ -s "$MANIFEST" ]]; then
    echo ""
    echo "=================================================================="
    echo "WARNING: dependency manifests that could not be installed:"
    sed 's/^/  - /' "$MANIFEST"
    echo "recorded in ${MANIFEST}"
    echo "=================================================================="
    echo ""
fi

if [[ "$FAILED" == "1" ]]; then
    echo "install_product_deps: strict mode — dependencies incomplete." >&2
    exit 1
fi

exit 0
