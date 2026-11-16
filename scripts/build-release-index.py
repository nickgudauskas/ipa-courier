#!/usr/bin/env python3
"""Builds releases.json: the latest GitHub release of every catalog project.

IPA Courier downloads this one file instead of calling GitHub's API once per
project, which would exceed the 60-requests-per-hour anonymous limit.

Usage: GITHUB_TOKEN=... python3 scripts/build-release-index.py [--images DIR] > releases.json

With --images, it also saves each project's GitHub preview card as
DIR/<owner>__<repo>.png, skipping ones already there. GitHub's preview-image
service allows about 100 requests per IP before asking for a wait of several
minutes, so the app reads these published copies instead.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "Resources" / "catalog.json"
TOKEN = os.environ.get("GITHUB_TOKEN", "")


def latest(repo):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "IPA-Courier-release-index",
            **({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = json.load(response)
    except urllib.error.HTTPError as error:
        print(f"{repo}: HTTP {error.code}", file=sys.stderr)
        return repo, None
    except Exception as error:  # network hiccup: leave it out, the app falls back to the API
        print(f"{repo}: {error}", file=sys.stderr)
        return repo, None
    return repo, {
        "tag": raw["tag_name"],
        "name": raw.get("name"),
        "publishedAt": raw.get("published_at"),
        "pageURL": raw["html_url"],
        "assets": [
            {"name": a["name"], "size": a["size"], "downloadURL": a["browser_download_url"]}
            for a in raw.get("assets", [])
        ],
    }


def image_name(repo):
    return repo.replace("/", "__") + ".png"


def fetch_images(repos, directory, budget_seconds=1200):
    """Downloads missing preview cards one at a time, honouring Retry-After."""
    directory.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + budget_seconds
    missing = [r for r in sorted(repos) if not (directory / image_name(r)).exists()]
    saved = 0
    for repo in missing:
        for _ in range(4):
            if time.monotonic() > deadline:
                print(f"images: time budget used, {len(missing) - saved} left for the next run", file=sys.stderr)
                return
            request = urllib.request.Request(
                f"https://opengraph.githubassets.com/1/{repo}", headers={"User-Agent": "IPA-Courier-release-index"})
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
                if data[:8] == b"\x89PNG\r\n\x1a\n":
                    (directory / image_name(repo)).write_bytes(data)
                    saved += 1
                break
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    wait = min(int(error.headers.get("Retry-After", "60")), 300)
                    print(f"images: rate limited, waiting {wait}s", file=sys.stderr)
                    time.sleep(wait)
                    continue
                print(f"images: {repo}: HTTP {error.code}", file=sys.stderr)
                break
            except Exception as error:
                print(f"images: {repo}: {error}", file=sys.stderr)
                break
        time.sleep(1)
    print(f"images: saved {saved}, {len(repos) - len(missing)} already present", file=sys.stderr)


def main():
    catalog = json.loads(CATALOG.read_text())
    repos = {p["repo"] for p in catalog["projects"]}
    if catalog.get("padmint"):
        repos.add(catalog["padmint"]["repo"])
    if "--images" in sys.argv:
        fetch_images({p["repo"] for p in catalog["projects"]}, Path(sys.argv[sys.argv.index("--images") + 1]))
    with ThreadPoolExecutor(8) as pool:
        results = dict(pool.map(latest, sorted(repos)))
    releases = {repo: release for repo, release in results.items() if release}
    print(f"{len(releases)}/{len(repos)} releases indexed", file=sys.stderr)
    json.dump(
        {
            "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "releases": releases,
        },
        sys.stdout,
        indent=1,
        sort_keys=True,
    )
    print()


if __name__ == "__main__":
    main()
