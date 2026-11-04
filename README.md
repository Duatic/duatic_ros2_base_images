# duatic_ros2_base_images

Opinionated ROS 2 Docker images for robot software development, and the image factory that
builds the Duatic images of every repository that calls it on top of them.

- **Base images** (`ros2-base`, `ros2-dev`): generic, multi-arch, built and released by this
  repository. See [Using the dev image](#using-the-dev-image).
- **Workspace images** (`<name>`, `<name>-dev`, `<name>-ci`):
  built from the checkout of whichever repository calls this repository's reusable workflows.
  See [Workspace images](#workspace-images).

## Base images

Built for `linux/amd64` and `linux/arm64`.

| Image | Contents |
| --- | --- |
| `ghcr.io/duatic/ros2-base` | `ros:<distro>-ros-base` + `ros-<distro>-desktop-full` (rviz, rqt, Gazebo) + build toolchain (colcon, vcs, ccache, CycloneDDS) + a global pip venv + vendored colcon mixins + `duatic-rosdep-install` / `duatic-install-extra-deps` for installing a workspace's dependencies at build time. |
| `ghcr.io/duatic/ros2-dev` | `ros2-base` + developer tooling (gdb, clangd, clang-format, pre-commit, plotjuggler, rqt monitors, ...) + shell setup + an entrypoint that runs as the host user. |

Distros: `humble`, `jazzy`, `kilted`, `lyrical`, `rolling`.

Tags: `:<distro>` (latest release), `:<distro>-X.Y.Z` (immutable), `:<distro>-X.Y`, `:<distro>-X`.

### Using the dev image

```bash
docker run -it --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e HOST_USER="$USER" \
  -v "$PWD/src:/ros2_ws/src" \
  ghcr.io/duatic/ros2-dev:jazzy
```

With `HOST_UID` set, the entrypoint creates a matching user, makes it a member of every group
that owns a device under `/dev`, and drops root while keeping `CAP_NET_RAW` (EtherCAT without
root). Without `HOST_UID` the container runs as root.

To open further shells in a running container as the same user, use
`docker exec -it <container> duatic-exec bash`.

#### Shell

| Command | What it does |
| --- | --- |
| `cb` | `colcon build` with the `release ccache compile-commands` mixins. `cb s` adds `--symlink-install`, `cb upto P..` / `cb only P..` select packages (`*` wildcards allowed). Run `cb help` for the full list. |
| `cc` | Clean `build/`, `install/` and `log/` of the workspace. |
| `duatic-deps [--if-changed \| --list] [src]` | Install every dependency `src/` declares: rosdep keys, plus every `Aptfile` (apt) and `requirements.txt` (pip) at any depth. `--if-changed` skips the install when every manifest is already listed in `/etc/duatic/deps.stamp`, which every install without unresolved dependencies extends. Downloaded `.deb`s are kept, so `/var/cache/apt` can be mounted as a cache. `--list` prints those entries, for an image that installs a workspace's dependencies at build time to write. |
| `duatic-doctor` | Diagnose capabilities, device groups, `/run/udev`, DDS config and unresolved dependencies. |
| `duatic-exec` | Enter the container as the host user with device groups synced and `CAP_NET_RAW`. |
| `duatic-shell` | The container's `$SHELL`. Reaches `duatic-exec` through `sudo` for shells that start without it, such as VSCode terminals. |

The ROS environment is sourced in this order, last wins: `/opt/ros/<distro>`, then
`/opt/duatic/ws/install` (a prebuilt underlay, if a derived image adds one), then
`$ROS_WS/install` (default `/ros2_ws`). The prompt shows `user@<name>-<distro>-<version>`;
derived images set `DUATIC_IMAGE_NAME`.

DDS defaults to CycloneDDS on loopback (`/etc/cyclonedds.xml`). Set `CYCLONEDDS_IFACE` and
`CYCLONEDDS_PEER` to use another interface.

#### Python packages

pip installs into a global venv at `/opt/duatic/venv`, created with `--system-site-packages`
and activated through `VIRTUAL_ENV`, `PATH` and `PYTHONPATH`:

- pip cannot uninstall Debian-packaged files, so a system-wide install aborts whenever a
  requirement needs a newer version of an apt python package. In the venv, pip shadows it.
- `--system-site-packages` keeps `rclpy`, `ament_*` and numpy from apt visible, and pip skips
  requirements apt already satisfies.
- `PYTHONPATH` makes the venv visible to `/usr/bin/python3` tools such as `ros2` and `colcon`.
  Do not pip-install colcon.
- `PIP_CONSTRAINT` points at `/etc/duatic/pip-constraints.txt`, which pins numpy to the apt
  version. The ROS C extensions are built against that numpy, so a requirement that needs a
  different one fails to resolve instead of breaking `rclpy` at import.

`sudo pip3` targets the same venv.

### Building

```bash
# base + dev for jazzy, native architecture, loaded into the local image store
./scripts/build_base.sh --ros-distro jazzy

# arm64 on an amd64 host (needs QEMU binfmt, e.g. tonistiigi/binfmt)
./scripts/build_base.sh --ros-distro jazzy --platform linux/arm64

# multi-arch, pushed
./scripts/build_base.sh --ros-distro jazzy --platform linux/amd64,linux/arm64 --version 1.2.3 --push
```

Run `./scripts/build_base.sh --help` for all flags.

The `ros:<distro>-ros-base` parents are pinned by digest in `docker/base.Dockerfile`, one stage per
distro. Dependabot opens a pull request when a digest changes and requests review from the
code owners. Its commits are `fix(deps)`, so merged bumps go out with the next release as a
patch.

#### Colcon mixins

`config/colcon_mixins/` holds the mixin files from
[colcon/colcon-mixin-repository](https://github.com/colcon/colcon-mixin-repository), installed to
`$COLCON_HOME/mixin/default`. To refresh them, copy the `*.mixin` files from that repository over
the ones here.

## Workspace images

The factory keeps no list of repositories: a repository calls its reusable workflows, and the
factory builds the workspace that repository roots (the repository and everything its
`repos.list` collects) from its checkout, on top of the base images.
`<name>` is the calling repository's name without its `duatic_` prefix: `duatic_dynaarm`
publishes `ghcr.io/duatic/dynaarm`, the image its robots run, next to `dynaarm-dev` and
`dynaarm-ci`. Each image holds every distro; its tags start with the distro, like the base
images' (`dynaarm:jazzy-1.2.0`).

| Target | Image | Contents | Consumed by |
| --- | --- | --- | --- |
| `dev` | `ghcr.io/duatic/<name>-dev` | `ros2-dev` + the workspace's dependencies, resolved **leniently**. When the workspace compiled, it also ships that prebuilt install as an underlay at `/opt/duatic/ws/install`, which [dev_workspace](https://github.com/Duatic/dev_workspace) overlays with its `src/`. When it did not, `dev` falls back to a **lean** image without it, so developers are never blocked. `DUATIC_UNDERLAY` records which one you got, and `duatic-doctor` reports it. | Developers, via dev_workspace |
| `runtime` | `ghcr.io/duatic/<name>` | The compiled workspace on `ros2-base`, at `/opt/duatic/ws` (with a `/ros2_ws` symlink), and the robot entrypoint. An unresolved dependency **fails the build**: robots never ship incomplete. | Robots |
| `ci` | `ghcr.io/duatic/<name>-ci` | The workspace the repository roots, without the repository itself, behind the same strict gate as `runtime`. Private: it contains compiled private upstream code. | [ci-workflows](https://github.com/Duatic/ci-workflows), which builds and tests the repository on top |

`dev` and `runtime` share one compile of the workspace: the internal, never-published
`workspace` stage collects the repository's full repo set and runs `colcon build` once at
`/opt/duatic/ws`. `runtime` builds on top of it and `dev` copies its install in.

Tags:
- `runtime`, release: immutable `:<distro>-<version>`, and `:<distro>`, which points at the
  latest release. See [Releases of workspace images](#releases-of-workspace-images). Customer
  robots pin a `:<distro>-<version>` or track `:<distro>`.
- `runtime`, nightly: `:<distro>-nightly` (whatever the last nightly built, for integration
  robots) and immutable `:<distro>-YYYY-MM-DD`.
- `dev`: rolling `:<distro>` and immutable `:<distro>-YYYY-MM-DD`. A lean image publishes only
  as `:<distro>-YYYY-MM-DD`, so `:<distro>` stays on the last build whose workspace compiled.
- `ci`: `:<distro>-<commit>`.

### What makes up a workspace

The calling repository owns its composition. The factory takes its checkout and runs
`vcs import` over its `repos.list`, following the `repos.list` of every repository listed there
and failing when two of them pin the same repository differently (`scripts/expand_repos.py`).
A repository without a `repos.list` builds on its own.

Dependencies rosdep cannot resolve are declared in `requirements.txt` (pip) and `Aptfile` (apt)
files at any depth of the workspace, which `duatic-install-extra-deps` installs after rosdep.
Both passes in the `workspace` stage are **lenient**: unresolvable rosdep keys go to
`/etc/duatic/unresolved-rosdep.txt` and uninstallable manifests to
`/etc/duatic/unresolved-deps.txt`, without blocking the compile. Both files ship inside `dev`,
and the `ci` stage, which `runtime` builds on, fails when either is non-empty.

### Every image knows what it is made of

`dev`, `workspace` and `runtime` carry `/etc/duatic/sources.lock.repos`, the exact repo set
of the build with every entry pinned to a commit. Hand it to `vcs import`, or back to
`docker buildx build --target runtime --build-context sourceslock=<dir with that file>`, to
reconstruct the same source tree later.

`dev` also carries `/etc/duatic/sources.repos`, the same set with each `version:` left on the
branch it was checked out on, as a starting point for an editable manifest.

### Building workspace images locally

`--source` takes a checkout of the repository rooting the image, named after its `origin`
remote. The image holds the checkout as it is, uncommitted changes included.

```bash
# dev + runtime, sharing one workspace compile (what the nightly does)
./scripts/build_workspace.sh --source ../duatic_dynaarm --ros-distro jazzy

# a single target, or push to ghcr.io
./scripts/build_workspace.sh --source ../duatic_dxtr --ros-distro jazzy --target runtime
./scripts/build_workspace.sh --source ../duatic_dynaarm --ros-distro jazzy --target ci
./scripts/build_workspace.sh --source ../duatic_dynaarm --ros-distro jazzy --push
```

The private repositories need GitHub auth: `$GIT_AUTH_TOKEN`, or an existing `gh auth login`.
The same token authenticates the public clones the dependency and compile layers make (pip git
requirements, CMake `FetchContent`), since github.com throttles anonymous clones per source IP;
`scripts/github_auth.sh` documents the failure mode.

The parents are the base images of the release matching `$FACTORY_REF` (see
`scripts/image_env.sh`), which the workflows set to the ref they run from. Preset
`ROS2_BASE_IMAGE` / `ROS2_DEV_IMAGE` to build against other tags, such as unreleased base images.

`scripts/build_workspace.sh --help` lists every flag and the tags each target produces.

### Calling the factory

Every workspace image workflow is `workflow_call` and builds the image of the repository calling it.
They log in to Docker Hub first when the optional `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`
secrets are set, so `docker.io` pulls are rate-limited per account instead of per IP.

- [`nightly.yml`](.github/workflows/nightly.yml): dev and runtime per distro, in one job per
  distro. With `publish`, it also commits `<distro>-dev.svg` and `<distro>-runtime.svg` status
  badges to the caller's `image-badges` branch.

  ```yaml
  jobs:
    image:
      permissions:
        contents: write   # image-badges branch
        packages: write
      uses: Duatic/duatic_ros2_base_images/.github/workflows/nightly.yml@v1
      with:
        publish: ${{ github.event_name == 'schedule' || inputs.publish }}
      secrets: inherit
  ```
- [`build-image.yml`](.github/workflows/build-image.yml): one `target` (`dev`, `runtime`,
  `dev,runtime` for both sharing one compile, or `ci`) for one distro. It returns the ci image
  (`target: ci`) or the release image (`target: runtime` with a `version`) as its `image`
  output. Private repositories need the `GH_PAT` secret.
- [`release-image.yml`](.github/workflows/release-image.yml): see
  [Releases of workspace images](#releases-of-workspace-images).

The calling repositories need Write access to their image packages in GHCR.

### Releases of workspace images

`release-image.yml` (inputs `ros_distro`, `version`) builds `runtime` through `build-image.yml`
from the revision the calling repository runs on, refuses to run if `<name>:<distro>-<version>`
already exists, pushes it, moves `:<distro>` to it, tags the caller `release/<distro>/<version>`,
and attaches `sources.lock.repos` and a snapshot of what got installed (`dpkg -l`, `pip freeze`,
`ros2 pkg list`) to a GitHub Release on that tag. A repository dispatches it by hand: a
release is a deliberate act, separate from the nightly.

### Self-hosted runners

The workflows run on `ubuntu-latest` unless the caller passes another `runner`. Duatic's
self-hosted ARC runners (`runner: self-hosted`) host in-cluster pull-through registry
mirrors. When `$HOSTIP` (the node IP, from the Kubernetes downward API) is set,
`build_workspace.sh` renders [`docker/buildkitd.toml.tmpl`](docker/buildkitd.toml.tmpl) with it and
builds on a `docker-container` builder that pulls `docker.io` and `ghcr.io` through those
mirrors. Without `$HOSTIP`, pulls go direct.

`dev` and `runtime` reach the `workspace` stage by name through the shared BuildKit cache, so
every `build_workspace.sh` invocation must pass identical build args to it; see
`ensure_workspace_build()`.

## Releases

Releases use the changelog release workflows of
[Duatic/ci-workflows](https://github.com/Duatic/ci-workflows#changelog-releases). The version is
the highest `vX.Y.Z` tag.

1. Run the **Release** workflow from the Actions tab and pick the bump: `derived` (from the
   commits), `major`, `minor` or `patch`. It opens a draft `release: X.Y.Z` pull request that adds
   the next section to `CHANGELOG.rst`, with every commit since the last tag. `chore`, `ci`,
   `test` and `build` commits are left out of the notes; with nothing else since the last tag,
   there is nothing to release.
2. Merge the pull request. This pushes the multi-arch base images for every distro, then tags
   `vX.Y.Z`, moves `vX` to it and publishes the GitHub Release with that section as its notes.
   When a distro fails to publish, nothing is tagged.

A release ships the base images and the factory together: a repository calling the
factory at `@vX` builds on `ros2-base:<distro>-X`, at `@vX.Y.Z` on `ros2-base:<distro>-X.Y.Z`.
A factory called at a branch or commit builds on the latest release, `ros2-base:<distro>`.

Pull request titles must be conventional commits (`feat: ...`, `fix(dev): ...`), since `main`
is squash-merged and the changelog is built from them. Notes that should say more than a title
go under an `Upcoming changes` heading in `CHANGELOG.rst`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause, see [LICENSE](LICENSE). The vendored colcon mixins are CC0-1.0, from
[colcon/colcon-mixin-repository](https://github.com/colcon/colcon-mixin-repository).
