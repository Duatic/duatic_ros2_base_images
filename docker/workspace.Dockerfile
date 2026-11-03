# syntax=docker/dockerfile:1
#
# Duatic workspace images, multi-stage: the workspace a repository roots (the repository and
# everything its repos.list collects), on top of the published images of docker/base.Dockerfile:
# ros2-base (toolchain, venv, mixins, dependency scripts) and ros2-dev (developer tooling,
# shell environment, entrypoint). Published targets are dev, runtime and ci; fetch, manifests
# and workspace are internal stages that let dev and runtime share ONE compile of the workspace.
#
# Build args:
#   ROS2_BASE_IMAGE   public ros2-base image for the distro (fetch, workspace, runtime)
#   ROS2_DEV_IMAGE    public ros2-dev image for the distro (dev)
#   UNDERLAY_REF      what dev copies /opt/duatic/ws from: `no-underlay` (default, lean) or
#                     `workspace`, which build_workspace.sh sets only when the workspace compiled.
#   IMAGE_NAME        image name of the source repository (e.g. dynaarm)
#   SOURCE_REPO       the repository rooting the workspace (e.g. duatic_dynaarm), whose
#                     checkout build_workspace.sh passes as the source build context (below)
#   COMPILE_SOURCE    1 (default): the source repository is compiled with its workspace (dev,
#                     runtime). 0: it only contributes its dependency manifests (ci).
#   CACHEBUST         bump (e.g. to the date) to force a fresh clone, and a fresh
#                     apt-get update/upgrade in workspace/dev, on nightly builds
#
# dev/workspace/runtime need a GitHub token, both for the private repos and to keep the
# public clones in the dependency/compile layers off the per-IP anonymous rate limit. Use
# scripts/build_workspace.sh rather than invoking buildx directly.

ARG ROS2_BASE_IMAGE=ghcr.io/duatic/ros2-base:jazzy
ARG ROS2_DEV_IMAGE=ghcr.io/duatic/ros2-dev:jazzy
ARG UNDERLAY_REF=no-underlay

############################
# sourceslock — optional pinned-manifest override for reproducible RELEASE builds. Empty
# (a zero-byte file) by default: a normal nightly/local build sees nothing here and fetch
# takes its usual branch-tracking path below. Rebuilding a release by hand overrides this
# whole stage via `--build-context sourceslock=<dir with a real sources.lock.repos at its root>`:
# a SHA-exact manifest, itself produced by a PREVIOUS build's `vcs export --exact` (see fetch
# below), so the rebuild reproduces the exact same source tree instead of whatever `main` has
# drifted to since.
############################
FROM alpine AS sourceslock
RUN touch /sources.lock.repos

############################
# source: the checkout of SOURCE_REPO rooting the workspace. build_workspace.sh always
# overrides it via `--build-context source=<checkout>`; the empty default only serves builds
# that never reach fetch.
############################
FROM scratch AS source

############################
# fetch: the source checkout + its declared dependency repos (runtime input only)
############################
FROM ${ROS2_BASE_IMAGE} AS fetch
ARG SOURCE_REPO
ARG COMPILE_SOURCE=1
ARG CACHEBUST=none

WORKDIR ${ROS_WS}
RUN mkdir -p src
COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth
COPY --chmod=755 scripts/expand_repos.py /usr/local/bin/duatic-expand-repos
COPY --from=sourceslock /sources.lock.repos /tmp/sourceslock.repos
COPY --from=source / /tmp/source/

