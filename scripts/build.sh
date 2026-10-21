#!/usr/bin/env bash
set -euo pipefail

# Build the base and/or dev image for one ROS distro. Run with --help for flags.

REGISTRY_NS="${REGISTRY_NS:-ghcr.io/duatic}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/build.sh [--ros-distro DISTRO] [--target base|dev|all]
                     [--platform PLATFORMS] [--version X.Y.Z] [--cachebust STR] [--push]

Flags:
  --ros-distro DISTRO  jazzy | kilted | lyrical | rolling            (default: jazzy)
  --target TARGET      base | dev | all                              (default: all)
  --platform LIST      e.g. linux/arm64 or linux/amd64,linux/arm64   (default: native)
                       More than one platform requires --push.
  --version X.Y.Z      also tag <distro>-X.Y.Z and <distro>-X.Y
  --cachebust STR      force a fresh apt-get update/upgrade
  --push               push to the registry instead of loading locally

Images: $REGISTRY_NS/ros2-base and $REGISTRY_NS/ros2-dev (REGISTRY_NS default: ghcr.io/duatic),
always tagged :<distro>.
EOF
}

ROS_DISTRO=jazzy
TARGET=all
PLATFORM=""
VERSION=""
CACHEBUST=none
PUSH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ros-distro) ROS_DISTRO="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --cachebust) CACHEBUST="$2"; shift 2 ;;
        --push) PUSH=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "build.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$ROS_DISTRO" in
    jazzy | kilted | lyrical | rolling) ;;
    *) echo "build.sh: unsupported ROS distro '$ROS_DISTRO'" >&2; exit 2 ;;
esac
case "$TARGET" in
    base) targets=(base) ;;
    dev) targets=(dev) ;;
    all) targets=(base dev) ;;
    *) echo "build.sh: unknown target '$TARGET'" >&2; exit 2 ;;
esac
if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "build.sh: --version must be X.Y.Z, got '$VERSION'" >&2
    exit 2
fi
if [[ "$PLATFORM" == *,* && "$PUSH" == 0 ]]; then
    echo "build.sh: a multi-platform build cannot be loaded locally; add --push" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

for target in "${targets[@]}"; do
    repo="${REGISTRY_NS}/ros2-${target}"
    tags=(-t "${repo}:${ROS_DISTRO}")
    if [[ -n "$VERSION" ]]; then
        tags+=(-t "${repo}:${ROS_DISTRO}-${VERSION}" -t "${repo}:${ROS_DISTRO}-${VERSION%.*}")
    fi

    args=(
        -f docker/Dockerfile
        --target "$target"
        --build-arg "ROS_DISTRO=${ROS_DISTRO}"
        --build-arg "CACHEBUST=${CACHEBUST}"
        --build-arg "IMAGE_VERSION=${VERSION}"
        "${tags[@]}"
    )
    [[ -n "$PLATFORM" ]] && args+=(--platform "$PLATFORM")
    if [[ "$PUSH" == 1 ]]; then args+=(--push); else args+=(--load); fi

    # dev reuses the base layers cached by the previous iteration.
    echo ">>> building ${repo}:${ROS_DISTRO} (${PLATFORM:-native})"
    docker buildx build "${args[@]}" .
done
