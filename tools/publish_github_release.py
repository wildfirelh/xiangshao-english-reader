"""Mirror the public source repository and publish its APK release on GitHub.

Credentials stay in memory. Existing tags, notes and assets are never replaced.
GitHub REST references: https://docs.github.com/en/rest/releases/releases and
https://docs.github.com/en/rest/releases/assets .
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import quote, urlsplit

import requests

from package_release import DEFAULT_AAPT, package_release, read_version, sha256_file
from release_presentation import release_body_matches
from release_title import release_title
ROOT = Path(__file__).resolve().parents[1]
API = "https://api.github.com"
GH = Path(r"C:\Program Files\GitHub CLI\gh.exe")
DEFAULT_OWNER = "wildfirelh"
SOURCE_NAME = "xiangshao-english-reader"
PUBLIC_NAME = SOURCE_NAME
VERSION_TAG = re.compile(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?")


def credentials():
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            return os.environ[name].strip()
    result = subprocess.run([str(GH), "auth", "token", "--hostname", "github.com"],
                            capture_output=True, text=True, timeout=20)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("GitHub credentials unavailable; authenticate gh or set GH_TOKEN")
    return result.stdout.strip()


def git_command(cwd, *args, token=None, check=True, anonymous=False):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    # Exclude inherited header/askpass injections and keep tokens out of argv and config.
    for key in list(environment):
        if key in ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_ASKPASS", "SSH_ASKPASS") or key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            environment.pop(key, None)
    if token:
        encoded = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        environment.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.https://github.com/.extraHeader",
                           GIT_CONFIG_VALUE_0=f"Authorization: Basic {encoded}")
    if anonymous:
        environment.update(GIT_ASKPASS="", SSH_ASKPASS="", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", env=environment)
    if check and result.returncode:
        # Neither stderr nor signed URLs/credential-helper output may reach logs.
        raise RuntimeError(f"GitHub mirror Git operation failed: {args[0]}")
    return result.stdout.strip() if check else result


def git(*args):
    return git_command(ROOT, *args)


def source_snapshot(tag):
    """Validate the local App tag without contacting another hosting platform."""
    if not VERSION_TAG.fullmatch(tag):
        raise RuntimeError("Invalid App version tag")
    if git("status", "--porcelain"):
        raise RuntimeError("Commit publishing changes before publishing")
    head = git("rev-parse", "HEAD")
    if head != git("rev-parse", "refs/heads/main"):
        raise RuntimeError("Check out main before publishing")
    if git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise RuntimeError("App version tag must remain annotated")
    tagged_commit = git("rev-parse", f"{tag}^{{commit}}")
    if git_command(ROOT, "merge-base", "--is-ancestor", tagged_commit, head,
                   check=False).returncode:
        raise RuntimeError("App version tag must belong to the current main history")
    if git("diff", "--name-only", tagged_commit, head, "--",
           "pubspec.yaml", "lib", "android", "assets"):
        raise RuntimeError("App or textbook changed after its version tag; build a new version")
    # mirror_repository subsequently verifies remote GitHub main and every tag,
    # rejecting divergent branches or moved tags before publishing any Release.
    return tagged_commit


def mirror_repository(cwd, repository, token):
    if repository != f"{DEFAULT_OWNER}/{SOURCE_NAME}" or Path(cwd).resolve() != ROOT.resolve():
        raise RuntimeError("Only the authorized source repository may be mirrored")
    run = lambda *args, **kwargs: git_command(cwd, *args, **kwargs)
    if run("status", "--porcelain"):
        raise RuntimeError("Commit local changes before mirroring to GitHub")
    head = run("rev-parse", "refs/heads/main")
    if run("rev-parse", "HEAD") != head:
        raise RuntimeError("Check out main before mirroring to GitHub")
    tags = {}
    for line in run("for-each-ref", "--format=%(refname) %(objecttype) %(objectname)", "refs/tags").splitlines():
        ref, kind, object_id = line.split()
        if VERSION_TAG.fullmatch(ref.removeprefix("refs/tags/")):
            if kind != "tag":
                raise RuntimeError("App version tags must remain annotated")
            tags[ref] = object_id
    if not tags:
        raise RuntimeError("An annotated App version tag is required")
    remote = f"https://github.com/{repository}.git"
    existing = run("remote", "get-url", "github", check=False)
    if existing.returncode:
        run("remote", "add", "github", remote)
    for direction in ((), ("--push",)):
        if run("remote", "get-url", *direction, "--all", "github").splitlines() != [remote]:
            raise RuntimeError("Existing github remote points to another repository")
    refs = dict(line.split()[::-1] for line in run("ls-remote", "github", token=token).splitlines())
    for ref, object_id in refs.items():
        if ref == "HEAD" or ref == "refs/heads/main":
            continue
        if ref.endswith("^{}") and ref.removesuffix("^{}") in tags:
            if object_id != run("rev-parse", ref):
                raise RuntimeError("Existing GitHub version tag points to another commit")
        elif ref in tags and tags[ref] == object_id:
            continue
        else:
            raise RuntimeError("GitHub repository contains different or unexpected history; refusing to overwrite")
    if refs.get("refs/heads/main") and refs["refs/heads/main"] != head:
        run("fetch", "--no-tags", "github", "main", token=token)
        if run("merge-base", "--is-ancestor", "FETCH_HEAD", head, check=False).returncode:
            raise RuntimeError("GitHub main has diverged; refusing to overwrite")
    refspecs = ["refs/heads/main:refs/heads/main", *[f"{ref}:{ref}" for ref in tags]]
    run("push", "--atomic", "github", *refspecs, token=token)
    after = dict(line.split()[::-1] for line in run("ls-remote", "github", token=token).splitlines())
    if after.get("refs/heads/main") != head or any(after.get(ref) != value for ref, value in tags.items()):
        raise RuntimeError("GitHub mirror refs did not match the local repository")
    return {"main": head, "annotatedVersionTags": len(tags)}


class GitHubRelease:
    def __init__(self, token):
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers.update({"Authorization": f"Bearer {token}",
                                     "Accept": "application/vnd.github+json",
                                     "X-GitHub-Api-Version": "2022-11-28"})

    def request(self, method, path, *, missing_ok=False, **kwargs):
        try:
            with self.session.request(method, API + path, timeout=(20, 90),
                                      allow_redirects=False, **kwargs) as response:
                if missing_ok and response.status_code == 404:
                    return None
                if not response.ok:
                    raise RuntimeError(f"GitHub API request failed (HTTP {response.status_code})")
                return response.json()
        except requests.RequestException:
            raise RuntimeError("GitHub API network request failed; rerun to resume") from None
        except ValueError:
            raise RuntimeError("GitHub API returned invalid JSON") from None

    def owner(self, requested):
        login = self.request("GET", "/user").get("login", "")
        if not login or login.lower() != requested.lower():
            raise RuntimeError("Authenticated GitHub user differs from GH_OWNER; refusing another account")
        return login

    def ensure_repository(self, repository, *, private):
        if repository != f"{DEFAULT_OWNER}/{SOURCE_NAME}" or private is not False:
            raise RuntimeError("Only the authorized public source-and-release repository is allowed")
        path = f"/repos/{repository}"
        repo = self.request("GET", path)
        if (repo.get("full_name", "").lower() != repository.lower()
                or repo.get("owner", {}).get("login", "").lower() != repository.split("/")[0].lower()
                or repo.get("private") is not private or repo.get("fork") is not False):
            raise RuntimeError("GitHub repository identity, privacy or fork status is unexpected")
        return repo

    def list_items(self, path):
        items = []
        for page in range(1, 11):
            batch = self.request("GET", path, params={"per_page": 100, "page": page})
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise RuntimeError("GitHub pagination limit exceeded; review repository manually")

    def release(self, repository, tag):
        prefix = f"/repos/{repository}/releases"
        release = self.request("GET", f"{prefix}/tags/{quote(tag, safe='')}", missing_ok=True)
        if release is not None:
            return release
        # GitHub's tag endpoint may omit unpublished drafts; resume via the authenticated list.
        matches = [item for item in self.list_items(prefix) if item.get("tag_name") == tag]
        if len(matches) > 1:
            raise RuntimeError("GitHub has multiple releases for the version tag")
        return matches[0] if matches else None

    def upload(self, repository, release, file):
        expected = f"https://uploads.github.com/repos/{repository}/releases/{release['id']}/assets"
        if release.get("upload_url", "").split("{", 1)[0] != expected:
            raise RuntimeError("GitHub returned an unexpected upload endpoint")
        try:
            with file.open("rb") as source:
                with self.session.post(expected, params={"name": file.name}, data=source,
                                       headers={"Content-Type": "application/octet-stream"},
                                       timeout=(20, 300), allow_redirects=False) as response:
                    if not response.ok:
                        raise RuntimeError(f"GitHub attachment upload failed (HTTP {response.status_code})")
                    return response.json()
        except requests.RequestException:
            raise RuntimeError("GitHub attachment upload network request failed; rerun to resume") from None

    def verify_download(self, repository, asset, file, *, anonymous):
        expected_digest = sha256_file(file)
        if asset.get("size") != file.stat().st_size or asset.get("state") != "uploaded":
            raise RuntimeError(f"GitHub attachment metadata differs: {file.name}")
        if asset.get("digest") not in (None, f"sha256:{expected_digest}"):
            raise RuntimeError(f"GitHub attachment digest differs: {file.name}")
        browser_prefix = f"https://github.com/{repository}/releases/download/"
        browser_url = asset.get("browser_download_url", "")
        if not browser_url.startswith(browser_prefix):
            raise RuntimeError("GitHub returned an unexpected public download URL")
        storage = requests.Session()
        storage.trust_env = False
        response = None
        try:
            for attempt in range(3 if anonymous else 1):
                if anonymous:
                    response = storage.get(browser_url, stream=True, timeout=(20, 90), allow_redirects=False)
                else:
                    url = f"{API}/repos/{repository}/releases/assets/{int(asset['id'])}"
                    response = self.session.get(url, headers={"Accept": "application/octet-stream"},
                                                stream=True, timeout=(20, 90), allow_redirects=False)
                for _ in range(5):
                    if response.status_code not in (301, 302, 303, 307, 308):
                        break
                    location = response.headers.get("Location", "")
                    parsed = urlsplit(location)
                    if (parsed.scheme != "https" or parsed.username or parsed.password
                            or not parsed.hostname or parsed.port not in (None, 443)
                            or not (parsed.hostname == "github.com" or parsed.hostname.endswith(".githubusercontent.com"))):
                        raise RuntimeError("GitHub attachment redirect is not approved HTTPS storage")
                    response.close()
                    # All signed storage redirects use a separate session without API auth.
                    response = storage.get(location, stream=True, timeout=(20, 90), allow_redirects=False)
                if response.status_code == 404 and anonymous and attempt < 2:
                    # A newly published browser URL may take a few seconds to propagate.
                    response.close()
                    response = None
                    time.sleep(2 * (attempt + 1))
                    continue
                if response.status_code != 200:
                    raise RuntimeError(f"GitHub attachment verification failed (HTTP {response.status_code})")
                break
            digest, size = hashlib.sha256(), 0
            for chunk in response.iter_content(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
            if digest.hexdigest() != expected_digest or size != file.stat().st_size:
                raise RuntimeError(f"GitHub attachment differs from local file: {file.name}")
        except requests.RequestException:
            raise RuntimeError("GitHub attachment verification network request failed; rerun to resume") from None
        finally:
            if response is not None:
                response.close()
            storage.close()

    def publish(self, repository, tag, commit, notes, files):
        apk_files = [file for file in files if re.fullmatch(
            rf"xiangshao-english-reader-{re.escape(tag)}-build\d+-(?:arm64-v8a|armeabi-v7a|x86_64)\.apk", file.name)]
        if len(apk_files) != 1 or set(files) != {apk_files[0], apk_files[0].with_suffix(".apk.sha256")}:
            raise RuntimeError("GitHub public release may contain only the versioned APK and its checksum")
        title = release_title(tag, notes)
        self.ensure_repository(repository, private=False)
        prefix = f"/repos/{repository}/releases"
        release = self.release(repository, tag)
        if release is None:
            release = self.request("POST", prefix, json={
                "tag_name": tag, "target_commitish": commit, "name": title,
                "body": notes, "draft": True, "prerelease": False,
            })
        if (release.get("tag_name") != tag or release.get("name") != title
                or not release_body_matches(release.get("body", ""), notes,
                                            tag=tag, platform="github")
                or release.get("target_commitish") != commit or release.get("prerelease") is not False
                or not isinstance(release.get("draft"), bool)):
            raise RuntimeError("Existing GitHub release differs; refusing to overwrite version history")
        assets = {item["name"]: item for item in self.list_items(f"{prefix}/{release['id']}/assets")}
        names = {file.name for file in files}
        if set(assets) - names:
            raise RuntimeError("GitHub public release contains unexpected attachments")
        for file in files:
            if file.name not in assets:
                if not release["draft"]:
                    raise RuntimeError("Published GitHub release is missing attachments; refusing to change it")
                print(f"Uploading {file.name} ({file.stat().st_size:,} bytes)", flush=True)
                assets[file.name] = self.upload(repository, release, file)
            if release["draft"]:
                self.verify_download(repository, assets[file.name], file, anonymous=False)
        published_draft = release["draft"]
        if published_draft:
            release = self.request("PATCH", f"{prefix}/{release['id']}", json={
                "draft": False, "prerelease": False, "make_latest": "true",
            })
        if release.get("draft") is not False or release.get("prerelease") is not False:
            raise RuntimeError("GitHub release did not become a stable published release")
        if published_draft:
            # Draft upload URLs can name an untagged release; publication returns canonical URLs.
            assets = {item["name"]: item for item in self.list_items(f"{prefix}/{release['id']}/assets")}
            if set(assets) != names:
                raise RuntimeError("Published GitHub release attachments differ from the verified draft")
        # Use the browser URLs after publication to prove access without credentials.
        for file in files:
            self.verify_download(repository, assets[file.name], file, anonymous=True)
        return release, len(assets)


def verify_anonymous_pages(repository, tag):
    page = f"https://github.com/{repository}"
    with requests.Session() as session:
        session.trust_env = False
        try:
            for suffix in ("", f"/releases/tag/{quote(tag, safe='')}"):
                with session.get(page + suffix, timeout=(20, 90), allow_redirects=False) as response:
                    if response.status_code != 200:
                        raise RuntimeError(f"GitHub anonymous page failed (HTTP {response.status_code})")
        except requests.RequestException:
            raise RuntimeError("GitHub anonymous page verification network request failed") from None
    result = git_command(ROOT, "-c", "credential.helper=", "-c", "core.askPass=",
                         "-c", "http.extraHeader=", "ls-remote", "--exit-code",
                         page + ".git", "refs/heads/main", anonymous=True, check=False)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("GitHub public source cannot be accessed without Git credentials")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, default=ROOT / "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk")
    parser.add_argument("--aapt", type=Path, default=DEFAULT_AAPT)
    args = parser.parse_args()
    version, _ = read_version(ROOT / "pubspec.yaml")
    tag = f"v{version}"
    metadata = package_release(ROOT, args.apk.resolve(), args.aapt.resolve())
    apk = ROOT / "build/releases" / tag / metadata["filename"]
    notes = (ROOT / "releases" / f"{tag}.md").read_text(encoding="utf-8")
    source_commit = source_snapshot(tag)
    if git("show", f"{source_commit}:releases/{tag}.md").strip() != notes.strip():
        raise RuntimeError("Release notes changed after their App version tag")
    token = credentials()
    client = GitHubRelease(token)
    try:
        owner = client.owner(os.environ.get("GH_OWNER", DEFAULT_OWNER))
        source_repository = f"{owner}/{SOURCE_NAME}"
        client.ensure_repository(source_repository, private=False)
        source_mirror = mirror_repository(ROOT, source_repository, token)
        release, asset_count = client.publish(source_repository, tag, source_commit, notes,
                                              [apk, apk.with_suffix(".apk.sha256")])
        verify_anonymous_pages(source_repository, tag)
        client.ensure_repository(source_repository, private=False)
    finally:
        client.session.close()
    report = {
        "tag": tag, "sourceCommit": source_commit, "sourcePublic": True,
        "sourceRepository": f"https://github.com/{source_repository}", "sourceMirror": source_mirror,
        "repository": f"https://github.com/{source_repository}",
        "releasePage": f"https://github.com/{source_repository}/releases/tag/{tag}",
        "releaseId": release["id"], "releaseStatus": "published", "assetCount": asset_count,
        "apk": apk.name, "sha256": metadata["sha256"],
        "anonymousPagesVerified": True, "anonymousDownloadsVerified": True,
    }
    (apk.parent / "github-release.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"GitHub release failed: {error}")
        raise SystemExit(1)
