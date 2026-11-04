#!/usr/bin/env bash
set -euo pipefail

# Build the dev / runtime / ci image of a repository checkout for one ROS distro. Run with
# --help for full flag documentation.
#
# See README.md for the architecture (stage graph, strict-vs-lenient dependency gate, dev's
# lean fallback, and why dev and runtime share one workspace compile via
# ensure_workspace_build() below).

usage() {
    cat <<'EOF'
Build the dev / runtime / ci image of a repository checkout for one ROS distro.

Usage:
  ./scripts/build_workspace.sh --source DIR [--ros-distro DISTRO]
                               [--target dev,runtime|dev|runtime|ci]
                               [--push] [--cachebust STR] [--sources-lock FILE]

The checkout roots the workspace: its repos.list collects the other repositories, and its
packages and dependency manifests go in. The repository is named after the checkout's origin
remote, and its images after the repository without its duatic_ prefix: duatic_dynaarm
publishes ghcr.io/duatic/dynaarm (runtime), dynaarm-dev and dynaarm-ci, every distro in each.

Flags:
  --source DIR           a checkout of the repository rooting the image (required)
  --ros-distro DISTRO    ROS distro to build, e.g. jazzy (not validated; must be one
                         docker/base.Dockerfile builds)                  (default: jazzy)
  --target LIST          comma-separated targets: dev, runtime, or ci on its own
                                                                         (default: dev,runtime)
  --push                 push to ghcr.io (default: only load into the local docker
                         image store)
  --cachebust STR        forces a fresh source clone and a fresh apt-get update/upgrade
                         in ci/dev, and a new ci key                    (default: IMAGE_DATE)
  --version VERSION      RELEASE build (--target runtime or dev,runtime): builds everything
                         from scratch, never reusing a ci image; tags each image
                         :<distro>-VERSION instead of the nightly tags and moves its
                         :<distro> to it, refuses to build if a VERSION tag already exists
                         (release tags are immutable), and builds dev only once runtime
                         passed. Used by release-image.yml.
  --sources-lock FILE    rebuild from the sources.lock.repos of an earlier image instead of
                         the branches repos.list names; --source must be the root at the
                         commit FILE names
  --parallel-workers N   colcon packages compiled concurrently          (default: 4)
  --inner-jobs N         make jobs inside each package                  (default: 1)
                         Concurrent compilers is the product of the two; size it against
                         the runner's DIND_MEMORY_LIMIT in duatic_computer_setup.
  -h, --help             print this help and exit

GitHub auth for the private-repo clones is resolved in this order:
  1. $GIT_AUTH_TOKEN in the environment (used by CI)
  2. `gh auth token` from an existing gh login (local convenience)

The parents are ghcr.io/duatic/ros2-{base,dev}, at the release image_env.sh derives from
$FACTORY_REF. Preset ROS2_BASE_IMAGE / ROS2_DEV_IMAGE to build against other tags.

Targets:
  dev     ros2-dev + the workspace's deps + the prebuilt workspace at /opt/duatic/ws/install
          as an underlay dev_workspace's src/ overlays. When the workspace fails to compile
          (e.g. a missing dependency), dev falls back to a LEAN image (no prebuilt
          workspace) instead of blocking developers (DUATIC_UNDERLAY inside the image
          records which one it got). A FAILED build publishes nothing, so yesterday's
          :<distro> is simply still there; developers are never blocked.
  runtime the compiled workspace behind the STRICT dependency gate: the workspace stage
          resolved deps leniently, so a non-empty /etc/duatic/unresolved-rosdep.txt fails
          runtime outright here, whether or not dev fell back. Robots never ship
          incomplete. Nightly publishes :<distro>-nightly; :<distro> is reserved for the
          latest release (release-image.yml).
  ci      every dependency of the workspace and the upstream repositories compiled (everything
          its repos.list collects), without the repository itself: CI builds and tests the
          checkout on top, and dev and runtime compile it in. Lenient: CI and runtime gate on
          its unresolved dependencies. Built on its own as a target.

The repository set is resolved first: every branch repos.list names, recursively, is pinned to
its commit (scripts/expand_repos.py). The ci image is keyed on everything it is built from:
the cachebust day, the factory commit, the ros2-base digest, the distro, the pinned upstream
repositories and the checkout's package.xml, Aptfile and requirements.txt files. When an
image with that key is published, every target reuses it instead of building it; a pushed
build that had to build it publishes it for the next. A release never reuses one.

ensure_workspace_build() compiles the checkout on top of ci once per script invocation, at
/opt/duatic/ws (Dockerfile target `workspace`), into BuildKit's cache only: it is an internal
stage, not one of the published images. build_dev() and build_runtime() both call it; the
first call does the work and the second reuses the cached stage, so `--target dev,runtime`
(what the nightly uses) compiles the checkout once.

Tags produced per target, e.g. for duatic_dynaarm on jazzy:
  runtime:  dynaarm:jazzy-nightly     and  dynaarm:jazzy-<IMAGE_DATE>      (nightly)
            dynaarm:jazzy-<VERSION>   and moves dynaarm:jazzy             (release-image.yml only)
  dev:      dynaarm-dev:jazzy         and  dynaarm-dev:jazzy-<IMAGE_DATE>  (nightly)
            dynaarm-dev:jazzy-<VERSION> and  dynaarm-dev:jazzy             (release-image.yml only)
  ci:       dynaarm-ci:jazzy-<key>
EOF
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)
DOCKERFILE="${REPO_ROOT}/docker/workspace.Dockerfile"

