# syntax=docker/dockerfile:1
#
# Duatic product images, multi-stage.
#
# Builds the product layer on top of the published images of docker/base.Dockerfile:
# ros2-base (toolchain, venv, mixins, dependency scripts) and ros2-dev (developer tooling,
# shell environment, entrypoint). Published targets are dev, runtime and ci; fetch, cacher and
# product-build are internal stages that let dev and runtime share ONE compile of the product stack.
#
# Build args:
#   ROS2_BASE_IMAGE   public ros2-base image for the distro (fetch, product-build, runtime)
#   ROS2_DEV_IMAGE    public ros2-dev image for the distro (dev)
#   UNDERLAY_REF      what dev copies /opt/duatic/ws from: `no-underlay` (default, lean) or
#                     `product-build` — build_product.sh sets the latter only when product-build succeeded.
#   RUNTIME_BASE_REF  what `ci` (and so `runtime`) builds FROM: the inline `product-build` stage.
#   PRODUCT           image name of the root repository (e.g. dynaarm)
#   PRODUCT_REPO      the repository rooting the workspace (e.g. duatic_dynaarm), whose
#                     checkout build_product.sh passes as the rootsrc build context (below)
#   ROOT_IN_STACK     1 (default): the root repository is compiled with its stack (dev,
#                     runtime). 0: it only contributes its dependency manifests (ci).
#   CACHEBUST         bump (e.g. to the date) to force a fresh clone, and a fresh
#                     apt-get update/upgrade in product-build/dev, on nightly builds
#
# dev/product-build/runtime need a GitHub token, both for the private repos and to keep the
# public clones in the dependency/compile layers off the per-IP anonymous rate limit. Use
# scripts/build_product.sh rather than invoking buildx directly.
#
# dev_workspace's clean local build overrides the cacher stage with the developer's local
# dependency manifests, which prunes fetch from the build graph (no token needed):
#   docker buildx build --target dev --build-context cacher=<dir with src/ manifests> ...
# (that path always yields a lean dev — there is no local source to colcon-build.)

ARG ROS2_BASE_IMAGE=ghcr.io/duatic/ros2-base:jazzy
ARG ROS2_DEV_IMAGE=ghcr.io/duatic/ros2-dev:jazzy
ARG UNDERLAY_REF=no-underlay
ARG RUNTIME_BASE_REF=product-build

############################
# sourceslock — optional pinned-manifest override for reproducible RELEASE builds. Empty
# (a zero-byte file) by default: a normal nightly/local build sees nothing here and fetch
# takes its usual branch-tracking path below. release-image.yml overrides this whole stage via
# `--build-context sourceslock=<dir with a real sources.lock.repos at its root>` — a
# SHA-exact manifest, itself produced by a PREVIOUS build's `vcs export --exact` (see fetch
# below) — so re-running the same release reproduces the exact same source tree instead of
# whatever `main` has drifted to since. Same override convention dev_workspace's clean local
# build already uses for the `cacher` stage below.
############################
FROM alpine AS sourceslock
RUN touch /sources.lock.repos

############################
# rootsrc: the checkout of PRODUCT_REPO rooting the workspace. build_product.sh always overrides it
# via `--build-context rootsrc=<checkout>`; the empty default only serves builds that never
# reach fetch.
############################
FROM scratch AS rootsrc

############################
# fetch: the root checkout + its declared dependency repos (runtime input only)
############################
FROM ${ROS2_BASE_IMAGE} AS fetch
ARG PRODUCT_REPO
ARG ROOT_IN_STACK=1
ARG CACHEBUST=none

WORKDIR ${ROS_WS}
RUN mkdir -p src
COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth
COPY --chmod=755 scripts/expand_repos.py /usr/local/bin/duatic-expand-repos
COPY --from=sourceslock /sources.lock.repos /tmp/sourceslock.repos
COPY --from=rootsrc / /tmp/rootsrc/

# duatic-with-github-auth authenticates every github.com clone below with the token secret,
# which is mounted only for this layer and never persisted (see scripts/github_auth.sh).
# --require: these repos are private, so anonymous cannot work. Two source paths:
#   - normal (/tmp/sourceslock.repos empty): `vcs import` the root checkout's repos.list,
#     which may list nothing: the everyday "whatever the branches are right now" path.
#     duatic-expand-repos first follows the repos.list of every listed repository, and
#     fails the build when two of them pin the same repository differently. With
#     ROOT_IN_STACK=0 the checkout itself stays out of src/, so neither the pin nor the
#     compile holds it; cacher adds its manifests for dependency resolution.
#   - release (sourceslock overridden): `vcs import` directly from that pinned, SHA-exact
#     manifest instead — no repos.list read, no branch tracking.
# In every case, `vcs export --exact` writes the manifest actually used to sources.lock.repos,
# which product-build/dev copy in at /etc/duatic/sources.lock.repos: for the normal path
# that is this build's OWN pin (what makes any nightly image reproducible later); for the
# release path it reproduces the input unchanged, which is the reproducibility guarantee
# release-image.yml checks.
#
# A second, PLAIN `vcs export` (no --exact) also runs, into sources.repos: on the normal
# path `vcs import` leaves each repo checked out ON its branch (not detached), so this
# reports the actual branch names (main, master, whatever repos.list said) instead of SHAs —
# dev_workspace's clone_repos.sh extracts THIS one into an editable, branch-tracking
# manifest, so `version: main` -> a feature branch remains a normal edit instead of starting
# from a frozen pin. (On the release path every repo IS detached at a pinned SHA, so this
# second file just echoes the same SHAs — harmless, and unused there: a release isn't
# something you clone-and-edit.)
RUN --mount=type=secret,id=GIT_AUTH_TOKEN,required \
    duatic-with-github-auth --require bash -c 'set -euo pipefail; \
    echo "cachebust: ${CACHEBUST}"; \
    if [ -s /tmp/sourceslock.repos ]; then \
        echo "fetch: importing the pinned sources.lock.repos (release build)"; \
        vcs import src < /tmp/sourceslock.repos --skip-existing; \
    else \
        if [ "${ROOT_IN_STACK}" = 1 ]; then cp -a /tmp/rootsrc "src/${PRODUCT_REPO}"; fi; \
        if [ -f /tmp/rootsrc/repos.list ]; then \
            duatic-expand-repos /tmp/rootsrc/repos.list \
                --exclude-url "https://github.com/Duatic/${PRODUCT_REPO}.git" > /tmp/upstream.repos; \
            vcs import src < /tmp/upstream.repos --skip-existing; \
        fi; \
    fi; \
    vcs export --exact src > sources.lock.repos; \
    vcs export src > sources.repos'

