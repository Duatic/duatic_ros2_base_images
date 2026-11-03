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

"""Flatten a repos.list together with every repos.list its git repositories carry, recursively.

Each git entry's own repos.list is read at the version that entry pins. Two lists naming the same
repository key must agree on its type, url and version, and one url may not appear under two keys;
either is an error that names both lists. The merged list is printed as YAML, ready for `vcs import`.

Usage:  expand_repos.py REPOS_FILE [--exclude-url URL]

--exclude-url drops the repository being built, which a dependency's own list may name in turn.
"""

import argparse
import subprocess
import sys
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


def nested_list(url, version):
    """The repos.list text a git repository carries at version, or None when it carries none."""
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
        if not git("ls-tree", "FETCH_HEAD", NESTED).strip():
            return None
        return git("show", f"FETCH_HEAD:{NESTED}")


def main():
    """Print the merged repos list, or exit with the first conflict found."""
    ap = argparse.ArgumentParser()
    ap.add_argument("repos_file")
    ap.add_argument("--exclude-url", default="")
    args = ap.parse_args()
    exclude = normalized_url(args.exclude_url) if args.exclude_url else None

    with open(args.repos_file) as f:
        queue = deque([(args.repos_file, repositories(f.read()))])
    merged, named_by, key_of_url = {}, {}, {}
    while queue:
        origin, repos = queue.popleft()
        for key, entry in repos.items():
            if exclude and normalized_url(entry.get("url", "")) == exclude:
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
            if entry.get("type") == "git":
                text = nested_list(entry["url"], str(entry.get("version") or "HEAD"))
                if text is not None:
                    queue.append((f"{key}/{NESTED}", repositories(text)))

    yaml.safe_dump({"repositories": merged}, sys.stdout, sort_keys=False, default_flow_style=False)


if __name__ == "__main__":
    main()