# duatic-with-github-auth authenticates every github.com clone below with the token secret,
# which is mounted only for this layer and never persisted (see scripts/github_auth.sh).
# --require: these repos are private, so anonymous cannot work. Two source paths:
#   - normal (/tmp/sourceslock.repos empty): `vcs import` the source checkout's repos.list,
#     which may list nothing: the everyday "whatever the branches are right now" path.
#     duatic-expand-repos first follows the repos.list of every listed repository, and
#     fails the build when two of them pin the same repository differently. With
#     COMPILE_SOURCE=0 the checkout itself stays out of src/, so neither the pin nor the
#     compile holds it; manifests adds its manifests for dependency resolution.
#   - release (sourceslock overridden): `vcs import` directly from that pinned, SHA-exact
#     manifest instead — no repos.list read, no branch tracking.
# In every case, `vcs export --exact` writes the manifest actually used to sources.lock.repos,
# which workspace/dev copy in at /etc/duatic/sources.lock.repos: for the normal path
# that is this build's OWN pin (what makes any nightly image reproducible later); for the
# release path it reproduces the input unchanged.
#
# A second, PLAIN `vcs export` (no --exact) also runs, into sources.repos: on the normal
# path `vcs import` leaves each repo checked out ON its branch (not detached), so this
# reports the actual branch names (main, master, whatever repos.list said) instead of SHAs,
# for an editable, branch-tracking manifest: `version: main` -> a feature branch remains a
# normal edit instead of starting from a frozen pin. (On the release path every repo IS detached at a pinned SHA, so this
# second file just echoes the same SHAs — harmless, and unused there: a release isn't
# something you clone-and-edit.)
RUN --mount=type=secret,id=GIT_AUTH_TOKEN,required \
    duatic-with-github-auth --require bash -c 'set -euo pipefail; \
    echo "cachebust: ${CACHEBUST}"; \
    if [ -s /tmp/sourceslock.repos ]; then \
        echo "fetch: importing the pinned sources.lock.repos (release build)"; \
        vcs import src < /tmp/sourceslock.repos --skip-existing; \
    else \
        if [ "${COMPILE_SOURCE}" = 1 ]; then cp -a /tmp/source "src/${SOURCE_REPO}"; fi; \
        if [ -f /tmp/source/repos.list ]; then \
            duatic-expand-repos /tmp/source/repos.list \
                --exclude-url "https://github.com/Duatic/${SOURCE_REPO}.git" > /tmp/upstream.repos; \
            vcs import src < /tmp/upstream.repos --skip-existing; \
        fi; \
    fi; \
    vcs export --exact src > sources.lock.repos; \
    vcs export src > sources.repos'

############################
# manifests: only the dependency manifests, which the dependency-resolution layers need
############################
FROM alpine AS manifests
ARG SOURCE_REPO
WORKDIR /src
COPY --from=fetch /ros2_ws/src/ /src/
COPY --from=source / /src/${SOURCE_REPO}/
RUN find . -type f ! -name 'package.xml' ! -name 'Aptfile' ! -name 'requirements.txt' -delete \
    && find . -type d -empty -delete

############################
# workspace: the full workspace, compiled at /opt/duatic/ws
#
# Dependency resolution here is LENIENT. A missing dependency is recorded in (/etc/duatic/unresolved-rosdep.txt,
# /etc/duatic/unresolved-deps.txt),
# The colcon build itself is NOT lenient: if it fails runtime cannot be built.
############################
FROM ${ROS2_BASE_IMAGE} AS workspace
ARG CACHEBUST=none
# Packages built at once.
ARG PARALLEL_WORKERS=4
# Make jobs per package. colcon bounds only packages, so concurrent compilers is the
# product of the two; size it against DIND_MEMORY_LIMIT in duatic_computer_setup.
ARG INNER_JOBS=1
ENV DUATIC_WS=/opt/duatic/ws
WORKDIR ${DUATIC_WS}

COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth

