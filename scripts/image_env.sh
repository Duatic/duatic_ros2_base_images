#!/usr/bin/env bash
# Shared repository / ROS-distro / image-name resolver for the workspace images.
# Source this from scripts/ to get consistent names for a (repository, distro) cell.
# Single source of truth for the naming convention. The factory keeps no list of repositories:
# whichever repository calls it roots the image, and the image is named after it.
#
# Inputs (env var takes precedence over default):
#   ROS_DISTRO   any distro docker/base.Dockerfile builds (default: jazzy);
#                not validated against a fixed list here
#   IMAGE_DATE   immutable date tag                        (default: today, YYYY-MM-DD)
#   FACTORY_REF  the git ref of this repository the factory runs from, as job.workflow_ref
#                names it (refs/tags/v1, refs/tags/v1.2.3, refs/heads/main, ...); unset for
#                a local build. Selects the ros2-base / ros2-dev release to build on.
#
# Exports:
#   SOURCE_REPO      the repository rooting the image, e.g. duatic_dynaarm
#   IMAGE_NAME       its image name, the repository without its duatic_ prefix (dynaarm)
#   ROS_DISTRO IMAGE_DATE
#   ROS2_BASE_IMAGE  ros2-base image (fetch, workspace, runtime build FROM it)
#   ROS2_DEV_IMAGE   ros2-dev image (dev builds FROM it)
#   RUNTIME_IMAGE    published runtime image, the product itself (…/<name>, no tag)
#   DEV_IMAGE        published dev image (…/<name>-dev, no tag)
#   CI_IMAGE         ci image (…/<name>-ci, no tag)
#
# Every distro shares one image per role: tags start with the distro (<distro>,
# <distro>-<version>, <distro>-nightly, ...), like the ros2-base / ros2-dev tags.
#
# Functions:
#   image_env_resolve <repository> <distro>   export the vars above for one cell

REGISTRY_NS="ghcr.io/duatic"

# Print the ros2-base / ros2-dev tag that the factory at a given ref builds on.
#
# build_base.sh tags every release X.Y.Z as <distro>-X.Y.Z, <distro>-X.Y, <distro>-X and
# <distro>. The factory and the base images are released together, so a caller pinning the
# factory to a release tag (vX, vX.Y or vX.Y.Z) gets the base images of that same release.
# Any other ref (a branch, a pull request, a commit, or none for a local build) builds on the
# latest release, with a warning: such a factory may rely on base changes not released yet.
#
#   $1  FACTORY_REF (see above), possibly empty
#   $2  the ROS distro
# Prints the tag, e.g. jazzy-1.2.3; returns non-zero for a tag that is not a release.
image_env_base_tag() {
    local ref="$1" distro="$2"
    if [[ "$ref" =~ ^refs/tags/v([0-9]+(\.[0-9]+){0,2})$ ]]; then
        echo "${distro}-${BASH_REMATCH[1]}"
    elif [[ "$ref" == refs/tags/* ]]; then
        echo "Error: factory tag ${ref#refs/tags/} is not a release (vX, vX.Y or vX.Y.Z)." >&2
        return 1
    else
        echo "WARNING: factory ref '${ref:-none}' is not a release tag, so the base images default" \
            "to the latest release (${distro})." >&2
        echo "$distro"
    fi
}

# The distro is not validated here: an unknown distro simply fails later at the pull of the
# ros2-base image. ROS2_BASE_IMAGE / ROS2_DEV_IMAGE may be preset to build against other
# images, such as an unreleased base image pushed under a test tag.
image_env_resolve() { # <repository> <distro>
    if [[ -z "${1:-}" ]]; then
        echo "Error: no repository to root the image." >&2
        return 1
    fi

    SOURCE_REPO="$1"
    IMAGE_NAME="${SOURCE_REPO#duatic_}"
    ROS_DISTRO="${2:-${ROS_DISTRO:-jazzy}}"
    IMAGE_DATE="${IMAGE_DATE:-$(date +%Y-%m-%d)}"
    if [[ -z "${ROS2_BASE_IMAGE:-}" || -z "${ROS2_DEV_IMAGE:-}" ]]; then
        local base_tag
        base_tag=$(image_env_base_tag "${FACTORY_REF:-}" "$ROS_DISTRO") || return 1
        ROS2_BASE_IMAGE="${ROS2_BASE_IMAGE:-${REGISTRY_NS}/ros2-base:${base_tag}}"
        ROS2_DEV_IMAGE="${ROS2_DEV_IMAGE:-${REGISTRY_NS}/ros2-dev:${base_tag}}"
    fi
    RUNTIME_IMAGE="${REGISTRY_NS}/${IMAGE_NAME}"
    DEV_IMAGE="${REGISTRY_NS}/${IMAGE_NAME}-dev"
    CI_IMAGE="${REGISTRY_NS}/${IMAGE_NAME}-ci"

    export SOURCE_REPO IMAGE_NAME ROS_DISTRO IMAGE_DATE ROS2_BASE_IMAGE ROS2_DEV_IMAGE \
        DEV_IMAGE RUNTIME_IMAGE CI_IMAGE
}