DISTRO_FLAG="jazzy"
TARGET="dev,runtime"
PUSH=false
CACHEBUST_FLAG=""
VERSION_FLAG=""
PARALLEL_WORKERS_FLAG=""
INNER_JOBS_FLAG=""
SOURCE_FLAG=""
SOURCES_LOCK_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ros-distro) DISTRO_FLAG="$2"; shift 2 ;;
        --ros-distro=*) DISTRO_FLAG="${1#*=}"; shift ;;
        --target) TARGET="$2"; shift 2 ;;
        --target=*) TARGET="${1#*=}"; shift ;;
        --push) PUSH=true; shift ;;
        --cachebust) CACHEBUST_FLAG="$2"; shift 2 ;;
        --cachebust=*) CACHEBUST_FLAG="${1#*=}"; shift ;;
        --version) VERSION_FLAG="$2"; shift 2 ;;
        --version=*) VERSION_FLAG="${1#*=}"; shift ;;
        --parallel-workers) PARALLEL_WORKERS_FLAG="$2"; shift 2 ;;
        --parallel-workers=*) PARALLEL_WORKERS_FLAG="${1#*=}"; shift ;;
        --inner-jobs) INNER_JOBS_FLAG="$2"; shift 2 ;;
        --inner-jobs=*) INNER_JOBS_FLAG="${1#*=}"; shift ;;
        --source) SOURCE_FLAG="$2"; shift 2 ;;
        --source=*) SOURCE_FLAG="${1#*=}"; shift ;;
        --sources-lock) SOURCES_LOCK_FLAG="$2"; shift 2 ;;
        --sources-lock=*) SOURCES_LOCK_FLAG="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

BUILD_DEV=false BUILD_RUNTIME=false BUILD_CI=false
IFS=, read -r -a TARGETS <<<"$TARGET"
for t in "${TARGETS[@]}"; do
    case "$t" in
        dev) BUILD_DEV=true ;;
        runtime) BUILD_RUNTIME=true ;;
        ci) BUILD_CI=true ;;
        *) echo "Invalid --target: $t" >&2; exit 1 ;;
    esac
