"""Mirror source and publish verified APKs and update.json in one Gitee repo.

Official API contract: https://gitee.com/api/v5/swagger . Credentials remain
in memory; anonymous downloads use a separate session with no cookies/auth.
The update manifest is uploaded last, after APK bytes have been verified.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote, urljoin, urlsplit

import requests

from package_release import (
    ABI_VERSION_OFFSETS, DEFAULT_AAPT, package_release, read_version,
    sha256_file, write_sidecar,
)
from release_title import release_title


ROOT = Path(__file__).resolve().parents[1]
API = "https://gitee.com/api/v5"
OWNER = "wildfire666"
NAME = "xiangshao-english-reader"
REPOSITORY = f"{OWNER}/{NAME}"
REMOTE = f"https://gitee.com/{REPOSITORY}.git"
PACKAGE_NAME = "com.example.english_point_reading"
CERT_SHA256 = "be287a9d0e703355421be11adf674ead5a9dee6ff6288404421ab08b7ef26aa5"
VERSION_TAG = re.compile(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?")


def credentials():
    for name in ("GITEE_TOKEN", "GITEE_ACCESS_TOKEN"):
        if os.environ.get(name, "").strip():
            return os.environ[name].strip()
    try:
        result = subprocess.run(
            ["git", "credential", "fill"], cwd=ROOT,
            input="protocol=https\nhost=gitee.com\n\n", capture_output=True,
            text=True, timeout=25,
            env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never"),
        )
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("Gitee credential manager unavailable") from None
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode or not values.get("password"):
        raise RuntimeError("Configure GITEE_TOKEN or sign in using Git Credential Manager")
    return values["password"]


def git(*arguments, check=True, token=None):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    for key in list(environment):
        if key in ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_ASKPASS", "SSH_ASKPASS") or key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            environment.pop(key, None)
    if token:
        auth = base64.b64encode(f"{OWNER}:{token}".encode()).decode()
        environment.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.https://gitee.com/.extraHeader",
                           GIT_CONFIG_VALUE_0=f"Authorization: Basic {auth}")
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", env=environment)
    if check and result.returncode:
        raise RuntimeError(f"Gitee Git operation failed: {arguments[0]}")
    return result.stdout.strip() if check else result


def mirror_repository(token):
    if git("status", "--porcelain"):
        raise RuntimeError("Commit source changes before publishing")
    head = git("rev-parse", "refs/heads/main")
    if git("rev-parse", "HEAD") != head:
        raise RuntimeError("Check out main before publishing")
    existing = git("remote", "get-url", "gitee", check=False)
    if existing.returncode:
        git("remote", "add", "gitee", REMOTE)
    for direction in ((), ("--push",)):
        if git("remote", "get-url", *direction, "--all", "gitee").splitlines() != [REMOTE]:
            raise RuntimeError("Gitee remote does not match the authorized repository")
    tags = {}
    for line in git("for-each-ref", "--format=%(refname) %(objecttype) %(objectname)", "refs/tags").splitlines():
        ref, kind, object_id = line.split()
        if VERSION_TAG.fullmatch(ref.removeprefix("refs/tags/")):
            if kind != "tag":
                raise RuntimeError("App version tags must be annotated")
            tags[ref] = object_id
    refs = dict(line.split()[::-1] for line in git("ls-remote", "gitee", token=token).splitlines())
    for ref, object_id in refs.items():
        if ref in ("HEAD", "refs/heads/main"):
            continue
        if ref.endswith("^{}") and ref.removesuffix("^{}") in tags:
            if git("rev-parse", ref) != object_id:
                raise RuntimeError("Existing Gitee version tag differs")
        elif tags.get(ref) != object_id:
            raise RuntimeError("Gitee contains unexpected refs; refusing to overwrite")
    if refs.get("refs/heads/main") and refs["refs/heads/main"] != head:
        git("fetch", "--no-tags", "gitee", "main", token=token)
        if git("merge-base", "--is-ancestor", "FETCH_HEAD", head, check=False).returncode:
            raise RuntimeError("Gitee main has diverged; refusing to overwrite")
    git("push", "--atomic", "gitee", "refs/heads/main:refs/heads/main",
        *[f"{ref}:{ref}" for ref in tags], token=token)
    after = dict(line.split()[::-1] for line in git("ls-remote", "gitee", token=token).splitlines())
    if after.get("refs/heads/main") != head or any(after.get(ref) != value for ref, value in tags.items()):
        raise RuntimeError("Gitee source refs did not match local refs")
    return head


def download_url(tag, filename):
    if not VERSION_TAG.fullmatch(tag) or Path(filename).name != filename:
        raise ValueError("Invalid release tag or filename")
    return f"https://gitee.com/{REPOSITORY}/releases/download/{quote(tag, safe='')}/{quote(filename, safe='')}"


def secure_download_url(url):
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if (parsed.scheme != "https" or parsed.username or parsed.password
            or parsed.port not in (None, 443)
            or not (host == "gitee.com" or host.endswith(".gitee.com"))):
        raise RuntimeError("Download redirected outside Gitee HTTPS storage")
    return url


def verify_download(file, url):
    """Re-download all bytes without auth, cookies or netrc, then check SHA/size."""
    expected = sha256_file(file)
    anonymous = requests.Session()
    anonymous.trust_env = False
    response = None
    try:
        url = secure_download_url(url)
        for _ in range(6):
            anonymous.cookies.clear()
            response = anonymous.get(url, stream=True, timeout=(20, 120), allow_redirects=False)
            if response.status_code not in (301, 302, 303, 307, 308):
                break
            location = secure_download_url(urljoin(url, response.headers.get("Location", "")))
            response.close()
            response = None
            url = location
        if response is None or response.status_code != 200:
            raise RuntimeError("Anonymous Gitee attachment download failed")
        digest, size = hashlib.sha256(), 0
        for chunk in response.iter_content(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
            if size > file.stat().st_size:
                raise RuntimeError(f"Anonymous Gitee attachment differs: {file.name}")
        if digest.hexdigest() != expected or size != file.stat().st_size:
            raise RuntimeError(f"Anonymous Gitee attachment differs: {file.name}")
    except requests.RequestException:
        raise RuntimeError("Anonymous Gitee download network request failed") from None
    finally:
        if response is not None:
            response.close()
        anonymous.close()


class GiteeRelease:
    def __init__(self, token):
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers["Authorization"] = f"token {token}"

    def request(self, method, path, *, missing_ok=False, **kwargs):
        try:
            with self.session.request(method, API + path, timeout=(20, 180),
                                      allow_redirects=False, **kwargs) as response:
                if missing_ok and response.status_code == 404:
                    return None
                if not response.ok:
                    raise RuntimeError(f"Gitee API failed (HTTP {response.status_code})")
                return response.json()
        except requests.RequestException:
            raise RuntimeError("Gitee API network request failed; rerun to resume") from None
        except ValueError:
            raise RuntimeError("Gitee API returned invalid JSON") from None

    def ensure_owner(self):
        if self.request("GET", "/user").get("login") != OWNER:
            raise RuntimeError("Authenticated Gitee account differs from authorized owner")

    def repository(self, *, require_public=True):
        repo = self.request("GET", f"/repos/{REPOSITORY}", missing_ok=True)
        if repo is None:
            raise RuntimeError("Create the authorized Gitee repository first")
        if (repo.get("full_name") != REPOSITORY or repo.get("fork") is not False
                or repo.get("owner", {}).get("login") != OWNER):
            raise RuntimeError("Gitee repository identity is unexpected")
        if require_public and (repo.get("private") is not False or repo.get("public") is not True):
            raise RuntimeError("Gitee repository is not public")
        return repo

    def release(self, tag):
        return self.request("GET", f"/repos/{REPOSITORY}/releases/tags/{quote(tag, safe='')}", missing_ok=True)

    def attachments(self, release_id):
        return self.request("GET", f"/repos/{REPOSITORY}/releases/{int(release_id)}/attach_files",
                            params={"per_page": 100})

    def upload(self, release_id, file):
        with file.open("rb") as source:
            return self.request("POST", f"/repos/{REPOSITORY}/releases/{int(release_id)}/attach_files",
                                files={"file": (file.name, source, "application/octet-stream")})

    def publish(self, tag, commit, notes, files, manifest):
        title = release_title(tag, notes)
        self.ensure_owner()
        self.repository()
        release = self.release(tag)
        if release is None:
            release = self.request("POST", f"/repos/{REPOSITORY}/releases", data={
                "tag_name": tag, "target_commitish": commit,
                "name": title, "body": notes, "prerelease": "false",
            })
        if (release.get("tag_name") != tag or release.get("name") != title
                or release.get("target_commitish") != commit
                or release.get("body", "").strip() != notes.strip()
                or release.get("prerelease") is not False):
            raise RuntimeError("Existing Gitee release differs; immutable releases are never overwritten")
        assets = {asset["name"]: asset for asset in self.attachments(release["id"])}
        # Every APK and checksum is verified before an updater can see update.json.
        for file in [*files, manifest]:
            asset = assets.get(file.name)
            if asset is None:
                print(f"Uploading to Gitee: {file.name} ({file.stat().st_size:,} bytes)", flush=True)
                asset = self.upload(release["id"], file)
            if asset.get("name") != file.name:
                raise RuntimeError("Gitee attachment name differs")
            if asset.get("size") not in (None, file.stat().st_size):
                raise RuntimeError("Existing Gitee attachment size differs")
            url = asset.get("browser_download_url", download_url(tag, file.name))
            if url != download_url(tag, file.name):
                raise RuntimeError("Gitee attachment URL differs from the release")
            verify_download(file, url)
            print(f"Verified anonymous Gitee SHA-256: {file.name}", flush=True)
        latest = self.request("GET", f"/repos/{REPOSITORY}/releases/latest")
        if latest.get("tag_name") != tag or latest.get("prerelease") is not False:
            raise RuntimeError("Gitee latest release does not match the new version")
        names = {asset.get("name") for asset in latest.get("assets", [])}
        if not {file.name for file in [*files, manifest]}.issubset(names):
            raise RuntimeError("Gitee latest release is missing required assets")
        return latest


def extract_update_notes(notes):
    """Keep the reader-facing feature section out of technical Release tables."""
    feature_heading = re.search(r"^##\s+功能更新\s*$", notes, re.MULTILINE)
    if feature_heading is None:
        return notes.strip()
    section = notes[feature_heading.end():]
    next_heading = re.search(r"^##\s+", section, re.MULTILINE)
    if next_heading is not None:
        section = section[:next_heading.start()]
    section = re.sub(r"\*\*(.*?)\*\*", r"\1", section)
    section = re.sub(r"__(.*?)__", r"\1", section)
    section = re.sub(r"`([^`\n]+)`", r"\1", section)
    section = re.sub(r"^[ \t]*[-*+]\s+", "", section, flags=re.MULTILINE)
    return section.strip()


def make_update_manifest(version, build_number, notes, artifacts):
    if (not VERSION_TAG.fullmatch(f"v{version}") or type(build_number) is not int
            or build_number <= 0 or not isinstance(notes, str) or not notes.strip()):
        raise ValueError("Invalid update version, build number or release notes")
    architectures = {}
    for item in artifacts:
        abi = item["abi"]
        if (abi not in ABI_VERSION_OFFSETS or abi in architectures
                or item["version"] != version or item["build_number"] != build_number
                or item["version_code"] != ABI_VERSION_OFFSETS[abi] + build_number
                or item["package_name"] != PACKAGE_NAME
                or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
                or not isinstance(item["size_bytes"], int) or item["size_bytes"] <= 0):
            raise ValueError("APK metadata differs from update manifest version/package")
        architectures[abi] = {
            "url": download_url(f"v{version}", item["filename"]),
            "size": item["size_bytes"], "sha256": item["sha256"],
            "versionCode": item["version_code"],
        }
    if not architectures:
        raise ValueError("Update manifest requires at least one APK")
    update_notes = extract_update_notes(notes)
    if not update_notes:
        raise ValueError("Update manifest requires readable feature notes")
    return {"schemaVersion": 1, "versionName": version, "buildNumber": build_number,
            "packageName": PACKAGE_NAME, "certSha256": CERT_SHA256,
            "minSdk": 24, "releaseNotes": update_notes, "architectures": architectures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aapt", type=Path, default=DEFAULT_AAPT)
    parser.add_argument("--abi", choices=list(ABI_VERSION_OFFSETS), action="append",
                        help="ABI to publish; repeat for several (default: all split APKs)")
    parser.add_argument("--prepare-only", action="store_true", help="Package APKs and write manifest without network publication")
    args = parser.parse_args()
    version, build_number = read_version(ROOT / "pubspec.yaml")
    tag = f"v{version}"
    notes = (ROOT / "releases" / f"{tag}.md").read_text(encoding="utf-8")
    metadata = [package_release(ROOT, ROOT / "build/app/outputs/flutter-apk" / f"app-{abi}-release.apk", args.aapt)
                for abi in (args.abi or list(ABI_VERSION_OFFSETS))]
    release_dir = ROOT / "build/releases" / tag
    manifest = release_dir / "update.json"
    content = make_update_manifest(version, build_number, notes, metadata)
    write_sidecar(manifest, (json.dumps(content, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    if args.prepare_only:
        print(f"Prepared Gitee update manifest: {manifest}")
        return 0
    token = credentials()
    client = GiteeRelease(token)
    try:
        client.ensure_owner()
        client.repository()
        if git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
            raise RuntimeError("Current App tag must be annotated")
        head = git("rev-parse", "HEAD")
        tagged_commit = git("rev-parse", f"{tag}^{{commit}}")
        if git("diff", "--name-only", tagged_commit, head, "--", "pubspec.yaml", "lib", "android", "assets"):
            raise RuntimeError("App differs from version tag; build a new version")
        if git("show", f"{tagged_commit}:releases/{tag}.md").strip() != notes.strip():
            raise RuntimeError("Release notes changed after version tag")
        mirror_repository(token)
        files = []
        for item in metadata:
            file = release_dir / item["filename"]
            files.extend([file, file.with_suffix(".apk.sha256")])
        release = client.publish(tag, tagged_commit, notes, files, manifest)
    finally:
        client.session.close()
    # Explicitly exercise updater metadata without the authenticated API session.
    with requests.Session() as anonymous:
        anonymous.trust_env = False
        with anonymous.get(f"{API}/repos/{REPOSITORY}/releases/latest", timeout=(20, 60), allow_redirects=False) as response:
            if response.status_code != 200 or response.json().get("tag_name") != tag:
                raise RuntimeError("Anonymous Gitee updater metadata unavailable")
    report = {"repository": f"https://gitee.com/{REPOSITORY}", "tag": tag,
              "sourceCommit": tagged_commit, "releaseId": release["id"],
              "releasePage": f"https://gitee.com/{REPOSITORY}/releases/{tag}",
              "updateManifest": download_url(tag, "update.json"),
              "anonymousMetadataVerified": True, "anonymousDownloadsVerified": True,
              "architectures": content["architectures"]}
    (release_dir / "gitee-release.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Gitee release failed: {error}", file=sys.stderr)
        raise SystemExit(1)
