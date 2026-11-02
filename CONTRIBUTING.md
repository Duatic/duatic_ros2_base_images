# Contributing

We encourage community contributions to this repository. Feel free to open an issue or provide a pull request.

# Licensing

Any contribution to this repository will be under the BSD License.

## Pull requests

`main` is squash-merged, so the pull request title becomes the commit message and feeds the changelog.
Titles must be conventional commits, e.g. `feat: add foo to the dev image` or `fix(dev): ...`.
A `!` after the type marks a breaking change.

Image changes should be built locally before opening a pull request, e.g. `./scripts/build.sh --ros-distro jazzy`.

## Tooling

Please make sure for any pull request that it passes the `pre-commit` checks.

### pre-commit

The [pre-commit](https://pre-commit.com/) tool is used for running certain checks and formatters every time before a commit is done.
Please use it on any pull requests for this repository. It also runs automatically in CI via `.github/workflows/pre-commit.yml`.

__Installation:__

`apt install pipx && pipx install pre-commit`. Open a new terminal afterwards.

__Usage:__
In the repository folder run: `pre-commit run --all`. This can be automated with `pre-commit install`, so all checks are run every time a commit is done.
