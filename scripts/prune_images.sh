#!/usr/bin/env bash
set -euo pipefail

# Delete the versions of a GHCR container package that nothing needs any more.
#
# Usage: ./scripts/prune_images.sh --package NAME --before EPOCH [--deletable-tags REGEX]
#
# Deletes each version of ghcr.io/<owner>/NAME created before EPOCH (seconds) whose tags all
# match REGEX (default: none, so only untagged versions qualify), except:
#   - a version that a kept image index references, followed recursively: the per-architecture
#     manifests and attestations of a multi-arch tag are untagged versions of their own;
#   - the newest version, when every version qualifies: GHCR refuses to delete a package's
#     last version.
#
# Environment: GH_TOKEN (packages: write), OWNER (the organization), GITHUB_API_URL (default:
# https://api.github.com). Reading an index needs `docker login ghcr.io`.

PACKAGE="" BEFORE="" DELETABLE='^$'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package) PACKAGE="$2"; shift 2 ;;
        --before) BEFORE="$2"; shift 2 ;;
        --deletable-tags) DELETABLE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
if [[ -z "$PACKAGE" || -z "$BEFORE" || -z "${OWNER:-}" || -z "${GH_TOKEN:-}" ]]; then
    echo "Usage: OWNER=... GH_TOKEN=... $0 --package NAME --before EPOCH" \
        "[--deletable-tags REGEX]" >&2
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
        [[ $(jq length <<<"$versions") -gt 0 ]] || break
        echo "$versions"
    done | jq -s 'add // []'
}

# Print the digests an image index lists, one per line; nothing for a single manifest.
#   $1  the digest of the version
children() {
    docker manifest inspect "${IMAGE}@$1" | jq -r '.manifests[]?.digest'
}

VERSIONS=$(list_versions)
# Each version gains .old: created before the cutoff with only deletable tags.
VERSIONS=$(jq --argjson before "$BEFORE" --arg deletable "$DELETABLE" '
    map(.old = ((.created_at | fromdateiso8601) < $before
                and all(.metadata.container.tags[]; test($deletable))))' <<<"$VERSIONS")
if jq -e 'length > 0 and all(.old)' <<<"$VERSIONS" >/dev/null; then
    VERSIONS=$(jq 'sort_by(.created_at) | .[-1].old = false' <<<"$VERSIONS")
fi

# Every digest a kept tag needs. Only tags point at indexes worth following: an untagged kept
# version is recent, and so is everything it lists. A failed inspect stops the script, so a
# needed manifest is never taken for an unreferenced one.
declare -A NEEDED=()
mapfile -t queue < <(jq -r '.[] | select((.old | not) and (.metadata.container.tags | length > 0))
                            | .name' <<<"$VERSIONS")
while [[ ${#queue[@]} -gt 0 ]]; do
    digest=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -z "${NEEDED[$digest]:-}" ]] || continue
    NEEDED[$digest]=1
    kids=$(children "$digest")
    [[ -z "$kids" ]] || mapfile -t -O "${#queue[@]}" queue <<<"$kids"
done

mapfile -t DELETE < <(jq -r '.[] | select(.old) | "\(.id) \(.name)"' <<<"$VERSIONS")
deleted=0
for entry in "${DELETE[@]}"; do
    [[ -z "${NEEDED[${entry#* }]:-}" ]] || continue
    curl -fsSL -X DELETE -H "Authorization: Bearer ${GH_TOKEN}" "${API}/${entry%% *}"
    deleted=$((deleted + 1))
done
echo "${PACKAGE}: deleted ${deleted} of $(jq length <<<"$VERSIONS") versions."
