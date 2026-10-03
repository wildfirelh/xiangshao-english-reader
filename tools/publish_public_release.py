"""Publish the versioned APK alongside source in the public AtomGit repository.

Repository visibility is changed deliberately outside this publishing command.
The command requires the authorized repository to already be public and keeps
App tags, historical notes and signed APK bytes unchanged.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

import requests

from package_release import DEFAULT_AAPT, package_release, read_version
from publish_gitcode_release import GitCodeRelease, ROOT, credentials, git


SOURCE_REPOSITORY = "gcw_rw0AAl7X/xiangshao-english-reader"
PUBLIC_REPOSITORY = SOURCE_REPOSITORY
PUBLIC_REMOTE = f"https://gitcode.com/{PUBLIC_REPOSITORY}.git"
PUBLIC_PAGE = f"https://gitcode.com/{PUBLIC_REPOSITORY}"


def public_git(*args, check=True, anonymous=False):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    if anonymous:
        for key in list(environment):
            if key in ("GIT_ASKPASS", "SSH_ASKPASS", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT") or key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
                environment.pop(key, None)
        environment.update(GIT_ASKPASS="", SSH_ASKPASS="", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", env=environment)
    if check and result.returncode:
        raise RuntimeError(f"Public repository Git operation failed: {args[0]}")
    return result.stdout.strip() if check else result


def ensure_public_repository(client):
    repo = client.request("GET", "")
    if repo.get("full_name") != PUBLIC_REPOSITORY or repo.get("private") is not False:
        raise RuntimeError("Expected the authorized public source-and-release repository")
    return repo


def source_snapshot(tag, token):
    if git("remote", "get-url", "origin") != PUBLIC_REMOTE:
        raise RuntimeError("Source origin does not match the authorized public repository")
    source = GitCodeRelease(SOURCE_REPOSITORY, token, tag)
    try:
        ensure_public_repository(source)
    finally:
        source.session.close()
    if git("status", "--porcelain"):
        raise RuntimeError("Commit and push publishing changes before publishing")
    head = git("rev-parse", "HEAD")
    if head != git("rev-parse", "refs/heads/main"):
        raise RuntimeError("Check out main before publishing")
    if git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise RuntimeError("App version tag must remain annotated")
    tag_object = git("rev-parse", f"refs/tags/{tag}")
    tagged_commit = git("rev-parse", f"{tag}^{{commit}}")
    refs = dict(line.split()[::-1] for line in git(
        "ls-remote", "origin", "refs/heads/main", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"
    ).splitlines())
    if (refs.get("refs/heads/main") != head or refs.get(f"refs/tags/{tag}") != tag_object
            or refs.get(f"refs/tags/{tag}^{{}}") != tagged_commit):
        raise RuntimeError("Push source main and the unchanged annotated App version tag before publishing")
    # Publishing/documentation changes may follow the existing App tag. App and
    # textbook content must still match the tagged version that produced the APK.
    if git("diff", "--name-only", tagged_commit, head, "--", "pubspec.yaml", "lib", "android", "assets"):
        raise RuntimeError("App or textbook changed after its version tag; build a new version")
    return tagged_commit


def verify_anonymous_pages():
    with requests.Session() as anonymous:
        anonymous.trust_env = False
        for suffix in ("", "/releases"):
            try:
                with anonymous.get(PUBLIC_PAGE + suffix, timeout=(20, 60), allow_redirects=False) as response:
                    if response.status_code != 200:
                        raise RuntimeError(f"Anonymous public page failed (HTTP {response.status_code})")
            except requests.RequestException:
                raise RuntimeError("Anonymous page verification network request failed") from None
    result = public_git("-c", "credential.helper=", "-c", "core.askPass=", "-c", "http.extraHeader=",
                        "ls-remote", "--exit-code", PUBLIC_REMOTE, "refs/heads/main", check=False, anonymous=True)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Public source cannot be accessed without Git credentials")


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
    token = credentials(git("remote", "get-url", "origin"))
    source_commit = source_snapshot(tag, token)
    if git("show", f"{source_commit}:releases/{tag}.md").strip() != notes.strip():
        raise RuntimeError("Release notes changed after their App version tag")
    verify_anonymous_pages()
    client = GitCodeRelease(PUBLIC_REPOSITORY, token, tag)
    try:
        ensure_public_repository(client)
        release = client.publish(tag, source_commit, f"湘少英语三上点读 {tag}", notes,
                                 [apk, apk.with_suffix(".apk.sha256")], expected_private=False)
    finally:
        client.session.close()
    report = {"tag": tag, "sourceCommit": source_commit, "sourcePublic": True,
              "repository": PUBLIC_PAGE, "releasePage": f"{PUBLIC_PAGE}/releases",
              "releaseStatus": release["release_status"], "apk": apk.name,
              "sha256": metadata["sha256"], "anonymousPagesVerified": True,
              "anonymousDownloadsVerified": True}
    (apk.parent / "public-gitcode-release.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Public release failed: {error}")
        raise SystemExit(1)
