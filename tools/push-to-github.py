#!/usr/bin/env python3
"""Push the repository to GitHub with the Git Data API.

    python3 tools/push-to-github.py [repo] [branch]

Why the API and not `git push`: the machine this was written on has a
PortableGit without `git-remote-https`, so `git clone` and `git push` over
HTTPS fail with "git: 'remote-https' is not a git command". The API works.

Why not one `PUT` per file: the Contents API needs a request per path, and a
commit per file unless the file already exists with a known sha. The Git Data
API takes the whole tree in one call -- one blob per file, one tree, one
commit -- which is both faster and atomic: the branch moves once, to a tree
that is complete.

The token comes from the environment:

    GITHUB_TOKEN=ghp_... python3 tools/push-to-github.py
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = "https://api.github.com"

# The engine is upstream's and the CI fetches it; the build products are
# products. Everything here is in `.gitignore` too, but the filter is
# applied here as well so that the script never depends on git being
# installed to do the right thing.
EXCLUDE_PREFIXES = ("engine/",)
EXCLUDE_DIRS = {".git", "build", "DerivedData", "__pycache__"}
EXCLUDE_NAMES = {".DS_Store"}


def api(url: str, method: str = "GET", body=None):
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("GITHUB_TOKEN is not set", file=sys.stderr)
        sys.exit(1)
    headers = {
        "User-Agent": "spektralab-ios-push",
        "Authorization": f"token {token}",
        "Content-Type": "application/json",
        "Accept": "application/vnd.github+json",
    }
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:800]
        print(f"{method} {url}\n  -> HTTP {error.code}\n  -> {detail}", file=sys.stderr)
        raise


def files() -> list[tuple[str, bytes]]:
    """Every file to push, as (path, bytes)."""
    out: list[tuple[str, bytes]] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        parts = path.relative_to(ROOT).parts
        if parts[0] in EXCLUDE_DIRS:
            continue
        if any(part in EXCLUDE_DIRS for part in parts[:-1]):
            continue
        if path.name in EXCLUDE_NAMES or path.name.endswith(".pyc"):
            continue
        if relative.startswith(EXCLUDE_PREFIXES):
            continue
        out.append((relative, path.read_bytes()))
    return out


def ensure_not_empty(repo: str, branch: str) -> bool:
    """Make sure the repository has a commit, and return whether it made one.

    GitHub refuses to create a blob in an empty repository: "Git Repository is
    empty" (HTTP 409). The Git Data API needs a tree to hang a commit on, and
    a commit needs a tree, so the two are a chicken and an egg -- but only
    for the very first commit.

    The way out is the Contents API, which is the one endpoint that knows
    how to bootstrap an empty repository: it creates the file and the commit
    and the branch in one go. So the first push writes a placeholder through
    it, and everything after that goes through the tree.
    """
    try:
        api(f"{API}/repos/{repo}/git/refs/heads/{branch}")
        return False
    except urllib.error.HTTPError as error:
        # An empty repository answers 409 ("Git Repository is empty") rather
        # than 404, because the branch is missing rather than the repo.
        if error.code not in (404, 409):
            raise

    print("  the repository is empty; bootstrapping it")
    api(f"{API}/repos/{repo}/contents/.gitkeep", "PUT", {
        "message": "Bootstrap the repository.\n\nThe real tree arrives in the next commit.",
        "content": base64.b64encode(b"").decode("ascii"),
        "branch": branch,
    })
    return True


def main() -> None:
    repo = sys.argv[1] if len(sys.argv) > 1 else "Minerchu/SpektraLab-iOS"
    branch = sys.argv[2] if len(sys.argv) > 2 else "main"

    payload = files()
    total = sum(len(data) for _, data in payload)
    print(f"{len(payload)} files, {total / 1024:.0f} KB -> {repo}@{branch}")

    ensure_not_empty(repo, branch)

    # 1) One blob per file. The sha comes back for the tree.
    tree_entries = []
    for index, (path, data) in enumerate(payload, 1):
        blob = api(f"{API}/repos/{repo}/git/blobs", "POST", {
            "content": base64.b64encode(data).decode("ascii"),
            "encoding": "base64",
        })
        tree_entries.append({
            "path": path,
            "mode": "100755" if path.endswith(".sh") else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        if index % 10 == 0 or index == len(payload):
            print(f"  blobs {index}/{len(payload)}")

    # 2) The tree. A tree whose entries are all blobs is a flat tree, which is
    #    what a checkout of this repository wants.
    tree = api(f"{API}/repos/{repo}/git/trees", "POST", {
        "base_tree": None,
        "tree": tree_entries,
    })
    print(f"  tree {tree['sha']}")

    # 3) The commit. Its parent is the bootstrap commit, so the history is
    #    one commit rather than two unrelated ones.
    parents = []
    try:
        ref = api(f"{API}/repos/{repo}/git/refs/heads/{branch}")
        parents = [ref["object"]["sha"]]
    except urllib.error.HTTPError:
        pass

    message = ("SpektraLab for iOS\n"
               "\n"
               "The film and paper simulation engine, on iPhone.\n"
               "\n"
               "The engine is upstream's and is fetched by the CI rather than\n"
               "vendored here: https://github.com/JamesQiu2005/SpektraLab\n"
               "\n"
               "iOS is Metal natively, so this port reuses the upstream Metal\n"
               "backend rather than the Vulkan one the Android port uses. Three\n"
               "changes to the engine, all in metal_gpu.cpp and all recorded in\n"
               "tools/apply-ios-patch.py.\n")
    commit = api(f"{API}/repos/{repo}/git/commits", "POST", {
        "message": message,
        "tree": tree["sha"],
        "parents": parents,
    })
    print(f"  commit {commit['sha']}")

    # 4) Point the branch at it.
    try:
        ref = api(f"{API}/repos/{repo}/git/refs", "POST", {
            "ref": f"refs/heads/{branch}",
            "sha": commit["sha"],
        })
        print(f"  branch {branch} -> {ref['object']['sha']}")
    except urllib.error.HTTPError as error:
        if error.code != 422:
            raise
        ref = api(f"{API}/repos/{repo}/git/refs/heads/{branch}", "PATCH", {
            "sha": commit["sha"],
            "force": True,
        })
        print(f"  branch {branch} updated -> {ref['object']['sha']}")

    print(f"\ndone: https://github.com/{repo}/tree/{branch}")


if __name__ == "__main__":
    main()
