"""Publish a pushed App tag, notes, APK and checksum in the public source repo.

Uses GITCODE_TOKEN or the existing Git credential helper. Credentials and signed
storage URLs are kept in memory; uploads never receive the GitCode API token.
The CLI delegates to publish_public_release; GitCodeRelease remains reusable.
"""
import hashlib
import os
from pathlib import Path
import subprocess
from urllib.parse import quote, urlsplit

import requests


ROOT = Path(__file__).resolve().parents[1]
API = "https://api.gitcode.com/api/v5"


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True,
                            text=True, encoding="utf-8", errors="replace",
                            env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never"))
    if result.returncode:
        raise RuntimeError(f"Git operation failed: {arguments[0]}")
    return result.stdout.strip()


def credentials(remote):
    token = os.environ.get("GITCODE_TOKEN")
    if token:
        return token
    parsed = urlsplit(remote)
    result = subprocess.run(
        ["git", "credential", "fill"], cwd=ROOT,
        input=f"protocol=https\nhost=gitcode.com\npath={parsed.path.lstrip('/')}\n\n",
        capture_output=True, text=True, timeout=20,
        env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never"),
    )
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if not values.get("password"):
        raise RuntimeError("GitCode credential unavailable; configure GITCODE_TOKEN or Git credential manager")
    return values["password"]


class GitCodeRelease:
    def __init__(self, repository, token, tag):
        self.repository = repository
        self.endpoint = f"{API}/repos/{repository}"
        self.tag = quote(tag, safe="")
        self.session = requests.Session()
        self.session.headers["PRIVATE-TOKEN"] = token

    def request(self, method, suffix, *, missing_ok=False, **kwargs):
        try:
            response = self.session.request(method, self.endpoint + suffix,
                                            timeout=(20, 60), allow_redirects=False, **kwargs)
        except requests.RequestException:
            raise RuntimeError("GitCode API network request failed") from None
        with response:
            if missing_ok and response.status_code == 404:
                return None
            if not response.ok:
                raise RuntimeError(f"GitCode API request failed (HTTP {response.status_code})")
            try:
                return response.json()
            except ValueError:
                raise RuntimeError("GitCode API returned invalid JSON") from None

    def release(self):
        return self.request("GET", f"/releases/tags/{self.tag}", missing_ok=True)

    @staticmethod
    def secure_url(url):
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise RuntimeError("Attachment service returned an invalid HTTPS URL")
        return url

    def upload(self, file):
        upload = self.request("GET", f"/releases/{self.tag}/upload_url",
                              params={"file_name": file.name})
        url = self.secure_url(upload["url"])
        # A separate session excludes API headers and automatic .netrc auth.
        storage = requests.Session()
        storage.trust_env = False
        try:
            with file.open("rb") as source:
                with storage.put(url, headers=upload["headers"], data=source,
                                 timeout=(20, 180), allow_redirects=False) as response:
                    if not response.ok:
                        raise RuntimeError(f"Attachment upload failed (HTTP {response.status_code})")
        except requests.RequestException:
            raise RuntimeError("Attachment upload network request failed; rerun to resume") from None
        finally:
            storage.close()

    def verify_download(self, file, *, anonymous=False):
        filename = quote(file.name, safe="")
        if anonymous:
            url = f"https://gitcode.com/{self.repository}/releases/download/{self.tag}/{filename}"
        else:
            url = f"{self.endpoint}/releases/{self.tag}/attach_files/{filename}/download"
        expected = hashlib.sha256(file.read_bytes()).hexdigest()
        storage = requests.Session()
        storage.trust_env = False
        response = None
        try:
            # Public browser downloads must work without credentials. Storage
            # redirects always omit API authentication.
            download = storage.get if anonymous else self.session.get
            response = download(url, stream=True, timeout=(20, 60), allow_redirects=False)
            for _ in range(5):
                if response.status_code not in (301, 302, 303, 307, 308):
                    break
                location = self.secure_url(response.headers.get("Location", ""))
                response.close()
                response = storage.get(location, stream=True, timeout=(20, 60), allow_redirects=False)
            if response.status_code != 200:
                raise RuntimeError(f"Attachment verification failed (HTTP {response.status_code})")
            digest = hashlib.sha256()
            size = 0
            for chunk in response.iter_content(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
            if digest.hexdigest() != expected or size != file.stat().st_size:
                raise RuntimeError(f"Remote attachment differs from local file: {file.name}")
        except requests.RequestException:
            raise RuntimeError("Attachment verification network request failed; rerun to resume") from None
        finally:
            if response is not None:
                response.close()
            storage.close()

    def publish(self, tag, head, title, notes, files, *, expected_private=True):
        if not isinstance(expected_private, bool):
            raise RuntimeError("Expected repository privacy must be true or false")
        repo = self.request("GET", "")
        if repo.get("private") is not expected_private:
            raise RuntimeError("Repository privacy does not match requested publication mode")
        release = self.release()
        if release is None:
            release = self.request("POST", "/releases", json={
                "tag_name": tag, "target_commitish": head, "name": title,
                "body": notes, "release_status": "pre",
            })
        if release.get("body", "").strip() != notes.strip():
            raise RuntimeError("Existing release notes differ; do not overwrite a published version")
        if release.get("target_commitish") not in (head, "main"):
            raise RuntimeError("Release points to another commit")
        assets = {asset["name"] for asset in release.get("assets", [])}
        for file in files:
            if file.name not in assets:
                print(f"Uploading {file.name} ({file.stat().st_size:,} bytes)", flush=True)
                self.upload(file)
            self.verify_download(file, anonymous=not expected_private)
            print(f"Verified remote SHA256: {file.name}", flush=True)
        self.request("PATCH", f"/releases/{self.tag}", json={
            "name": title, "body": notes, "release_status": "latest",
        })
        final = self.release()
        if final.get("prerelease") or final.get("release_status") != "latest":
            raise RuntimeError("Release has not reached latest status")
        if not {file.name for file in files}.issubset({asset["name"] for asset in final.get("assets", [])}):
            raise RuntimeError("Release is missing uploaded attachments")
        return final


def main():
    # Keep the original command available; all publication uses the single
    # public source repository and its immutable App version tag.
    from publish_public_release import main as publish_public
    publish_public()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Release failed: {error}")
        raise SystemExit(1)
