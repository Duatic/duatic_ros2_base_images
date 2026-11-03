# syntax=docker/dockerfile:1
# Copyright 2026 Duatic AG
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that
# the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and
#    the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and
#    the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or
#    promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Duatic ROS 2 base images, multi-arch (linux/amd64, linux/arm64).
#
# Targets:
#   base  ROS desktop-full + build toolchain + global pip venv + colcon mixins
#   dev   base + developer tooling, shell setup and the UID-remapping entrypoint
#
# Build args:
#   ROS_DISTRO  humble | jazzy | kilted | lyrical | rolling (selects one of the ros-<distro> stages)
#   CACHEBUST   bump to force a fresh apt-get update/upgrade
#   IMAGE_VERSION  shown in the dev prompt and by duatic-doctor
#
#   docker buildx build -f docker/base.Dockerfile --build-arg ROS_DISTRO=jazzy --target dev .

ARG ROS_DISTRO=jazzy

# One literal FROM per distro, pinned by digest so Dependabot can bump them.
FROM docker.io/library/ros:humble-ros-base@sha256:d9bcf2e6f72df127fdee07048c2e87b1b4b9a59a74af0592f4489fc2844aa855 AS ros-humble
FROM docker.io/library/ros:jazzy-ros-base@sha256:8eed0a4669bbf43ee331878a4c39bd8ebddea8e3312a58b4fae8edb14526b617 AS ros-jazzy
FROM docker.io/library/ros:kilted-ros-base@sha256:ead7117130ebf582faf4b75eaf8128d598df9de705d53ee40bffe020a04ac0a6 AS ros-kilted
FROM docker.io/library/ros:lyrical-ros-base@sha256:3224ee150cb02eb89a5e0811bc267b57ed3a91b9c10191df57810726a7e916d7 AS ros-lyrical
FROM docker.io/library/ros:rolling-ros-base@sha256:fd1a2cf7995148ad54d29fbf452b9084b9b8a386ee36ee8241495410903a58cf AS ros-rolling

############################
# base: ROS desktop-full + build toolchain + colcon mixins.
############################
# hadolint ignore=DL3006
FROM ros-${ROS_DISTRO} AS base
ARG CACHEBUST=none
SHELL ["/bin/bash", "-c"]
# Every pip-installed python dep lives in ONE global venv (created below). PATH makes pip3/python3
# resolve to it; PYTHONPATH makes the SYSTEM interpreter (ros2, colcon, ament_*) see it too.
# Resulting precedence: workspace install/ -> /opt/ros/$ROS_DISTRO -> venv -> apt dist-packages.
ENV SHELL=/bin/bash \
    TZ=Europe/Berlin \
    ROS_WS=/ros2_ws \
    COLCON_HOME=/etc/colcon \
    DEBIAN_FRONTEND=noninteractive \
    VIRTUAL_ENV=/opt/duatic/venv \
    PATH=/opt/duatic/venv/bin:$PATH \
    PYTHONPATH=/opt/duatic/venv/site-packages \
    PIP_CONSTRAINT=/etc/duatic/pip-constraints.txt

# ROS desktop-full + build tooling
# hadolint ignore=DL3008
RUN echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ros-$ROS_DISTRO-desktop-full \
    git git-lfs wget ca-certificates ccache build-essential python3-pip python3-venv \
    python3-vcs2l python3-colcon-common-extensions python3-colcon-mixin \
    ros-$ROS_DISTRO-rmw-cyclonedds-cpp \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pins numpy to the apt version the ROS C extensions are built against, for every pip install.
RUN mkdir -p /etc/duatic && \
    python3 -c 'import numpy; print(f"numpy=={numpy.__version__}")' > "$PIP_CONSTRAINT"

# The global venv. ROS ships rclpy/ament_*/numpy as apt packages, and an isolated venv would break `import rclpy`.
# With --system-site-packages, pip only installs what apt does not already satisfy,
# and can shadow a too-old apt version WITHOUT uninstalling it.
# The site-packages symlink keeps the PYTHONPATH above independent of the python minor version
RUN python3 -m venv --system-site-packages "$VIRTUAL_ENV" && \
    ln -s "$("$VIRTUAL_ENV"/bin/python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" \
        "$VIRTUAL_ENV/site-packages" && \
    chmod -R a+rX /opt/duatic

# Colcon mixins, vendored from colcon/colcon-mixin-repository (see README to refresh them).
COPY config/colcon_mixins/ ${COLCON_HOME}/mixin/default/
RUN chmod -R a+rX ${COLCON_HOME}

RUN git config --system --add safe.directory '*'

# Install a workspace's declared dependencies (rosdep keys, Aptfile, requirements.txt), recording
# what could not be resolved under /etc/duatic/.
COPY --chmod=755 scripts/rosdep_install.sh /usr/local/bin/duatic-rosdep-install
COPY --chmod=755 scripts/install_product_deps.sh /usr/local/bin/duatic-install-product-deps