done
$BUILD_DEV || $BUILD_RUNTIME || $BUILD_CI || { echo "Error: --target names no target." >&2; exit 1; }
if $BUILD_CI && [[ ${#TARGETS[@]} -gt 1 ]]; then
    echo "Error: --target ci builds on its own." >&2
    exit 1
fi
if [[ -n "$VERSION_FLAG" ]] && ! $BUILD_RUNTIME; then
    echo "Error: --version releases runtime: use --target runtime or dev,runtime." >&2
    exit 1
fi

if [[ -z "$SOURCE_FLAG" ]]; then
    echo "Error: --source is required." >&2
    exit 1
fi
SOURCE_DIR=$(cd -- "$SOURCE_FLAG" && pwd)
ORIGIN_URL=$(git -C "$SOURCE_DIR" remote get-url origin) || {
    echo "Error: ${SOURCE_DIR} has no origin remote to name the repository after." >&2
    exit 1
}

# shellcheck source=./image_env.sh
source "${SCRIPT_DIR}/image_env.sh"
image_env_resolve "$(basename "$ORIGIN_URL" .git)" "$DISTRO_FLAG"

OUTPUT_ARG=(--load)
$PUSH && OUTPUT_ARG=(--push)

# Shared by every stage and part of the ci key: the day, so the apt-get upgrade and clone
# layers re-run daily instead of caching forever, and a ci image is reused for one day at most.
# Upstream commits need no bump: the pinned set is part of the key.
CACHEBUST="${CACHEBUST_FLAG:-$IMAGE_DATE}"

# Concurrent compilers is the product of the two. See the workspace stage in docker/workspace.Dockerfile.
PARALLEL_WORKERS="${PARALLEL_WORKERS_FLAG:-${PARALLEL_WORKERS:-4}}"
INNER_JOBS="${INNER_JOBS_FLAG:-${INNER_JOBS:-1}}"
for v in PARALLEL_WORKERS INNER_JOBS; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || { echo "$v must be a positive integer, got '${!v}'" >&2; exit 1; }
done
# Part of the workspace cache key: dev and runtime re-enter that stage, so all three
# builds must pass the same values or the workspace is compiled once per invocation.
PARALLEL_ARGS=(--build-arg "PARALLEL_WORKERS=${PARALLEL_WORKERS}"
               --build-arg "INNER_JOBS=${INNER_JOBS}")

# GitHub auth for the private-repo clone in the fetch stage. Sets SECRET_ARG.
resolve_token() {
    # Local convenience: reuse an existing `gh` login when no token is in the environment.
    if [[ -z "${GIT_AUTH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
        if gh_token=$(gh auth token 2>/dev/null) && [[ -n "$gh_token" ]]; then
            export GIT_AUTH_TOKEN="$gh_token"
            echo ">>> Using token from 'gh auth token'."
        fi
    fi
    if [[ -n "${GIT_AUTH_TOKEN:-}" ]]; then
        SECRET_ARG=(--secret "id=GIT_AUTH_TOKEN,env=GIT_AUTH_TOKEN")
    else
        echo "Error: no GitHub token. Set GIT_AUTH_TOKEN or log in with 'gh auth login'." >&2
        exit 1
    fi
}

resolve_token

# Passed identically to ensure_workspace_build/build_dev/build_runtime below (like
# CACHEBUST) so their build-args match and BuildKit's cache actually hits across the
# separate `docker buildx build` invocations instead of silently recompiling the workspace
# under a different source or parent image.
SOURCE_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
SOURCE_BRANCH=$(git -C "$SOURCE_DIR" symbolic-ref -q --short HEAD || echo "$SOURCE_COMMIT")
SOURCE_ARGS=(--build-context "source=${SOURCE_DIR}"
             --build-arg "SOURCE_REPO=${SOURCE_REPO}"
             --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}"
             --build-arg "SOURCE_BRANCH=${SOURCE_BRANCH}")
PARENT_ARGS=(--build-arg "ROS2_BASE_IMAGE=${ROS2_BASE_IMAGE}"
             --build-arg "ROS2_DEV_IMAGE=${ROS2_DEV_IMAGE}")
echo ">>> Public parents: ${ROS2_BASE_IMAGE}, ${ROS2_DEV_IMAGE}"

# Both paths create a docker-container builder; HOSTIP, set only on the runners, is what
# adds the in-cluster registry mirrors. The driver is required either way: the classic
# docker driver's exporter support varies with the daemon's buildkit version, and
# ensure_workspace_build's --output type=cacheonly needs it.
setup_cache() {
    if [[ -z "${HOSTIP:-}" ]]; then
        echo ">>> HOSTIP unset — building without in-cluster registry mirrors (direct)."
        if ! docker buildx inspect duatic-plain >/dev/null 2>&1; then
            docker buildx create --name duatic-plain --driver docker-container --bootstrap --use
        else
            docker buildx use duatic-plain
        fi
        return 0
    fi
    # Render buildkitd.toml with the runtime node IP (sed, so no gettext dep) and
    # create/use a docker-container builder that mirrors Docker Hub + ghcr pulls.
    local cfg="${REPO_ROOT}/docker/buildkitd.toml"
    sed "s|\${HOSTIP}|${HOSTIP}|g" "${REPO_ROOT}/docker/buildkitd.toml.tmpl" > "$cfg"
    if ! docker buildx inspect duatic-cache >/dev/null 2>&1; then
        docker buildx create --name duatic-cache \
            --driver docker-container \
            --driver-opt "image=moby/buildkit:${BUILDKIT_IMAGE_VERSION:-v0.20.2}" \
            --buildkitd-config "$cfg" \
            --bootstrap --use
    else
        docker buildx use duatic-cache
    fi
    echo ">>> In-cluster registry mirrors active at ${HOSTIP} (base-image pulls)."
}

# Pin the repository set (Dockerfile target lock, see its resolve stage) and pass it to every
# later build as the lock context, so they all build exactly the commits the ci key names.
# Sets LOCK_DIR.
resolve_lock() {
    LOCK_DIR=$(mktemp -d)
    trap 'rm -rf "$LOCK_DIR"' EXIT
    local lock_args=()
    if [[ -n "$SOURCES_LOCK_FLAG" ]]; then
        mkdir "${LOCK_DIR}/given"
        cp "$SOURCES_LOCK_FLAG" "${LOCK_DIR}/given/sources.lock.repos"
        lock_args=(--build-context "sourceslock=${LOCK_DIR}/given")
    fi
    echo ">>> Resolving the repository set of ${IMAGE_NAME}/${ROS_DISTRO}"
    docker buildx build \
        -f "$DOCKERFILE" \
        --target lock \
        --no-cache-filter resolve \
        "${PARENT_ARGS[@]}" \
        "${SOURCE_ARGS[@]}" \
        "${lock_args[@]}" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        "${SECRET_ARG[@]}" \
        --output "type=local,dest=${LOCK_DIR}" \
        "$REPO_ROOT"
    SOURCE_ARGS+=(--build-context "lock=${LOCK_DIR}")
}

# Print the ci key: a digest of everything the ci image is built from (see --help).
ci_key() {
    # The factory files the ci stage reads, so a commit elsewhere (docs, workflows) keeps the key.
    local paths=(docker scripts config) factory base
    factory=$(git -C "$REPO_ROOT" rev-parse "${paths[@]/#/HEAD:}" 2>/dev/null) ||
        factory="unversioned $(date +%s%N)"
    # Uncommitted changes to them key on their content, so a local edit never reuses an image.
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "${paths[@]}" 2>/dev/null)" ]]; then
        factory+=" $({ git -C "$REPO_ROOT" status --porcelain -- "${paths[@]}"
            git -C "$REPO_ROOT" diff HEAD -- "${paths[@]}"; } | sha256sum)"
    fi
    base=$(docker buildx imagetools inspect "$ROS2_BASE_IMAGE" --format '{{.Manifest.Digest}}')
    {
        printf '%s\n' "cachebust ${CACHEBUST}" "factory ${factory}" "base ${base}" "distro ${ROS_DISTRO}"
        cat "${LOCK_DIR}/upstream.repos"
        "${SCRIPT_DIR}/duatic_deps.sh" --list "$SOURCE_DIR"
    } | sha256sum | cut -c1-16
}

# The ci image every other target builds on, once per script invocation (Dockerfile target
# ci): reused when an image with this run's key is published, built otherwise. A pushed
# non-release build publishes what it built under the key; a release never reuses one and
# keeps its own in BuildKit's cache. On reuse, every later build's ci stage is the published
# image. Sets CI_REF, and CI_OK (true/false, never unset after the first call).
CI_OK=""
ensure_ci() {
    [[ -n "$CI_OK" ]] && return 0
    local output=(--output type=cacheonly)
    if [[ -n "$VERSION_FLAG" ]]; then
        CI_REF="the release's own (not published)"
    else
        CI_REF="${CI_IMAGE}:${ROS_DISTRO}-$(ci_key)"
        if docker manifest inspect "$CI_REF" >/dev/null 2>&1; then
            echo ">>> Reusing ${CI_REF}: nothing it is built from changed."
            SOURCE_ARGS+=(--build-context "ci=docker-image://${CI_REF}")
            CI_OK=true
            return 0
        fi
        # Published as a single manifest without provenance: each key is then one package
        # version, which the nightly's pruning deletes whole, with no attestation manifests left.
        if $BUILD_CI || $PUSH; then
            output=("${OUTPUT_ARG[@]}" --provenance=false --tag "$CI_REF")
        fi
    fi
    echo ">>> Building ci: ${CI_REF}"
    if docker buildx build \
        -f "$DOCKERFILE" \
        --target ci \
        "${PARENT_ARGS[@]}" \
        "${SOURCE_ARGS[@]}" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        "${output[@]}" \
        "$REPO_ROOT"; then
        CI_OK=true
    else
        CI_OK=false
        echo ">>> ci build FAILED for ${IMAGE_NAME}/${ROS_DISTRO}." >&2
    fi
}

# Compile the checkout on top of ci once per script invocation (Dockerfile target `workspace`).
# Memoized via WORKSPACE_BUILD_OK so build_dev() and build_runtime() calling it in the same
# run (--target dev,runtime) share one compile. Sets WORKSPACE_BUILD_OK
# (true/false, never unset after the first call).
# cacheonly: dev and runtime reach this stage by name and read it from BuildKit's cache,
# so loading the image into the docker store would cost ~10GB for nothing.
WORKSPACE_BUILD_OK=""
ensure_workspace_build() {
    [[ -n "$WORKSPACE_BUILD_OK" ]] && return 0   # already attempted this run

    ensure_ci
    if [[ "$CI_OK" != true ]]; then
        WORKSPACE_BUILD_OK=false
        echo ">>> dev will fall back to a LEAN image (DUATIC_UNDERLAY=0); runtime cannot be built." >&2
        return 0
    fi

    echo ">>> Building the workspace (target workspace): ${IMAGE_NAME}/${ROS_DISTRO}"
    if docker buildx build \
        -f "$DOCKERFILE" \
        --target workspace \
        "${PARENT_ARGS[@]}" \
        "${SOURCE_ARGS[@]}" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        --output type=cacheonly \
        "$REPO_ROOT"; then
        WORKSPACE_BUILD_OK=true
    else
        WORKSPACE_BUILD_OK=false
        echo ">>> workspace build FAILED for ${IMAGE_NAME}/${ROS_DISTRO} (missing/broken dependency?)." >&2
        echo ">>> dev will fall back to a LEAN image (DUATIC_UNDERLAY=0); runtime cannot be built." >&2
    fi
}

# Dev image: copies the workspace's install (ensure_workspace_build) in as a prebuilt
# underlay; falls back to a lean image if the workspace failed to compile. A lean image is
# tagged only :<distro>-<date>, so :<distro> stays on the last build whose workspace compiled and
# developers pulling it are never handed an image without the underlay. DUATIC_UNDERLAY (baked in as an image ENV) and the
# unresolved-rosdep/unresolved-deps manifests (baked in as files, already warned about
# during the build itself by duatic-rosdep-install/duatic-install-extra-deps) are how a
# developer checks a RUNNING container's actual state (duatic-doctor, from ros2-dev).
# A release tags DEV_RELEASE_TAG and moves :<distro>; a pushed one sets RELEASE_DEV_REF to it.
build_dev() {
    ensure_workspace_build

    local UNDERLAY_ARG=(--build-arg "DUATIC_UNDERLAY=0")
    local TAGS=("${DEV_RELEASE_TAG:-${DEV_IMAGE}:${ROS_DISTRO}-${IMAGE_DATE}}")
    if [[ "$WORKSPACE_BUILD_OK" == true ]]; then
        UNDERLAY_ARG=(--build-arg "UNDERLAY_REF=workspace" --build-arg "DUATIC_UNDERLAY=1")
        TAGS+=("${DEV_IMAGE}:${ROS_DISTRO}")
    else
        echo ">>> dev image will be LEAN for ${IMAGE_NAME}/${ROS_DISTRO} (the workspace failed to compile, no prebuilt workspace)." >&2
        $PUSH && echo ">>> NOT moving ${DEV_IMAGE}:${ROS_DISTRO}: the last good one stays." >&2
    fi

    echo ">>> Building dev: ${TAGS[*]} for ${IMAGE_NAME}/${ROS_DISTRO}"
    if ! docker buildx build \
        -f "$DOCKERFILE" \
        --target dev \
        "${PARENT_ARGS[@]}" \
        "${UNDERLAY_ARG[@]}" \
        "${SOURCE_ARGS[@]}" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        --build-arg "IMAGE_NAME=${IMAGE_NAME}" \
        --build-arg "IMAGE_VERSION=${VERSION_FLAG:-$IMAGE_DATE}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        "${TAGS[@]/#/--tag=}" \
        "${OUTPUT_ARG[@]}" \
        "$REPO_ROOT"; then
        echo ">>> dev build FAILED for ${IMAGE_NAME}/${ROS_DISTRO}" >&2
        return 1
    fi
    if [[ -n "$DEV_RELEASE_TAG" ]] && $PUSH; then
        RELEASE_DEV_REF="$DEV_RELEASE_TAG"
    fi
}

# Runtime image: always FROM the compiled workspace (ensure_workspace_build), never a lean
# fallback, robots must not ship incomplete. Fails outright if the workspace didn't compile.
#
# Nightly publishes :<distro>-nightly and :<distro>-<date>. A robot pulling :<distro>-nightly
# knows it's whatever main happened to build most recently, no vetting; the bare :<distro> is
# reserved for release-image.yml's deliberately promoted, immutable :<distro>-<version> tags
# (customer robots). A pushed release build sets RELEASE_REF to RUNTIME_RELEASE_TAG.
build_runtime() {
    local DISTRO_REF="${RUNTIME_IMAGE}:${ROS_DISTRO}" DESCRIPTION
    local -a TAG_ARGS
    if [[ -n "$RUNTIME_RELEASE_TAG" ]]; then
        TAG_ARGS=(-t "$RUNTIME_RELEASE_TAG")
        DESCRIPTION="${RUNTIME_RELEASE_TAG} (RELEASE)"
    else
        TAG_ARGS=(-t "${DISTRO_REF}-nightly" -t "${DISTRO_REF}-${IMAGE_DATE}")
        DESCRIPTION="${DISTRO_REF}-{nightly,${IMAGE_DATE}}"
    fi

    ensure_workspace_build

    if [[ "$WORKSPACE_BUILD_OK" != true ]]; then
        echo "Error: the workspace failed to compile for ${IMAGE_NAME}/${ROS_DISTRO}, cannot build runtime (robots must not ship incomplete)." >&2
        return 1
    fi

    echo ">>> Building runtime: ${DESCRIPTION} for ${IMAGE_NAME}/${ROS_DISTRO}"
    # Checked explicitly rather than relying on this being the last statement: see build_dev().
    if ! docker buildx build \
        -f "$DOCKERFILE" \
        --target runtime \
        "${PARENT_ARGS[@]}" \
        "${SOURCE_ARGS[@]}" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        --build-arg "IMAGE_NAME=${IMAGE_NAME}" \
        "${TAG_ARGS[@]}" \
        "${OUTPUT_ARG[@]}" \
        "$REPO_ROOT"; then
        echo ">>> runtime build FAILED for ${IMAGE_NAME}/${ROS_DISTRO}." >&2
        return 1
    fi

    # Move :<distro> to this version — server-side (imagetools operates on the registry
    # manifest directly), so it needs the version tag to actually be pushed already.
    if [[ -n "$RUNTIME_RELEASE_TAG" ]] && $PUSH; then
        echo ">>> Promoting ${DISTRO_REF} -> ${RUNTIME_RELEASE_TAG}"
        docker buildx imagetools create -t "$DISTRO_REF" "$RUNTIME_RELEASE_TAG"
        RELEASE_REF="$RUNTIME_RELEASE_TAG"
    fi
}

setup_cache

DEV_RESULT="" RUNTIME_RESULT="" RELEASE_REF="" RELEASE_DEV_REF=""

# Refuse to overwrite an already-published version, before resolving or compiling anything.
RUNTIME_RELEASE_TAG="" DEV_RELEASE_TAG=""
if [[ -n "$VERSION_FLAG" ]]; then
    RUNTIME_RELEASE_TAG="${RUNTIME_IMAGE}:${ROS_DISTRO}-${VERSION_FLAG}"
    $BUILD_DEV && DEV_RELEASE_TAG="${DEV_IMAGE}:${ROS_DISTRO}-${VERSION_FLAG}"
    for ref in "$RUNTIME_RELEASE_TAG" ${DEV_RELEASE_TAG:+"$DEV_RELEASE_TAG"}; do
        if docker manifest inspect "$ref" >/dev/null 2>&1; then
            echo "Error: ${ref} already exists; release tags are immutable. Pick a new version." >&2
            exit 1
        fi
    done
fi

resolve_lock

if $BUILD_CI; then
    ensure_ci
    [[ "$CI_OK" == true ]] || exit 1
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "image=$CI_REF" >> "$GITHUB_OUTPUT"
    exit 0
fi

# Each stage's result is captured independently. Runtime goes first: a release builds dev
# only after runtime passed its strict gate, so a failed release publishes no dev image under
# its version either.
if $BUILD_RUNTIME; then
    if build_runtime; then RUNTIME_RESULT=success; else RUNTIME_RESULT=failure; fi
fi
if $BUILD_DEV; then
    if [[ -n "$VERSION_FLAG" && "$RUNTIME_RESULT" != success ]]; then
        echo ">>> Skipping dev: the release of runtime failed." >&2
        DEV_RESULT=failure
    elif build_dev; then DEV_RESULT=success; else DEV_RESULT=failure; fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    [[ -n "$DEV_RESULT" ]] && echo "dev_result=$DEV_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$RUNTIME_RESULT" ]] && echo "runtime_result=$RUNTIME_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$RELEASE_REF" ]] && echo "image=$RELEASE_REF" >> "$GITHUB_OUTPUT"
    [[ -n "$RELEASE_DEV_REF" ]] && echo "dev_image=$RELEASE_DEV_REF" >> "$GITHUB_OUTPUT"
fi

echo "Done."
[[ "$DEV_RESULT" == "failure" || "$RUNTIME_RESULT" == "failure" ]] && exit 1
exit 0
