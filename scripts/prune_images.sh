#!/usr/bin/env bash
set -euo pipefail

# Delete the versions of a GHCR container package that nothing needs any more.
#
# Usage: ./scripts/prune_images.sh --package NAME --before EPOCH [--nightly | --any-tag]
#
# Deletes each version of ghcr.io/<owner>/NAME created before EPOCH (seconds) that is untagged,
# or with --nightly carries only dated nightly tags (image_env_nightly_tag_regex), or with
# --any-tag carries any tags at all, except:
#   - a version that a kept image index references, followed recursively: the per-architecture
#     manifests and attestations of a multi-arch tag are untagged versions of their own;
#   - the newest version, when every version qualifies: GHCR refuses to delete a package's
#     last version.
#
# Environment: GH_TOKEN (packages: write), OWNER (the organization), GITHUB_API_URL (default:
# https://api.github.com). Reading an index needs `docker login ghcr.io`.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=./image_env.sh
source "${SCRIPT_DIR}/image_env.sh"

PACKAGE="" BEFORE="" DELETABLE='^$'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package) PACKAGE="$2"; shift 2 ;;
        --before) BEFORE="$2"; shift 2 ;;
        --nightly) DELETABLE=$(image_env_nightly_tag_regex); shift ;;
        --any-tag) DELETABLE=''; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
if [[ -z "$PACKAGE" || -z "$BEFORE" || -z "${OWNER:-}" || -z "${GH_TOKEN:-}" ]]; then
    echo "Usage: OWNER=... GH_TOKEN=... $0 --package NAME --before EPOCH" \
        "[--nightly | --any-tag]" >&2
    exit 1
fi
API="${GITHUB_API_URL:-https://api.github.com}/orgs/${OWNER}/packages/container/${PACKAGE}/versions"
IMAGE="ghcr.io/${OWNER,,}/${PACKAGE}"

# Print every version of the package as one JSON array.
list_versions() {
    local page versions
    for ((page = 1; ; page++)); do
        versions=$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
            "${API}?per_page=100&page=${page}")
        echo "$versions"
        [[ $(jq length <<<"$versions") -eq 100 ]] || break
    done | jq -s 'add // []'
}

# Print the manifests an image index lists, one "<digest> <mediaType>" per line.
#   $1  the digest of the index
children() {
    docker manifest inspect "${IMAGE}@$1" | jq -r '.manifests[]? | "\(.digest) \(.mediaType)"'
}

# Each version gains .old: created before the cutoff with only deletable tags. The newest one
# never is when all would be.
VERSIONS=$(list_versions | jq --argjson before "$BEFORE" --arg deletable "$DELETABLE" '
    sort_by(.created_at)
    | map(.old = ((.created_at | fromdateiso8601) < $before
                  and all(.metadata.container.tags[]; test($deletable))))
    | if length > 0 and all(.old) then .[-1].old = false else . end')
if ! jq -e 'any(.old)' <<<"$VERSIONS" >/dev/null; then
    echo "${PACKAGE}: nothing to delete among $(jq length <<<"$VERSIONS") versions."
    exit 0
fi

# Every digest a kept tag needs. Only tags point at indexes worth following: an untagged kept
# version is recent, and so is everything it lists. Only indexes are inspected, and a failed
# inspect stops the script, so a needed manifest is never taken for an unreferenced one.
declare -A NEEDED=()
mapfile -t queue < <(jq -r '.[] | select((.old | not) and (.metadata.container.tags | length > 0))
                            | .name' <<<"$VERSIONS")
for digest in "${queue[@]}"; do NEEDED[$digest]=1; done
while [[ ${#queue[@]} -gt 0 ]]; do
    kids=$(children "${queue[0]}")
    queue=("${queue[@]:1}")
    while read -r digest type; do
        [[ -n "$digest" && -z "${NEEDED[$digest]:-}" ]] || continue
        NEEDED[$digest]=1
        [[ "$type" != *index* && "$type" != *manifest.list* ]] || queue+=("$digest")
    done <<<"$kids"
done

mapfile -t DELETE < <(jq -r '.[] | select(.old) | "\(.id) \(.name)"' <<<"$VERSIONS")
deleted=0
for entry in "${DELETE[@]}"; do
    [[ -z "${NEEDED[${entry#* }]:-}" ]] || continue
    curl -fsSL -X DELETE -H "Authorization: Bearer ${GH_TOKEN}" "${API}/${entry%% *}"
    deleted=$((deleted + 1))
done
echo "${PACKAGE}: deleted ${deleted} of $(jq length <<<"$VERSIONS") versions."