############################
# dev: base + developer tooling + dev-container shell environment.
############################
FROM base AS dev
ARG CACHEBUST=none
ARG IMAGE_VERSION=""
ENV DUATIC_DEV_CONTAINER=true \
    DUATIC_PRODUCT="" \
    DUATIC_IMAGE_VERSION=${IMAGE_VERSION} \
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    CYCLONEDDS_URI=file:///etc/cyclonedds.xml \
    ROS_AUTOMATIC_DISCOVERY_RANGE=SUBNET \
    SHELL=/usr/local/bin/duatic-shell
WORKDIR ${ROS_WS}

# Developer tooling. The packages in the loop are best-effort: not every distro ships them.
# hadolint ignore=DL3008
RUN echo "cachebust: ${CACHEBUST}" && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    apt-transport-https unzip gpg black socat gh bash-completion \
    clangd clang-format pre-commit sudo gosu libcap2-bin \
    pipx gdb xterm x11-apps && \
    for pkg in \
        clang-format-20 \
        ros-$ROS_DISTRO-rqt-runtime-monitor ros-$ROS_DISTRO-rqt-robot-monitor \
        ros-$ROS_DISTRO-plotjuggler ros-$ROS_DISTRO-plotjuggler-ros \
        ros-$ROS_DISTRO-rosbridge-suite ros-$ROS_DISTRO-ros2controlcli \
        ros-$ROS_DISTRO-behaviortree-cpp; do \
        apt-get install -y --no-install-recommends "$pkg" || \
            echo "WARNING: dev tooling package '$pkg' not available for ROS distro '$ROS_DISTRO', skipping." >&2; \
    done && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Keep downloaded packages so a container can mount /var/cache/apt as a cache.
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/keep-cache

# duatic-deps installs a workspace's declared dependencies into the running container;
# duatic-doctor diagnoses capabilities, groups, devices, DDS and unresolved deps.
COPY --chmod=755 scripts/duatic_deps.sh /usr/local/bin/duatic-deps
COPY --chmod=755 scripts/duatic_doctor.sh /usr/local/bin/duatic-doctor

# The entrypoint drops root to the host user, so a developer must be able to `pip3 install`.
# Non-recursive: a `chmod -R` would copy every installed file into a new layer.
RUN chmod a+rwX "$VIRTUAL_ENV" "$VIRTUAL_ENV/bin" "$VIRTUAL_ENV/lib" \
    "$VIRTUAL_ENV"/lib/python*/ "$VIRTUAL_ENV/site-packages"
COPY --chmod=440 config/sudoers-duatic-venv /etc/sudoers.d/duatic-venv
COPY --chmod=440 config/sudoers-duatic-caps /etc/sudoers.d/duatic-caps

# Identity + capability tooling (see the config/bin/ headers):
#   duatic-sync-groups  make the host user a member of every device-owning group in /dev
#   duatic-exec         the one way anything enters this container as the host user
#   duatic-shell        $SHELL / login shell, reaches duatic-exec via sudo
COPY --chmod=755 config/bin/duatic-sync-groups config/bin/duatic-exec config/bin/duatic-shell \
    /usr/local/bin/
RUN echo /usr/local/bin/duatic-shell >>/etc/shells

# Shell environment: ROS overlay chain + venv, cb/cc build helpers, prompt, history.
COPY --chmod=644 config/profile.d/10-duatic-ros.sh \
    config/profile.d/20-duatic-workflow.sh config/profile.d/30-duatic-prompt.sh \
    config/profile.d/40-duatic-history.sh /etc/profile.d/
RUN { \
      echo ''; \
      echo '# Duatic: interactive non-login shells read only this file, so load the same drop-ins'; \
      echo '# /etc/profile.d gives login shells. All are self-guarded, so sourcing them twice is a no-op.'; \
      echo 'for _duatic_f in /etc/profile.d/bash_completion.sh /etc/profile.d/10-duatic-ros.sh /etc/profile.d/20-duatic-workflow.sh /etc/profile.d/30-duatic-prompt.sh /etc/profile.d/40-duatic-history.sh; do'; \
      echo '    [ -r "$_duatic_f" ] && . "$_duatic_f"'; \
      echo 'done'; \
      echo 'unset _duatic_f'; \
    } >>/etc/bash.bashrc && \
    rm -f /etc/skel/.bashrc  # would override the prompt and history set above

# DDS config + the UID-remapping entrypoint
COPY config/cyclonedds.xml /etc/cyclonedds.xml
COPY --chmod=755 config/dev_entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod a+r /etc/cyclonedds.xml

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "/bin/bash" ]
