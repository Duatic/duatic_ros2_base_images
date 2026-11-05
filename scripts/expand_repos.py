#!/usr/bin/env python3
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

"""Resolve the repository set a workspace is built from, every git repository pinned to a commit.

REPOS_FILE is the root repository's repos.list (missing: the root builds on its own). It is merged
with every repos.list its git repositories carry, recursively, each read at the version that entry
names. Two lists naming the same repository key must agree on its type, url and version, and one
url may not appear under two keys; either is an error that names both lists. Each git repository
is pinned to the commit its version names right now.

Usage:  expand_repos.py REPOS_FILE --root NAME URL COMMIT BRANCH --out DIR [--locked]

Writes, ready for `vcs import`:
  DIR/upstream.repos       the pinned repositories, without the root: what the build imports
  DIR/sources.lock.repos   the root at COMMIT and the pinned repositories: the exact source pin
  DIR/sources.repos        the root at BRANCH and every repository at the version its list names:
                           an editable, branch-tracking manifest

--locked takes REPOS_FILE as the sources.lock.repos of an earlier build, to reproduce it: nothing
is expanded or pinned again, the root (matched by URL) is left out of upstream.repos, and both
manifests repeat REPOS_FILE.
"""

import argparse
import os
import subprocess
import tempfile
from collections import deque

import yaml

NESTED = "repos.list"


def normalized_url(url):
    """The url without case, a trailing slash or .git, so spellings of one repository compare equal."""
    url = url.rstrip("/").lower()
    return url[: -len(".git")] if url.endswith(".git") else url


def spec(entry):
    """What two lists naming the same repository key have to agree on."""
    return entry.get("type"), normalized_url(entry.get("url", "")), str(entry.get("version", ""))


def repositories(text):
    """The repositories mapping of a repos file's text."""
    return (yaml.safe_load(text) or {}).get("repositories") or {}


def resolve(url, version):
    """The commit a git repository's version names, and the repos.list text it carries there.

    Args:
        url: the repository to fetch from.
        version: a branch, tag or commit.

    Returns:
        (commit, text), text None when the repository carries no repos.list.
    """
    with tempfile.TemporaryDirectory() as tmp:

        def git(*args):
            """Run git in the scratch repository, failing with the fetched url in the message."""
            r = subprocess.run(["git", *args], cwd=tmp, capture_output=True, text=True)
            if r.returncode:
                raise SystemExit(f'{url}@{version}: git {" ".join(args)}: {r.stderr.strip()}')
            return r.stdout

        git("init", "-q")
        git("remote", "add", "origin", url)
        # A partial clone fetches commit and trees only; git show then downloads the one blob read.
        git("config", "remote.origin.promisor", "true")
        git("config", "remote.origin.partialclonefilter", "blob:none")
        git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", version)
        commit = git("rev-parse", "FETCH_HEAD").strip()
        if not git("ls-tree", "FETCH_HEAD", NESTED).strip():
            return commit, None
        return commit, git("show", f"FETCH_HEAD:{NESTED}")


def expand(repos, root_url):
    """Merge repos with the lists its git repositories carry, pinning each git repository.

    Args:
        repos: the repositories mapping of the root's repos.list.
        root_url: the root repository's normalized url, left out wherever a list names it.

    Returns:
        (merged, pinned): the repositories at the versions their lists name, and the same with
        every git repository's version replaced by its commit.
    """
    queue = deque([(NESTED, repos)])
    merged, pinned, named_by, key_of_url = {}, {}, {}, {}
    while queue:
        origin, repos = queue.popleft()
        for key, entry in repos.items():
            if normalized_url(entry.get("url", "")) == root_url:
                continue
            if key in merged:
                if spec(merged[key]) != spec(entry):
                    first, second = merged[key], entry
                    raise SystemExit(
                        f"conflicting entries for {key}:\n"
                        f'  {named_by[key]}: {first.get("url")} @ {first.get("version")}\n'
                        f'  {origin}: {second.get("url")} @ {second.get("version")}'
                    )
                continue
            url = normalized_url(entry.get("url", ""))
            if url in key_of_url:
                other = key_of_url[url]
                raise SystemExit(
                    f'{entry.get("url")} is named both {other} ({named_by[other]}) and {key} ({origin})'
                )
            merged[key], named_by[key], key_of_url[url] = entry, origin, key
            if entry.get("type") != "git":
                pinned[key] = entry
                continue
            commit, text = resolve(entry["url"], str(entry.get("version") or "HEAD"))
            pinned[key] = {**entry, "version": commit}
            if text is not None:
                queue.append((f"{key}/{NESTED}", repositories(text)))
    return merged, pinned


def write(path, repos):
    """Write a repositories mapping as a repos file."""
    with open(path, "w") as f:
        yaml.safe_dump({"repositories": repos}, f, sort_keys=False, default_flow_style=False)


def main():
    """Write the three repos files, or exit with the first conflict found."""
    ap = argparse.ArgumentParser()
    ap.add_argument("repos_file")
    ap.add_argument("--root", nargs=4, required=True, metavar=("NAME", "URL", "COMMIT", "BRANCH"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--locked", action="store_true")
    args = ap.parse_args()
    name, url, commit, branch = args.root
    root_url = normalized_url(url)

    repos = {}
    if os.path.exists(args.repos_file):
        with open(args.repos_file) as f:
            repos = repositories(f.read())

    if args.locked:
        upstream = {k: e for k, e in repos.items() if normalized_url(e.get("url", "")) != root_url}
        write(os.path.join(args.out, "upstream.repos"), upstream)
        write(os.path.join(args.out, "sources.lock.repos"), repos)
        write(os.path.join(args.out, "sources.repos"), repos)
        return

    merged, pinned = expand(repos, root_url)
    root = {"type": "git", "url": url}
    write(os.path.join(args.out, "upstream.repos"), pinned)
    write(
        os.path.join(args.out, "sources.lock.repos"), {name: {**root, "version": commit}, **pinned}
    )
    write(os.path.join(args.out, "sources.repos"), {name: {**root, "version": branch}, **merged})


if __name__ == "__main__":
    main()