############################
# cacher — keeps the files the dep-resolution layers needs
############################
FROM alpine AS cacher
ARG PRODUCT_REPO
WORKDIR /src
COPY --from=fetch /ros2_ws/src/ /src/
COPY --from=rootsrc / /src/${PRODUCT_REPO}/
RUN find . -type f ! -name 'package.xml' ! -name 'Aptfile' ! -name 'requirements.txt' -delete \
    && find . -type d -empty -delete

############################
# product-build — the full product stack, compiled at /opt/duatic/ws
#
# Dependency resolution here is LENIENT. A missing dependency is recorded in (/etc/duatic/unresolved-rosdep.txt,
# /etc/duatic/unresolved-deps.txt),
# The colcon build itself is NOT lenient: if it fails runtime cannot be built.
############################
FROM ${ROS2_BASE_IMAGE} AS product-build
ARG PRODUCT_REPO
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
COPY --from=cacher /src/ ${DUATIC_WS}/src/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    duatic-rosdep-install src "$ROS_DISTRO" && \
    duatic-with-github-auth duatic-install-product-deps src --lenient && \
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

# Exact source pin this stack was built from (see fetch above) — carried into runtime (via
# its FROM chain) and dev (copied again below, since a lean dev never goes through this
# stage) at a fixed path so `duatic-doctor` and a developer's `clone_repos.sh` can always
# find it.
COPY --from=fetch /ros2_ws/sources.lock.repos /etc/duatic/sources.lock.repos

############################
# underlay — the prebuilt product stack dev copies in, or nothing for a lean dev
############################
FROM alpine AS no-underlay
RUN mkdir -p /opt/duatic/ws

# hadolint ignore=DL3006
FROM ${UNDERLAY_REF} AS underlay

############################
# dev — PUBLISHED. ros2-dev + product deps (LENIENT) + the prebuilt product stack when it compiled.
############################
FROM ${ROS2_DEV_IMAGE} AS dev
ARG PRODUCT_REPO=""
ARG CACHEBUST=none
ARG PRODUCT=""
ARG IMAGE_DATE=""
# 1 only when UNDERLAY_REF is product-build, i.e. this image ships the prebuilt
# /opt/duatic/ws/install underlay; 0 for the lean fallback. Informational (dev_workspace).
ARG DUATIC_UNDERLAY=0
ENV DUATIC_PRODUCT=${PRODUCT} \
    DUATIC_IMAGE_VERSION=${IMAGE_DATE} \
    DUATIC_UNDERLAY=${DUATIC_UNDERLAY}
WORKDIR ${ROS_WS}

# Exact source pin + its branch-tracking companion (see fetch above). dev_workspace's
# clone_repos.sh reads sources.repos (branch names, editable); duatic-doctor and
# reproducibility tooling read sources.lock.repos (exact SHAs).
RUN mkdir -p /etc/duatic
COPY --from=fetch /ros2_ws/sources.lock.repos /etc/duatic/sources.lock.repos
COPY --from=fetch /ros2_ws/sources.repos /etc/duatic/sources.repos

COPY --chmod=755 scripts/github_auth.sh /usr/local/bin/duatic-with-github-auth

# Resolve deps: the same manifests product-build resolved, so the underlay's libraries are present.
# LENIENT: a missing dependency is recorded in /etc/duatic/unresolved-{rosdep,deps}.txt.
# The deps stamp is written only for a complete install, so duatic-deps --if-changed retries the rest.
COPY --from=cacher /src/ ${ROS_WS}/src/
RUN --mount=type=secret,id=GIT_AUTH_TOKEN \
    echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    duatic-rosdep-install src "$ROS_DISTRO" && \
    duatic-with-github-auth duatic-install-product-deps src --lenient && \
    { [ -s /etc/duatic/unresolved-rosdep.txt ] || [ -s /etc/duatic/unresolved-deps.txt ] || \
      duatic-deps --list src > /etc/duatic/deps.stamp; } && \
    rm -rf ~/.config/ros.org/rqt_gui* && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=underlay /opt/duatic/ws /opt/duatic/ws

############################
# ci: (product-build, inline or reused from the same build_product.sh run) + the STRICT dependency quality gate.
# Published by CI builds, which build and test their repository on top; runtime builds on it.
############################
FROM ${RUNTIME_BASE_REF} AS ci
ENV ROS_WS=/opt/duatic/ws

# Quality gate: product-build resolves both rosdep keys and the Aptfile/requirements.txt
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
# runtime: ci + the robot's product and workspace layout.
# Workspace lives at /opt/duatic/ws; ROS_WS is repointed there and /ros2_ws kept as a back-compat symlink
############################
FROM ci AS runtime
ARG PRODUCT
ENV PRODUCT=${PRODUCT}
WORKDIR ${ROS_WS}

RUN ln -s /opt/duatic/ws /ros2_ws
