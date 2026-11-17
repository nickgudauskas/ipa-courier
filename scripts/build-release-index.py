#!/usr/bin/env python3
"""Builds releases.json: the latest GitHub release of every catalog project.

IPA Courier downloads this one file instead of calling GitHub's API once per
project, which would exceed the 60-requests-per-hour anonymous limit.

Usage: GITHUB_TOKEN=... python3 scripts/build-release-index.py [--images DIR] [--health FILE]
                                                               [--catalog FILE] > releases.json

With --images, it also saves each project's GitHub preview card as
DIR/<owner>__<repo>.png, skipping ones already there. GitHub's preview-image
service allows about 100 requests per IP before asking for a wait of several
minutes, so the app reads these published copies instead.

With --health, it also checks every project and writes a Markdown report of
problems to FILE (empty when everything resolves): repos that moved or
disappeared, repos with no releases, and asset rules that no longer match.
The workflow turns a non-empty report into a GitHub issue.

A platform rule can also have "tag", a regular expression: that platform's file
then comes from the newest published release whose tag matches (for projects
that release each platform separately, e.g. "^iOSv"). Its files are merged into
the project's entry, so every app version finds them with the same asset rule.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "Resources" / "catalog.json"
TOKEN = os.environ.get("GITHUB_TOKEN", "")


def api(path):
    request = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "IPA-Courier-release-index",
            **({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}),
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def latest(repo):
    """Returns (repo, release or None, problem or None).

    A problem is only reported when it's definite (HTTP 404); network errors
    and server hiccups are retried and otherwise left out quietly, so a brief
    GitHub outage doesn't open an issue.
    """
    for attempt in range(3):
        try:
            raw = api(f"repos/{repo}/releases/latest")
            break
        except urllib.error.HTTPError as error:
            if error.code == 404:
                try:
                    api(f"repos/{repo}")
                    return repo, None, "has no published releases (only drafts, pre-releases or none at all)"
                except urllib.error.HTTPError:
                    return repo, None, "doesn't exist any more (deleted, renamed without a redirect, or made private)"
            print(f"{repo}: HTTP {error.code}", file=sys.stderr)
        except Exception as error:
            print(f"{repo}: {error}", file=sys.stderr)
        time.sleep(2 * (attempt + 1))
    else:
        return repo, None, None
    return repo, record(raw), None


def record(raw):
    return {
        "tag": raw["tag_name"],
        "name": raw.get("name"),
        "publishedAt": raw.get("published_at"),
        "pageURL": raw["html_url"],
        "assets": [
            {"name": a["name"], "size": a["size"], "downloadURL": a["browser_download_url"]}
            for a in raw.get("assets", [])
        ],
    }


def tagged(repo, pattern):
    """The newest published (not draft or pre-release) release whose tag matches, or None."""
    for attempt in range(3):
        try:
            for page in range(1, 4):
                items = api(f"repos/{repo}/releases?per_page=100&page={page}")
                for raw in items:  # newest first
                    if not raw.get("draft") and not raw.get("prerelease") and re.search(pattern, raw["tag_name"]):
                        return record(raw)
                if len(items) < 100:
                    return None
            return None
        except Exception as error:
            print(f"{repo} (tag {pattern}): {error}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))
    return None


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


def option(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


PLATFORMS = {"mac": "Mac", "ios": "iPhone & iPad", "android": "Android"}


def health_report(catalog, results, tagged_releases=None):
    """Markdown list of catalog problems, or "" when every project resolves."""
    tagged_releases = tagged_releases or {}
    problems = []
    for project in catalog["projects"]:
        repo = project["repo"]
        release, problem = results.get(repo, (None, None))
        label = f"**{project['name']}** (`{project['id']}`, [{repo}](https://github.com/{repo}))"
        if problem:
            problems.append(f"- {label}: the repo {problem}.")
            continue
        if not release:
            continue  # couldn't check this time; don't guess
        actual = "/".join(release["pageURL"].split("/")[3:5])
        if actual.lower() != repo.lower():
            problems.append(f"- {label}: the repo moved to [{actual}](https://github.com/{actual}). Update `repo`.")
        names = [asset["name"] for asset in release["assets"]]
        for key, platform in PLATFORMS.items():
            rule = project.get(key)
            if not rule:
                continue
            checked = release
            if rule.get("tag"):
                checked = tagged_releases.get((repo, rule["tag"]))
                if not checked:
                    problems.append(f"- {label}: no published release has a tag matching `{rule['tag']}` "
                                    f"(the {platform} rule's `tag`).")
                    continue
                names = [asset["name"] for asset in checked["assets"]]
            else:
                names = [asset["name"] for asset in release["assets"]]
            try:
                matched = any(re.search(rule["asset"], name, re.IGNORECASE) for name in names)
            except re.error as error:
                problems.append(f"- {label}: the {platform} rule `{rule['asset']}` isn't a valid regular expression ({error}).")
                continue
            if not matched:
                shown = ", ".join(f"`{n}`" for n in names[:12]) or "no files"
                more = f" and {len(names) - 12} more" if len(names) > 12 else ""
                problems.append(
                    f"- {label}: no {platform} file in [{checked['tag']}]({checked['pageURL']}) matches "
                    f"`{rule['asset']}`. The release has {shown}{more}.")
    if not problems:
        return ""
    return "\n".join([
        f"The scheduled catalog check found {len(problems)} problem{'s' if len(problems) != 1 else ''} in "
        "[`Resources/catalog.json`](../blob/main/Resources/catalog.json). Affected projects show "
        "\"Release unavailable\" or lose a download button in Discover until they're fixed.",
        "",
        *problems,
        "",
        "Fix each entry (and bump the catalog's `revision`), or remove projects that are gone. "
        "This issue is updated by the [Update release index](../actions/workflows/release-index.yml) "
        "workflow and closes itself once every project resolves again.",
        "",
        f"_Last checked {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}._",
    ]) + "\n"


def main():
    catalog = json.loads(Path(option("--catalog") or CATALOG).read_text())
    repos = {p["repo"] for p in catalog["projects"]}
    if catalog.get("padmint"):
        repos.add(catalog["padmint"]["repo"])
    if option("--images"):
        fetch_images({p["repo"] for p in catalog["projects"]}, Path(option("--images")))
    with ThreadPoolExecutor(8) as pool:
        results = {repo: (release, problem) for repo, release, problem in pool.map(latest, sorted(repos))}
    releases = {repo: release for repo, (release, _) in results.items() if release}
    wanted = {(p["repo"], p[key]["tag"]) for p in catalog["projects"] for key in PLATFORMS
              if isinstance(p.get(key), dict) and p[key].get("tag")}
    tagged_releases = {pair: tagged(*pair) for pair in sorted(wanted)}
    for (repo, _), extra in tagged_releases.items():
        if extra and repo in releases:
            have = {a["name"] for a in releases[repo]["assets"]}
            # Each merged file names its own release, so the app can show that version.
            source = {"tag": extra["tag"], "publishedAt": extra["publishedAt"], "pageURL": extra["pageURL"]}
            releases[repo]["assets"] += [{**a, **source} for a in extra["assets"] if a["name"] not in have]
    print(f"{len(releases)}/{len(repos)} releases indexed", file=sys.stderr)
    if option("--health"):
        report = health_report(catalog, results, tagged_releases)
        Path(option("--health")).write_text(report)
        count = sum(line.startswith("- ") for line in report.splitlines())
        print(f"health: {count} problem(s)" if count else "health: all projects resolve", file=sys.stderr)
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
