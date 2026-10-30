# duatic_ros2_base_images

Opinionated ROS 2 Docker images for robot software development, built for `linux/amd64` and
`linux/arm64`. Duatic product images build on top of them.

| Image | Contents |
| --- | --- |
| `ghcr.io/duatic/ros2-base` | `ros:<distro>-ros-base` + `ros-<distro>-desktop-full` (rviz, rqt, Gazebo) + build toolchain (colcon, vcs, ccache, CycloneDDS) + a global pip venv + vendored colcon mixins + `duatic-rosdep-install` / `duatic-install-product-deps` for installing a workspace's dependencies at build time. |
| `ghcr.io/duatic/ros2-dev` | `ros2-base` + developer tooling (gdb, clangd, clang-format, pre-commit, plotjuggler, rqt monitors, ...) + shell setup + an entrypoint that runs as the host user. |

Distros: `jazzy`, `kilted`, `lyrical`, `rolling`.

Tags: `:<distro>` (latest release), `:<distro>-X.Y.Z` (immutable), `:<distro>-X.Y`.

## Using the dev image

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

### Shell

| Command | What it does |
| --- | --- |
| `cb` | `colcon build` with the `release ccache compile-commands` mixins. `cb s` adds `--symlink-install`, `cb upto P..` / `cb only P..` select packages (`*` wildcards allowed). Run `cb help` for the full list. |
| `cc` | Clean `build/`, `install/` and `log/` of the workspace. |
| `duatic-deps [--if-changed \| --list] [src]` | Install every dependency `src/` declares: rosdep keys, plus every `Aptfile` (apt) and `requirements.txt` (pip) at any depth. `--if-changed` skips the install when every manifest is already listed in `/etc/duatic/deps.stamp`, which every install extends. `--list` prints those entries, for an image that installs a workspace's dependencies at build time to write. |
| `duatic-doctor` | Diagnose capabilities, device groups, `/run/udev`, DDS config and unresolved dependencies. |
| `duatic-exec` | Enter the container as the host user with device groups synced and `CAP_NET_RAW`. |
| `duatic-shell` | The container's `$SHELL`. Reaches `duatic-exec` through `sudo` for shells that start without it, such as VSCode terminals. |

The ROS environment is sourced in this order, last wins: `/opt/ros/<distro>`, then
`/opt/duatic/ws/install` (a prebuilt underlay, if a derived image adds one), then
`$ROS_WS/install` (default `/ros2_ws`). The prompt shows `user@<product>-<distro>-<version>`;
derived images set `DUATIC_PRODUCT`.

DDS defaults to CycloneDDS on loopback (`/etc/cyclonedds.xml`). Set `CYCLONEDDS_IFACE` and
`CYCLONEDDS_PEER` to use another interface.

### Python packages

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

## Building

```bash
# base + dev for jazzy, native architecture, loaded into the local image store
./scripts/build.sh --ros-distro jazzy

# arm64 on an amd64 host (needs QEMU binfmt, e.g. tonistiigi/binfmt)
./scripts/build.sh --ros-distro jazzy --platform linux/arm64

# multi-arch, pushed
./scripts/build.sh --ros-distro jazzy --platform linux/amd64,linux/arm64 --version 1.2.3 --push
```

Run `./scripts/build.sh --help` for all flags.

The `ros:<distro>-ros-base` parents are pinned by digest in `docker/Dockerfile`, one stage per
distro. Dependabot opens a pull request when a digest changes and requests review from the
code owners. Merged bumps go out with the next release as a patch, listed under
"Base Image Updates".

### Colcon mixins

`config/colcon_mixins/` holds the mixin files from
[colcon/colcon-mixin-repository](https://github.com/colcon/colcon-mixin-repository), installed to
`$COLCON_HOME/mixin/default`. To refresh them, copy the `*.mixin` files from that repository over
the ones here.

## Releases

1. Run the **Release** workflow from the Actions tab. It opens a `release: X.Y.Z` pull request
   that bumps `version.txt` and adds the `CHANGELOG.md` section. The bump comes from the
   conventional commit titles since the last tag: `feat` is minor, `!` or `BREAKING CHANGE` is
   major, and anything else is patch. A `Release-As: X.Y.Z` commit footer overrides it.
2. Merge the pull request. This tags `vX.Y.Z`, publishes the GitHub Release, and pushes the
   multi-arch images for every distro.

Pull request titles must be conventional commits (`feat: ...`, `fix(dev): ...`), since `main`
is squash-merged and the changelog is built from them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause, see [LICENSE](LICENSE). The vendored colcon mixins are CC0-1.0, from
[colcon/colcon-mixin-repository](https://github.com/colcon/colcon-mixin-repository).
