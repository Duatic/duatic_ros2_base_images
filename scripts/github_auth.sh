#!/usr/bin/env bash
set -euo pipefail

# Run a command with every github.com clone it makes authenticated by the GIT_AUTH_TOKEN
# build secret.
#
#   github_auth.sh [--require] <command> [args...]
#
# github.com throttles ANONYMOUS clones per source IP, and the nightly builds of every calling
# repository (every distro, on the self-hosted runners, sharing one IP) exhaust
# that budget: the clone is
# then refused outright, with either
#
#   fatal: remote error: GitHub is temporarily limiting some unauthenticated downloads ...
#
# or a 401, which git reports as the far more confusing
#
#   fatal: could not read Username for 'https://github.com': No such device or address
#
# An authenticated clone draws on the token's own, far larger budget instead. That covers
# PUBLIC repos too: a pip requirement pointing at a git repo (and the git requirements that
# one in turn declares) and a CMake FetchContent clone are as exposed as a private clone is.
#
# Wrapping a COMMAND, rather than authenticating at each call site, is what reaches those
# clones: they happen inside pip, colcon and CMake, at a depth the Dockerfile cannot address.
#
# Auth is an `http.<url>.extraheader`, the mechanism actions/checkout uses, and it has to be:
# the header is sent preemptively, whereas credentials embedded in a rewritten clone URL are
# offered only once the server has answered 401, and a throttled GitHub refuses the request
# without ever issuing that challenge.
#
# The token is read from the /run/secrets/GIT_AUTH_TOKEN mount, never from a build arg, and
# the config it writes is removed when the command returns, so no image layer keeps it.
#
#   --require   fail when the secret is missing or empty. For layers that clone PRIVATE repos
#               (fetch), where anonymous cannot work anyway. Without it a missing secret
#               degrades to anonymous clones, which is what dev_workspace's tokenless local
#               dev build relies on.

REQUIRE=0
if [[ "${1:-}" == "--require" ]]; then
    REQUIRE=1
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") [--require] <command> [args...]" >&2
    exit 2
fi

SECRET=/run/secrets/GIT_AUTH_TOKEN
TOKEN=""
if [[ -r "$SECRET" ]]; then
    RAW=$(cat "$SECRET")
    TOKEN="${RAW#GIT_AUTH_TOKEN=}"
fi

# Never let git fall back to an interactive prompt: without a tty that is what turns a plain
# 401 into the misleading "could not read Username" above.
export GIT_TERMINAL_PROMPT=0

if [[ -z "$TOKEN" ]]; then
    if [[ "$REQUIRE" == "1" ]]; then
        echo "github_auth: no GitHub token in ${SECRET}. Pass --secret id=GIT_AUTH_TOKEN,env=GIT_AUTH_TOKEN." >&2
        exit 1
    fi
    echo "WARNING: github_auth: no GitHub token, so github.com clones will be anonymous and rate-limited." >&2
    exec "$@"
fi

SECTION='http.https://github.com/'

# cleanup: drop the credentials again, on success and on failure alike.
cleanup() { git config --global --remove-section "$SECTION" 2>/dev/null || true; }
trap cleanup EXIT

git config --global "${SECTION}.extraheader" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
"$@"
