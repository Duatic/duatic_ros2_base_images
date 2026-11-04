# syntax=docker/dockerfile:1
#
# Duatic workspace images, multi-stage: the workspace a repository roots (the repository and
# everything its repos.list collects), on top of the published images of docker/base.Dockerfile:
# ros2-base (toolchain, venv, mixins, dependency scripts) and ros2-dev (developer tooling,
# shell environment, entrypoint).
#
# Published targets are ci, dev and runtime, layered so that the expensive part is shared:
#   ci        ros2-base + every dependency + the upstream repositories compiled. It does not
#             hold the root repository's sources, so it stays valid for every commit until the
#             root's dependency manifests or an upstream commit change. build_workspace.sh
#             publishes it under a key of everything it is built from and reuses it.
#   workspace ci + the root repository compiled into the same install (internal)
#   runtime   workspace + the strict dependency gate
#   dev       ros2-dev + the dependencies + workspace's install as an underlay
#
# Build args:
#   ROS2_BASE_IMAGE   public ros2-base image for the distro (fetch, ci)
#   ROS2_DEV_IMAGE    public ros2-dev image for the distro (dev)
#   UNDERLAY_REF      what dev copies /opt/duatic/ws from: `no-underlay` (default, lean) or
#                     `workspace`, which build_workspace.sh sets only when the workspace compiled.
#   IMAGE_NAME        image name of the source repository (e.g. dynaarm)
#   IMAGE_VERSION     what dev reports as DUATIC_IMAGE_VERSION: the release version, or the
#                     build date for a nightly
#   SOURCE_REPO       the repository rooting the workspace (e.g. duatic_dynaarm), whose
#                     checkout build_workspace.sh passes as the source build context (below)
#   SOURCE_COMMIT     the checkout's commit, and SOURCE_BRANCH its branch (the commit when
#                     detached): the root's entry in the source manifests
#   CACHEBUST         bump (e.g. to the date) to force a fresh clone, and a fresh
#                     apt-get update/upgrade in ci/dev
#
# The stages need a GitHub token, both for the private repos and to keep the public clones in
# the dependency/compile layers off the per-IP anonymous rate limit. Use
# scripts/build_workspace.sh rather than invoking buildx directly.

ARG ROS2_BASE_IMAGE=ghcr.io/duatic/ros2-base:jazzy
ARG ROS2_DEV_IMAGE=ghcr.io/duatic/ros2-dev:jazzy
ARG UNDERLAY_REF=no-underlay

############################
# sourceslock — optional pinned-manifest override for reproducible RELEASE builds. Empty
# (a zero-byte file) by default: resolve then pins the branches repos.list names. Rebuilding a
# release by hand overrides this whole stage via `--build-context sourceslock=<dir with a real
# sources.lock.repos at its root>`, the manifest a PREVIOUS build wrote, together with a
# checkout of the root at the commit it names: the rebuild reproduces the exact same source tree.
############################
FROM alpine AS sourceslock
RUN touch /sources.lock.repos

############################
# source: the checkout of SOURCE_REPO rooting the workspace. build_workspace.sh always
# overrides it via `--build-context source=<checkout>`.
############################
FROM scratch AS source

############################
# resolve: pin the repository set. duatic-expand-repos follows the repos.list of every listed
# repository, fails when two of them pin the same repository differently, and pins each to the
# commit its branch names right now. build_workspace.sh runs this stage on its own (target lock),
# keys the ci image on the result and passes it back in as the lock context, so every later
# stage builds exactly the commits the key names, however the branches move meanwhile.
############################
# A small image, not ros2-base: a run that reuses its ci image builds only these two stages.
# The tools sit in a stage of their own, so build_workspace.sh can rerun resolve uncached alone.
FROM alpine AS resolve-tools
RUN apk add --no-cache bash coreutils git py3-yaml

FROM resolve-tools AS resolve
ARG SOURCE_REPO
ARG SOURCE_COMMIT
ARG SOURCE_BRANCH
ARG CACHEBUST=none
COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth
COPY --chmod=755 scripts/expand_repos.py /usr/local/bin/duatic-expand-repos
COPY --from=sourceslock /sources.lock.repos /tmp/sourceslock.repos
# The wildcard makes the copy optional: a root without a repos.list builds on its own.
COPY --from=source /repos.lis[t] /tmp/source/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN,required \
    duatic-with-github-auth --require bash -c 'set -euo pipefail; \
    echo "cachebust: ${CACHEBUST}"; \
    : "${SOURCE_COMMIT:?build with scripts/build_workspace.sh}"; \
    mkdir -p /out; \
    root=("${SOURCE_REPO}" "https://github.com/Duatic/${SOURCE_REPO}.git" \
          "${SOURCE_COMMIT}" "${SOURCE_BRANCH:-${SOURCE_COMMIT}}"); \
    if [ -s /tmp/sourceslock.repos ]; then \
        duatic-expand-repos /tmp/sourceslock.repos --root "${root[@]}" --out /out --locked; \
    else \
        duatic-expand-repos /tmp/source/repos.list --root "${root[@]}" --out /out; \
    fi'

# lock: upstream.repos, sources.lock.repos and sources.repos at the root (see expand_repos.py).
FROM scratch AS lock
COPY --from=resolve /out/ /

############################
# fetch: the pinned upstream repositories
############################
FROM ${ROS2_BASE_IMAGE} AS fetch
ARG CACHEBUST=none
WORKDIR ${ROS_WS}
RUN mkdir -p src
COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth
COPY --from=lock /upstream.repos /tmp/upstream.repos
# duatic-with-github-auth authenticates every github.com clone with the token secret, which is
# mounted only for this layer and never persisted (see scripts/github_auth.sh).
# --require: these repos are private, so anonymous cannot work.
RUN --mount=type=secret,id=GIT_AUTH_TOKEN,required \
    duatic-with-github-auth --require bash -c 'set -euo pipefail; \
    echo "cachebust: ${CACHEBUST}"; \
    vcs import src < /tmp/upstream.repos'