# Resolve deps. The manifests serve only this; the compile below sees exactly fetch's sources.
COPY --from=manifests /src/ ${DUATIC_WS}/src/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    duatic-rosdep-install src "$ROS_DISTRO" && \
    duatic-with-github-auth duatic-install-extra-deps src --lenient && \
    apt-get clean && rm -rf /var/lib/apt/lists/* src

# Colcon build. Vendor packages fetch their upstream from github.com at build time (CMake
# FetchContent/ExternalProject), which is why it goes through duatic-with-github-auth.
COPY --from=fetch /ros2_ws/src/ ${DUATIC_WS}/src/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    . /opt/ros/$ROS_DISTRO/setup.sh && \
    export CMAKE_PREFIX_PATH=/usr/local:$CMAKE_PREFIX_PATH \
           MAKEFLAGS="-j${INNER_JOBS}" \
           CMAKE_BUILD_PARALLEL_LEVEL="${INNER_JOBS}" && \
    echo "build limits: workers=${PARALLEL_WORKERS} inner=${INNER_JOBS} nproc=$(nproc) MAKEFLAGS=${MAKEFLAGS}" && \
    duatic-with-github-auth colcon build --continue-on-error --mixin release ccache \
        --parallel-workers "${PARALLEL_WORKERS}"

# Keep only the compiled install/, and make room for the source pin copied in next.
RUN rm -rf ${DUATIC_WS}/build ${DUATIC_WS}/log ${DUATIC_WS}/src && mkdir -p /etc/duatic

# Exact source pin this workspace was built from (see fetch above), carried into runtime (via
# its FROM chain) and dev (copied again below, since a lean dev never goes through this
# stage) at a fixed path so `duatic-doctor` and dev_workspace can always find it.
COPY --from=fetch /ros2_ws/sources.lock.repos /etc/duatic/sources.lock.repos

############################
# underlay: the prebuilt workspace dev copies in, or nothing for a lean dev
############################
FROM alpine AS no-underlay
RUN mkdir -p /opt/duatic/ws

# hadolint ignore=DL3006
FROM ${UNDERLAY_REF} AS underlay

############################
# dev: PUBLISHED. ros2-dev + the workspace's deps (LENIENT) + the prebuilt workspace when it compiled.
############################
FROM ${ROS2_DEV_IMAGE} AS dev
ARG CACHEBUST=none
ARG IMAGE_NAME=""
ARG IMAGE_DATE=""
# 1 only when UNDERLAY_REF is workspace, i.e. this image ships the prebuilt
# /opt/duatic/ws/install underlay; 0 for the lean fallback. Informational (dev_workspace).
ARG DUATIC_UNDERLAY=0
ENV DUATIC_IMAGE_NAME=${IMAGE_NAME} \
    DUATIC_IMAGE_VERSION=${IMAGE_DATE} \
    DUATIC_UNDERLAY=${DUATIC_UNDERLAY}
WORKDIR ${ROS_WS}

# Exact source pin + its branch-tracking companion (see fetch above): sources.repos keeps
# branch names (editable), sources.lock.repos exact SHAs (duatic-doctor, dev_workspace,
# reproducibility tooling).
RUN mkdir -p /etc/duatic
COPY --from=fetch /ros2_ws/sources.lock.repos /etc/duatic/sources.lock.repos
COPY --from=fetch /ros2_ws/sources.repos /etc/duatic/sources.repos

COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth

# Resolve deps: the same manifests workspace resolved, so the underlay's libraries are present.
# LENIENT: a missing dependency is recorded in /etc/duatic/unresolved-{rosdep,deps}.txt.
# The deps stamp is written only for a complete install, so duatic-deps --if-changed retries the rest.
COPY --from=manifests /src/ ${ROS_WS}/src/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    duatic-rosdep-install src "$ROS_DISTRO" && \
    duatic-with-github-auth duatic-install-extra-deps src --lenient && \
    { [ -s /etc/duatic/unresolved-rosdep.txt ] || [ -s /etc/duatic/unresolved-deps.txt ] || \
      duatic-deps --list src > /etc/duatic/deps.stamp; } && \
    rm -rf ~/.config/ros.org/rqt_gui* && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=underlay /opt/duatic/ws /opt/duatic/ws

############################
# ci: workspace + the STRICT dependency quality gate.
# Published by CI builds, which build and test their repository on top; runtime builds on it.
############################
FROM workspace AS ci
ENV ROS_WS=/opt/duatic/ws

# Quality gate: workspace resolves both rosdep keys and the Aptfile/requirements.txt
# manifests LENIENTLY; robots must not ship with any dependency unresolved.
RUN for m in unresolved-rosdep unresolved-deps; do \
        if [ -s "/etc/duatic/${m}.txt" ]; then \
            echo "gate: ${m}, robots must not ship incomplete:" >&2; \
            cat "/etc/duatic/${m}.txt" >&2; \
            exit 1; \
        fi; \
    done

COPY --chmod=755 config/runtime_entrypoint.sh /root/ros_entrypoint.sh

ENTRYPOINT [ "/root/ros_entrypoint.sh" ]
CMD [ "/bin/bash" ]

############################
# runtime: ci + the robot's image name and workspace layout.
# Workspace lives at /opt/duatic/ws; ROS_WS is repointed there and /ros2_ws kept as a back-compat symlink
############################
FROM ci AS runtime
ARG IMAGE_NAME
ENV DUATIC_IMAGE_NAME=${IMAGE_NAME}
WORKDIR ${ROS_WS}

RUN ln -s /opt/duatic/ws /ros2_ws
