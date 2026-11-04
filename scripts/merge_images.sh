#!/usr/bin/env bash
# The per-architecture maps are read through the namerefs in all() and tag().
# shellcheck disable=SC2034
set -euo pipefail

# Tag the per-architecture builds of one repository and distro as multi-arch images.
#
# Usage: ./scripts/merge_images.sh --architectures LIST DIR
#
# Each build_workspace.sh --push run pushes its runtime and dev images by digest and records
# them in DIR/<architecture>.env. This assembles the tags image_env.sh's image_env_tags names
# from the digests of every architecture in LIST (comma-separated):
#   - runtime and dev are each tagged only when every architecture built them, so a robot or
#     developer never pulls a tag that lacks their architecture;
#   - dev moves its rolling :<distro> only when every architecture compiled the workspace;
#   - a release tags nothing unless every image it builds succeeded on every architecture, so a
#     failed leg leaves the version unused, and it refuses a version that already exists.
# With GITHUB_OUTPUT set, writes runtime_result, dev_result and, for a release, image and
# dev_image (the :<distro>-<version> references).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=./image_env.sh
source "${SCRIPT_DIR}/image_env.sh"

ARCHITECTURES=""
while [[ $# -gt 1 ]]; do
    case "$1" in
        --architectures) ARCHITECTURES="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
DIR="${1:?usage: merge_images.sh --architectures LIST DIR}"
IFS=, read -r -a ARCHS <<<"$ARCHITECTURES"
[[ ${#ARCHS[@]} -gt 0 ]] || { echo "Error: --architectures names none." >&2; exit 1; }

# Read every architecture's record. A missing one is an architecture whose build never got to
# write it: everything it should have built counts as failed. Each map holds a value only for
# the architectures that have it: a digest, or "true" when the workspace compiled.
declare -A RUNTIME_DIGESTS DEV_DIGESTS DEV_COMPLETES
for arch in "${ARCHS[@]}"; do
    f="${DIR}/${arch}.env"
    if [[ ! -f "$f" ]]; then
        echo ">>> No build of ${arch} recorded." >&2
        continue
    fi
    # Parsed, not sourced: the records arrive as artifacts. Only the keys build_workspace.sh
    # writes are taken.
    RUNTIME_DIGEST="" DEV_DIGEST="" DEV_COMPLETE=""
    while IFS='=' read -r key value; do
        case "$key" in
            RUNTIME_IMAGE | DEV_IMAGE | ROS_DISTRO | IMAGE_DATE | VERSION | BUILD_RUNTIME | \
                BUILD_DEV | RUNTIME_DIGEST | DEV_DIGEST | DEV_COMPLETE) printf -v "$key" '%s' "$value" ;;
        esac
    done <"$f"
    RUNTIME_DIGESTS[$arch]="$RUNTIME_DIGEST" DEV_DIGESTS[$arch]="$DEV_DIGEST"
    [[ "$DEV_COMPLETE" == true ]] && DEV_COMPLETES[$arch]=true
done
: "${RUNTIME_IMAGE:?no architecture recorded a build}"

# Whether every architecture has a value in the map.
all() { # <map name>
    local -n map="$1"
    local arch
    for arch in "${ARCHS[@]}"; do [[ -n "${map[$arch]:-}" ]] || return 1; done
}
RUNTIME_RESULT="" DEV_RESULT=""
if [[ "$BUILD_RUNTIME" == true ]]; then
    if all RUNTIME_DIGESTS; then RUNTIME_RESULT=success; else RUNTIME_RESULT=failure; fi
fi
if [[ "$BUILD_DEV" == true ]]; then
    if all DEV_DIGESTS; then DEV_RESULT=success; else DEV_RESULT=failure; fi
fi

# Create one multi-arch index under every tag of a role. Prints the immutable reference.
tag() { # <role> <image> <digests map name> <complete>
    local role="$1" image="$2" complete="$4" arch t
    local -n digests="$3"
    local args=() tags
    mapfile -t tags < <(image_env_tags "$role" "$VERSION" "$complete")
    for t in "${tags[@]}"; do args+=(--tag "${image}:${t}"); done
    for arch in "${ARCHS[@]}"; do args+=("${image}@${digests[$arch]}"); done
    echo ">>> Tagging ${image}:{$(IFS=,; echo "${tags[*]}")} for ${ARCHS[*]}" >&2
    docker buildx imagetools create "${args[@]}" >&2
    echo "${image}:${tags[0]}"
}

RELEASE_REF="" RELEASE_DEV_REF=""
if [[ -n "$VERSION" ]]; then
    if [[ "$RUNTIME_RESULT" != success || "${DEV_RESULT:-success}" != success ]]; then
        # A release is all or nothing: report both roles failed, though one may have built.
        echo "Error: the release failed on an architecture; nothing is tagged, ${VERSION} stays unused." >&2
        RUNTIME_RESULT=failure
        [[ -n "$DEV_RESULT" ]] && DEV_RESULT=failure
    else
        image_env_release_free "$VERSION" "$BUILD_DEV" || exit 1
        RELEASE_REF=$(tag runtime "$RUNTIME_IMAGE" RUNTIME_DIGESTS true)
        [[ -n "$DEV_RESULT" ]] && RELEASE_DEV_REF=$(tag dev "$DEV_IMAGE" DEV_DIGESTS true)
    fi
else
    [[ "$RUNTIME_RESULT" == success ]] && tag runtime "$RUNTIME_IMAGE" RUNTIME_DIGESTS true >/dev/null
    if [[ "$DEV_RESULT" == success ]]; then
        complete=false
        all DEV_COMPLETES && complete=true
        $complete || echo ">>> NOT moving ${DEV_IMAGE}:${ROS_DISTRO}: an architecture built a lean dev image." >&2
        tag dev "$DEV_IMAGE" DEV_DIGESTS "$complete" >/dev/null
    fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    [[ -n "$RUNTIME_RESULT" ]] && echo "runtime_result=$RUNTIME_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$DEV_RESULT" ]] && echo "dev_result=$DEV_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$RELEASE_REF" ]] && echo "image=$RELEASE_REF" >> "$GITHUB_OUTPUT"
    [[ -n "$RELEASE_DEV_REF" ]] && echo "dev_image=$RELEASE_DEV_REF" >> "$GITHUB_OUTPUT"
fi
[[ "$RUNTIME_RESULT" != failure && "$DEV_RESULT" != failure ]]
