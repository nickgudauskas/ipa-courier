#!/usr/bin/env python3
"""Builds releases.json: the latest GitHub release of every catalog project.

IPA Courier downloads this one file instead of calling GitHub's API once per
project, which would exceed the 60-requests-per-hour anonymous limit.

Usage: GITHUB_TOKEN=... python3 scripts/build-release-index.py > releases.json
"""
import json
import os
import sys
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


def main():
    catalog = json.loads(CATALOG.read_text())
    repos = {p["repo"] for p in catalog["projects"]}
    if catalog.get("padmint"):
        repos.add(catalog["padmint"]["repo"])
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
