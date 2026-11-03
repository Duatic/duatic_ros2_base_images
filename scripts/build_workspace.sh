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
                               [--push] [--cachebust STR]

The checkout roots the workspace: its repos.list collects the other repositories, and its
packages and dependency manifests go in. The repository is named after the checkout's origin
remote, and the dev and runtime images after the repository without its duatic_ prefix
(duatic_dynaarm -> ghcr.io/duatic/dynaarm/<distro>-{dev,runtime}).

Flags:
  --source DIR           a checkout of the repository rooting the image (required)
  --ros-distro DISTRO    ROS distro to build, e.g. jazzy (not validated; must be one
                         docker/base.Dockerfile builds)                  (default: jazzy)
  --target LIST          comma-separated targets: dev, runtime, or ci on its own
                                                                         (default: dev,runtime)
  --push                 push to ghcr.io (default: only load into the local docker
                         image store)
  --cachebust STR        forces a fresh source clone and a fresh apt-get update/upgrade
                         in workspace/dev                               (default: IMAGE_DATE)
  --version VERSION      RELEASE build (--target runtime only): tags <image>:VERSION instead
                         of :edge/:<IMAGE_DATE>, refuses to build if that tag already
                         exists (release tags are immutable), and, when pushing, moves
                         <image>:stable to point at it. Used by release-image.yml.
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
          :latest is simply still there; developers are never blocked.
  runtime the compiled workspace behind the STRICT dependency gate: the workspace stage
          resolved deps leniently, so a non-empty /etc/duatic/unresolved-rosdep.txt fails
          runtime outright here, whether or not dev fell back. Robots never ship
          incomplete. Nightly publishes :edge, not :latest; see release-image.yml for the
          immutable :<version>/:stable channel.
  ci      the workspace the checkout roots (everything its repos.list collects and every
          dependency, behind the strict gate), without the repository itself: CI builds and
          tests the checkout on top. Tagged with the checkout's commit. Built on its own.

ensure_workspace_build() compiles the workspace once per script invocation, at /opt/duatic/ws
(Dockerfile target `workspace`), into BuildKit's cache only: it is an internal stage, not
one of the published images. build_dev() and build_runtime() both call it; the first call
does the work and the second reuses the cached stage, so `--target dev,runtime` (what the
nightly uses) compiles the workspace once. Two separate `--target dev` / `--target runtime`
runs, e.g. in separate CI jobs, do NOT share it.

Tags produced per target:
  dev:      <image>:latest  and  <image>:<IMAGE_DATE>
  runtime:  <image>:edge    and  <image>:<IMAGE_DATE>           (nightly)
            <image>:<VERSION> and moves <image>:stable          (release-image.yml only)
  ci:       ghcr.io/duatic/ci/<repo>/<distro>:<commit of the checkout>
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
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$VERSION_FLAG" && "$TARGET" != "runtime" ]]; then
    echo "Error: --version is only valid with --target runtime." >&2
    exit 1
fi

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

# Shared by workspace/dev: bumped daily by CI so the nightly apt-get
# upgrade/clone layers actually re-run instead of caching forever on the self-hosted
# runners. A ci build bumps it per run, so every run sees the current upstream heads.
CACHEBUST="${CACHEBUST_FLAG:-$IMAGE_DATE}"
$BUILD_CI && [[ -z "$CACHEBUST_FLAG" ]] && CACHEBUST="ci-$(date +%s%N)"

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
SOURCE_ARGS=(--build-context "source=${SOURCE_DIR}"
             --build-arg "SOURCE_REPO=${SOURCE_REPO}")
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