############################
# sourcetree: the root's checkout without its .git
############################
FROM alpine AS sourcetree
COPY --from=source / /src/
RUN rm -rf /src/.git

############################
# manifests: only the dependency manifests, which the dependency-resolution layers need
############################
FROM alpine AS manifests
ARG SOURCE_REPO
WORKDIR /src
COPY --from=fetch /ros2_ws/src/ /src/
COPY --from=sourcetree /src/ /src/${SOURCE_REPO}/
RUN find . -type f ! -name 'package.xml' ! -name 'Aptfile' ! -name 'requirements.txt' -delete \
    && find . -type d -empty -delete

############################
# ci: PUBLISHED and shared. Every dependency of the workspace, the root's included, and the
# upstream repositories compiled at /opt/duatic/ws. CI builds and tests the root on top;
# workspace compiles it in.
#
# Dependency resolution here is LENIENT. A missing dependency is recorded in
# /etc/duatic/unresolved-rosdep.txt and /etc/duatic/unresolved-deps.txt, which runtime and the
# CI test gate on. The colcon build itself is NOT lenient: if it fails nothing builds on it.
############################
FROM ${ROS2_BASE_IMAGE} AS ci
ARG CACHEBUST=none
# Packages built at once.
ARG PARALLEL_WORKERS=4
# Make jobs per package. colcon bounds only packages, so concurrent compilers is the
# product of the two; size it against DIND_MEMORY_LIMIT in duatic_computer_setup.
ARG INNER_JOBS=1
ENV DUATIC_WS=/opt/duatic/ws
WORKDIR ${DUATIC_WS}

COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth
# This factory's duatic-deps, whose --gate runtime and the CI test run, whichever ros2-base
# release the image builds on.
COPY --chmod=755 scripts/duatic_deps.sh /usr/local/bin/duatic-deps

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

# Keep only the compiled install/.
RUN rm -rf ${DUATIC_WS}/build ${DUATIC_WS}/log ${DUATIC_WS}/src && mkdir -p /etc/duatic

# The pin of the upstream repositories compiled here; workspace replaces it with the full pin.
COPY --from=lock /upstream.repos /etc/duatic/sources.lock.repos

ENV ROS_WS=/opt/duatic/ws
COPY --chmod=755 config/runtime_entrypoint.sh /root/ros_entrypoint.sh
ENTRYPOINT [ "/root/ros_entrypoint.sh" ]
CMD [ "/bin/bash" ]

############################
# workspace: ci + the root repository compiled into the same install, at /opt/duatic/ws.
# build_workspace.sh replaces the ci stage with the published image when it reuses one.
############################
FROM ci AS workspace
ARG SOURCE_REPO
ARG PARALLEL_WORKERS=4
ARG INNER_JOBS=1

COPY --from=sourcetree /src/ ${DUATIC_WS}/src/${SOURCE_REPO}/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    . /opt/ros/$ROS_DISTRO/setup.sh && \
    if [ -f install/setup.sh ]; then . install/setup.sh; fi && \
    export CMAKE_PREFIX_PATH=/usr/local:$CMAKE_PREFIX_PATH \
           MAKEFLAGS="-j${INNER_JOBS}" \
           CMAKE_BUILD_PARALLEL_LEVEL="${INNER_JOBS}" && \
    duatic-with-github-auth colcon build --continue-on-error --mixin release ccache \
        --parallel-workers "${PARALLEL_WORKERS}" && \
    rm -rf build log src

# Exact source pin this workspace was built from (see resolve above), carried into runtime (via
# its FROM chain) and dev (copied again below, since a lean dev never goes through this
# stage) at a fixed path so `duatic-doctor` and dev_workspace can always find it.
COPY --from=lock /sources.lock.repos /etc/duatic/sources.lock.repos

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
# 1 only when UNDERLAY_REF is workspace, i.e. this image ships the prebuilt
# /opt/duatic/ws/install underlay; 0 for the lean fallback. Informational (dev_workspace).
ARG DUATIC_UNDERLAY=0
ENV DUATIC_IMAGE_NAME=${IMAGE_NAME} \
    DUATIC_UNDERLAY=${DUATIC_UNDERLAY}
WORKDIR ${ROS_WS}

# Exact source pin + its branch-tracking companion (see resolve above): sources.repos keeps
# branch names (editable), sources.lock.repos exact SHAs (duatic-doctor, dev_workspace,
# reproducibility tooling).
RUN mkdir -p /etc/duatic
COPY --from=lock /sources.lock.repos /sources.repos /etc/duatic/

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

# Last, so a release and a nightly of the same day share every layer above: a build arg is in
# the environment of every RUN after it.
ARG IMAGE_VERSION=""
ENV DUATIC_IMAGE_VERSION=${IMAGE_VERSION}

############################
# runtime: workspace + the STRICT dependency quality gate, the robot's image name and workspace layout.
# Workspace lives at /opt/duatic/ws (ci points ROS_WS there); /ros2_ws is kept as a back-compat symlink
############################
FROM workspace AS runtime
ARG IMAGE_NAME
ENV DUATIC_IMAGE_NAME=${IMAGE_NAME}
WORKDIR ${ROS_WS}

# Quality gate: ci resolves both rosdep keys and the Aptfile/requirements.txt manifests
# LENIENTLY; robots must not ship with any dependency unresolved.
RUN duatic-deps --gate

RUN ln -s /opt/duatic/ws /ros2_ws
