#!/usr/bin/env python3
"""Fetch the upstream engine's tree through the GitHub API.

    python3 tools/fetch-engine.py <upstream-repo> <commit> <destination>

Why not `git clone` or the tarball: **neither of them delivers
`engine/resources`.** The tree API says the files are in the commit -- 33
blobs under `engine/resources`, the 9.4 MB `spektrafilm_constants.bin` among
them -- and a full clone, a shallow clone, a partial clone and the tarball
all produced a tree with an `engine` directory and no `resources` in it.

There is a second reason, and it is the one that bit: **the GitHub API's
anonymous rate limit is 60 requests an hour**, and a download that runs over
it does not fail loudly -- it returns a tree that is missing whatever was
fetched after the limit. Four different ways of fetching the tree agreeing
on the same incomplete answer is what a rate limit looks like from the
outside. With a token the limit is 5000 an hour, which this fits inside
comfortably.

So: authenticate, ask for the tree, ask for each directory's contents, and
check what came back. The tree API is the authority on what the commit
contains, and the contents API is the authority on the bytes.

`GITHUB_TOKEN` is used when it is set. On a GitHub runner it is always set,
as `${{ github.token }}`; it is a token that can read this public repository
and nothing else.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"

# The directories the app needs. Everything else in the upstream engine -- the
# tests, the host CLI, the tools -- is either desktop-shaped or not needed to
# build the app.
WANTED = (
    "engine/src",
    "engine/include",
    "engine/third_party/metal-cpp",
    "engine/resources",
    "engine/resources_product",
    # The iOS build uses this to fetch the pinned LibRaw tree for the RAW
    # fallback. It lives at the engine root, so the directory prefixes above
    # do not pick it up.
    "engine/setup-libraw.sh",
)

# The upstream's `engine/third_party` also has `stb`, which the app does not
# compile; skipping it saves a few megabytes of requests.
SKIP_PREFIXES = ("engine/third_party/stb",)

# The files that have to be there for the app to build at all.
REQUIRED = (
    "engine/include/spektrafilm/spk_engine.h",
    "engine/resources/spektrafilm_constants.bin",
    "engine/resources/print_luts.json",
    "engine/src/gpu/metal_gpu.cpp",
    "engine/src/pipeline/engine.cpp",
    "engine/src/shaders/nodes.metal",
    "engine/setup-libraw.sh",
)


def request(url: str, token: str, raw: bool = False, tries: int = 5):
    """One API call, with the retries a flaky network needs.

    A 403 is either the rate limit or a transient proxy failure, and the two
    need different answers: the rate limit wants a wait, a transient failure
    wants a retry. Both are retried, with a wait that grows.
    """
    headers = {
        "User-Agent": "spektralab-ios-fetch",
        "Accept": "application/vnd.github+json",
    }
    if token:
        headers["Authorization"] = f"token {token}"
    last = None
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, headers=headers), timeout=300) as response:
                data = response.read()
            if raw:
                return data
            return json.loads(data)
        except urllib.error.HTTPError as error:
            last = error
            if error.code == 403:
                # The rate limit says when it resets.
                reset = error.headers.get("X-RateLimit-Reset")
                wait = 60
                if reset:
                    try:
                        wait = max(5, min(300, int(reset) - int(time.time()) + 5))
                    except ValueError:
                        pass
                print(f"  rate limited; waiting {wait}s", flush=True)
                time.sleep(wait)
                continue
            # 500 included on purpose: the API answers it transiently, and
            # one of them on one blob used to abort the whole fetch.
            if error.code in (500, 502, 503, 504) and attempt < tries - 1:
                time.sleep(2 + attempt * 3)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            last = error
            if attempt < tries - 1:
                time.sleep(2 + attempt * 3)
                continue
            raise
    raise last if last else RuntimeError("unreachable")


def is_wanted(path: str) -> bool:
    if any(path.startswith(prefix) for prefix in SKIP_PREFIXES):
        return False
    return any(path.startswith(prefix) for prefix in WANTED)


def fetch_blob(repo: str, sha: str, token: str) -> bytes:
    """One blob's bytes, by sha, through the Git Data API.

    Not `download_url`, which is raw.githubusercontent.com: it answers **404**
    when it is rate limiting, and a 404 from there is indistinguishable from
    "this file is not in the commit". That is exactly how a partial fetch came
    to look like a complete one -- the fetch died at 141/239 with
    `HTTP Error 404: Not Found` and nothing to say which file or why.

    The blob endpoint is authenticated against the token's 5000/hour budget,
    returns base64 for any blob up to 100 MB, and cannot 404 for a sha that
    the tree itself just listed.
    """
    payload = request(f"{API}/repos/{repo}/git/blobs/{sha}", token)
    if payload.get("encoding") != "base64":
        raise RuntimeError(f"blob {sha[:12]} came back as {payload.get('encoding')}")
    return base64.b64decode(payload["content"])


def main() -> None:
    if len(sys.argv) < 4:
        print("usage: fetch-engine.py <repo> <commit> <destination>")
        sys.exit(2)
    repo = sys.argv[1]
    commit = sys.argv[2]
    destination = Path(sys.argv[3])
    token = os.environ.get("GITHUB_TOKEN", "").strip()

    if not token:
        print("::warning::no GITHUB_TOKEN: the API's anonymous limit is 60 "
              "requests an hour, which this needs more than")

    print(f"fetching {repo}@{commit[:12]} -> {destination}", flush=True)

    # The tree, for the authority on what the commit contains. The listing
    # below is what the bytes come from; this is what says what there should
    # be, and it is cheap (one request).
    tree = request(f"{API}/repos/{repo}/git/trees/{commit}?recursive=1", token)
    if tree.get("truncated"):
        raise SystemExit("the tree is truncated; the upstream repository is "
                         "too large for one tree request")
    expected = {entry["path"] for entry in tree["tree"]
                if entry["type"] == "blob" and is_wanted(entry["path"])}
    print(f"  the tree has {len(expected)} engine files", flush=True)

    # The bytes, one blob at a time, keyed by the sha the tree gave. The tree
    # is the only authority used here -- no directory listings, no
    # `download_url` -- so a rate-limited raw endpoint cannot turn into a
    # silently incomplete tree.
    found: list[dict] = sorted(
        (entry for entry in tree["tree"]
         if entry["type"] == "blob" and is_wanted(entry["path"])),
        key=lambda entry: entry["path"],
    )

    destination.mkdir(parents=True, exist_ok=True)
    written = 0
    total = 0
    for index, entry in enumerate(found, 1):
        target = destination / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        data = fetch_blob(repo, entry["sha"], token)
        expected_size = entry.get("size")
        if expected_size is not None and len(data) != expected_size:
            raise SystemExit(
                f"{entry['path']}: {len(data)} bytes, the tree says {expected_size}")
        target.write_bytes(data)
        written += 1
        total += len(data)
        if index % 20 == 0 or index == len(found):
            print(f"  {index}/{len(found)} files, {total / 1048576:.1f} MB", flush=True)

    # The check. The build fails later, and further away, if the engine is
    # incomplete; this says what is missing while it is still cheap to fix.
    missing = [p for p in REQUIRED if not (destination / p).exists()]
    if missing:
        for path in missing:
            print(f"::error::missing {path}")
        print(f"::error::{len(expected) - len(found)} of the tree's files did not arrive")
        raise SystemExit("the engine is incomplete")
    if not (destination / "engine/resources/profiles").is_dir():
        raise SystemExit("the engine has no stock profiles")

    profiles = len(list((destination / "engine/resources/profiles").glob("*.json")))
    print(f"the engine is in place: {written} files, {total / 1048576:.1f} MB, "
          f"{profiles} stock profiles")


if __name__ == "__main__":
    main()