# Compile the full workspace once per script invocation (Dockerfile target `workspace`).
# Memoized via WORKSPACE_BUILD_OK so build_dev() and build_runtime() calling it in the same
# run (--target dev,runtime) share one compile. Sets WORKSPACE_BUILD_OK
# (true/false, never unset after the first call).
# cacheonly: dev and runtime reach this stage by name and read it from BuildKit's cache,
# so loading the image into the docker store would cost ~10GB for nothing.
WORKSPACE_BUILD_OK=""
ensure_workspace_build() {
    [[ -n "$WORKSPACE_BUILD_OK" ]] && return 0   # already attempted this run

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
# tagged only :<date>, so :latest stays on the last build whose workspace compiled and
# developers pulling it are never handed an image without the underlay. DUATIC_UNDERLAY (baked in as an image ENV) and the
# unresolved-rosdep/unresolved-deps manifests (baked in as files, already warned about
# during the build itself by duatic-rosdep-install/duatic-install-extra-deps) are how a
# developer checks a RUNNING container's actual state (duatic-doctor, from ros2-dev).
build_dev() {
    ensure_workspace_build

    local UNDERLAY_ARG=(--build-arg "DUATIC_UNDERLAY=0")
    local TAGS=("${DEV_IMAGE}:${IMAGE_DATE}")
    if [[ "$WORKSPACE_BUILD_OK" == true ]]; then
        UNDERLAY_ARG=(--build-arg "UNDERLAY_REF=workspace" --build-arg "DUATIC_UNDERLAY=1")
        TAGS+=("${DEV_IMAGE}:latest")
    else
        echo ">>> dev image will be LEAN for ${IMAGE_NAME}/${ROS_DISTRO} (the workspace failed to compile, no prebuilt workspace)." >&2
        $PUSH && echo ">>> NOT moving ${DEV_IMAGE}:latest: the last good one stays." >&2
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
        --build-arg "IMAGE_DATE=${IMAGE_DATE}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        "${TAGS[@]/#/--tag=}" \
        "${OUTPUT_ARG[@]}" \
        "$REPO_ROOT"; then
        echo ">>> dev build FAILED for ${IMAGE_NAME}/${ROS_DISTRO}" >&2
        return 1
    fi
}

# Runtime image: always FROM the compiled workspace (ensure_workspace_build), never a lean
# fallback, robots must not ship incomplete. Fails outright if the workspace didn't compile.
#
# Nightly publishes :edge + :<date> — NOT :latest. A robot pulling :edge knows it's
# whatever main happened to build most recently, no vetting; :latest/:stable are reserved
# for release-image.yml's deliberately-promoted, immutable :<version> tags (customer robots).
# A pushed release build sets RELEASE_REF to the :<version> reference.
build_runtime() {
    ensure_workspace_build

    if [[ "$WORKSPACE_BUILD_OK" != true ]]; then
        echo "Error: the workspace failed to compile for ${IMAGE_NAME}/${ROS_DISTRO}, cannot build runtime (robots must not ship incomplete)." >&2
        return 1
    fi

    local -a TAG_ARGS
    if [[ -n "$VERSION_FLAG" ]]; then
        # Release build. Refuse to overwrite an already-published version — release tags
        # are immutable, full stop. (Any failure here, auth included, is treated the same
        # as "tag not found" and simply proceeds to build; this is a manually-triggered,
        # low-frequency workflow that a human reviews, not a hardened gate.)
        if docker manifest inspect "${RUNTIME_IMAGE}:${VERSION_FLAG}" >/dev/null 2>&1; then
            echo "Error: ${RUNTIME_IMAGE}:${VERSION_FLAG} already exists; release tags are immutable. Pick a new version." >&2
            return 1
        fi
        TAG_ARGS=(-t "${RUNTIME_IMAGE}:${VERSION_FLAG}")
        echo ">>> Building runtime: ${RUNTIME_IMAGE}:${VERSION_FLAG} (RELEASE) for ${IMAGE_NAME}/${ROS_DISTRO}"
    else
        TAG_ARGS=(-t "${RUNTIME_IMAGE}:edge" -t "${RUNTIME_IMAGE}:${IMAGE_DATE}")
        echo ">>> Building runtime: ${RUNTIME_IMAGE}:{edge,${IMAGE_DATE}} for ${IMAGE_NAME}/${ROS_DISTRO}"
    fi

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

    # Move :stable to this version — server-side (imagetools operates on the registry
    # manifest directly), so it needs the version tag to actually be pushed already.
    if [[ -n "$VERSION_FLAG" ]] && $PUSH; then
        echo ">>> Promoting ${RUNTIME_IMAGE}:stable -> ${VERSION_FLAG}"
        docker buildx imagetools create -t "${RUNTIME_IMAGE}:stable" "${RUNTIME_IMAGE}:${VERSION_FLAG}"
        RELEASE_REF="${RUNTIME_IMAGE}:${VERSION_FLAG}"
    fi
}

# CI image: the checkout's workspace without the checkout, tagged with its commit. Sets
# CI_REF to its reference.
build_ci() {
    CI_REF="${CI_IMAGE}:$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    echo ">>> Building ci: ${CI_REF}"
    if ! docker buildx build \
        -f "$DOCKERFILE" \
        --target ci \
        "${PARENT_ARGS[@]}" \
        "${SOURCE_ARGS[@]}" \
        --build-arg "COMPILE_SOURCE=0" \
        --build-arg "CACHEBUST=${CACHEBUST}" \
        "${PARALLEL_ARGS[@]}" \
        "${SECRET_ARG[@]}" \
        -t "$CI_REF" \
        "${OUTPUT_ARG[@]}" \
        "$REPO_ROOT"; then
        echo ">>> ci build FAILED for ${SOURCE_REPO}/${ROS_DISTRO}." >&2
        return 1
    fi
}

setup_cache

if $BUILD_CI; then
    build_ci
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "image=$CI_REF" >> "$GITHUB_OUTPUT"
    exit 0
fi

DEV_RESULT="" RUNTIME_RESULT="" RELEASE_REF=""

# Each stage's result is captured independently
if $BUILD_DEV; then
    if build_dev; then DEV_RESULT=success; else DEV_RESULT=failure; fi
fi
if $BUILD_RUNTIME; then
    if build_runtime; then RUNTIME_RESULT=success; else RUNTIME_RESULT=failure; fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    [[ -n "$DEV_RESULT" ]] && echo "dev_result=$DEV_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$RUNTIME_RESULT" ]] && echo "runtime_result=$RUNTIME_RESULT" >> "$GITHUB_OUTPUT"
    [[ -n "$RELEASE_REF" ]] && echo "image=$RELEASE_REF" >> "$GITHUB_OUTPUT"
fi

echo "Done."
[[ "$DEV_RESULT" == "failure" || "$RUNTIME_RESULT" == "failure" ]] && exit 1
exit 0
