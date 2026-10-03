"""Publish APKs and notes to the public download repository; keep source private."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

import requests

from package_release import DEFAULT_AAPT, package_release, read_version
from publish_gitcode_release import API, GitCodeRelease, ROOT, credentials, git


SOURCE_REPOSITORY = "gcw_rw0AAl7X/xiangshao-english-reader"
PUBLIC_REPOSITORY = "gcw_rw0AAl7X/xiangshao-english-reader-releases"
PUBLIC_REMOTE = f"https://gitcode.com/{PUBLIC_REPOSITORY}.git"
PUBLIC_PAGE = f"https://gitcode.com/{PUBLIC_REPOSITORY}"
GITHUB_PUBLIC_PAGE = "https://github.com/wildfirelh/xiangshao-english-reader-releases"
CHECKOUT = ROOT / "build/releases/.public-release-repository"
ALLOWED_PUBLIC_PATH = re.compile(
    r"(?:README\.md|releases/v\d+\.\d+\.\d+\.md|"
    r"checksums/xiangshao-english-reader-v\d+\.\d+\.\d+-build\d+-"
    r"(?:arm64-v8a|armeabi-v7a|x86_64)\.apk\.sha256)"
)


def validate_public_paths(paths):
    rejected = [path for path in paths if path and not ALLOWED_PUBLIC_PATH.fullmatch(path)]
    if rejected:
        raise RuntimeError("Public repository must contain only release documentation and checksums")


def public_git(*args, check=True, anonymous=False):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    if anonymous:
        for key in list(environment):
            if key in ("GIT_ASKPASS", "SSH_ASKPASS", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT") or key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
                environment.pop(key, None)
        environment.update(GIT_ASKPASS="", SSH_ASKPASS="", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    result = subprocess.run(["git", *args], cwd=CHECKOUT, capture_output=True,
                            text=True, encoding="utf-8", errors="replace",
                            env=environment)
    if check and result.returncode:
        raise RuntimeError(f"Public repository Git operation failed: {args[0]}")
    return result.stdout.strip() if check else result


def ensure_public_repository(client):
    repo = client.request("GET", "", missing_ok=True)
    if repo is None:
        try:
            with client.session.post(f"{API}/user/repos", json={
                "name": "xiangshao-english-reader-releases", "path": "xiangshao-english-reader-releases",
                "description": "湘少英语三上点读：公开 APK、版本说明与 SHA-256 校验。",
                "private": False, "auto_init": False, "default_branch": "main",
            }, timeout=(20, 60), allow_redirects=False) as response:
                if not response.ok:
                    raise RuntimeError(f"Create public repository failed (HTTP {response.status_code})")
        except requests.RequestException:
            raise RuntimeError("Create public repository network request failed") from None
        repo = client.request("GET", "")
    if repo.get("full_name") != PUBLIC_REPOSITORY or repo.get("private") is not False:
        raise RuntimeError("Expected the authorized public APK-only repository")


def source_snapshot(tag, token):
    if git("remote", "get-url", "origin") != f"https://gitcode.com/{SOURCE_REPOSITORY}.git":
        raise RuntimeError("Source origin does not match the private source repository")
    source = GitCodeRelease(SOURCE_REPOSITORY, token, tag)
    try:
        if source.request("GET", "").get("private") is not True:
            raise RuntimeError("Source repository must remain private")
    finally:
        source.session.close()
    if git("status", "--porcelain"):
        raise RuntimeError("Commit and push publishing changes before publishing")
    head = git("rev-parse", "HEAD")
    tagged_commit = git("rev-parse", f"{tag}^{{commit}}")
    refs = dict(line.split()[::-1] for line in git(
        "ls-remote", "origin", "refs/heads/main", f"refs/tags/{tag}^{{}}"
    ).splitlines())
    if refs.get("refs/heads/main") != head or refs.get(f"refs/tags/{tag}^{{}}") != tagged_commit:
        raise RuntimeError("Push source main and the annotated App version tag before publishing")
    # Publishing/documentation fixes may follow the existing App tag. The App
    # itself and its resources must still be exactly the version that was tagged.
    if git("diff", "--name-only", tagged_commit, head, "--", "pubspec.yaml", "lib", "android", "assets"):
        raise RuntimeError("App or textbook changed after its version tag; build a new version")
    return tagged_commit


def prepare_public_docs(tag, apk, notes):
    if not (CHECKOUT / ".git").is_dir():
        CHECKOUT.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(["git", "clone", PUBLIC_REMOTE, str(CHECKOUT)],
                                capture_output=True, text=True,
                                env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never"))
        if result.returncode:
            raise RuntimeError("Clone public release repository failed")
    if public_git("remote", "get-url", "origin") != PUBLIC_REMOTE:
        raise RuntimeError("Public checkout points to another repository")
    validate_public_paths(public_git("ls-files").splitlines())
    validate_public_paths(public_git("ls-files", "--others", "--exclude-standard").splitlines())
    if public_git("status", "--porcelain"):
        raise RuntimeError("Public documentation checkout has unfinished changes; review before retrying")
    public_git("fetch", "origin")
    if public_git("rev-parse", "--verify", "HEAD", check=False).returncode == 0:
        public_git("pull", "--ff-only", "origin", "main")
    else:
        public_git("symbolic-ref", "HEAD", "refs/heads/main")
    public_git("config", "user.name", git("config", "user.name"))
    public_git("config", "user.email", git("config", "user.email"))
    notes_name = f"releases/{tag}.md"
    if public_git("tag", "--list", tag):
        if public_git("show", f"{tag}:{notes_name}").strip() != notes.strip():
            raise RuntimeError("Existing public version tag has different notes; do not replace it")
    download = f"{PUBLIC_PAGE}/releases/download/{quote(tag, safe='')}/{quote(apk.name, safe='')}"
    github_download = f"{GITHUB_PUBLIC_PAGE}/releases/download/{quote(tag, safe='')}/{quote(apk.name, safe='')}"
    readme = (
        "# 湘少英语三上点读 · 安装包下载\n\n"
        "英语课本点读应用，支持离线音频、单句点读、整页连读、单元目录与阅读进度保存。\n\n"
        f"## 当前版本：{tag}\n\n"
        f"- [从 AtomGit 下载 Android ARM64 APK]({download})\n"
        f"- [从 GitHub 下载 Android ARM64 APK]({github_download})\n"
        f"- [查看本版功能更新]({notes_name})\n"
        f"- [AtomGit 发布版本]({PUBLIC_PAGE}/releases) · [GitHub 发布版本]({GITHUB_PUBLIC_PAGE}/releases)\n"
        f"- [SHA-256 校验文件](checksums/{apk.name}.sha256)\n\n"
        "本仓库公开提供安装包、功能更新说明和校验文件。APK 与校验文件位于 Release 附件中。\n"
    )
    files = {"README.md": readme, notes_name: notes,
             f"checksums/{apk.name}.sha256": apk.with_suffix(".apk.sha256").read_text(encoding="utf-8")}
    validate_public_paths(files)
    for name, text in files.items():
        path = CHECKOUT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text.rstrip() + "\n", encoding="utf-8", newline="\n")
    public_git("add", "--", *files.keys())
    validate_public_paths(public_git("ls-files").splitlines())
    if public_git("diff", "--cached", "--name-only"):
        public_git("commit", "-m", f"Publish {tag} download information and release notes")
    if not public_git("tag", "--list", tag):
        public_git("tag", "-a", tag, "-F", notes_name)
    public_git("push", "--atomic", "origin", "main", tag)
    return public_git("rev-parse", f"{tag}^{{commit}}")


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
    # Verify unauthenticated Git access too; an HTML shell returning 200 alone
    # cannot prove that its repository contents are publicly accessible.
    result = public_git("-c", "credential.helper=", "-c", "core.askPass=", "-c", "http.extraHeader=",
                        "ls-remote", "--exit-code", PUBLIC_REMOTE, "refs/heads/main", check=False, anonymous=True)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Public documentation cannot be accessed without Git credentials")


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
    client = GitCodeRelease(PUBLIC_REPOSITORY, token, tag)
    try:
        ensure_public_repository(client)
        public_commit = prepare_public_docs(tag, apk, notes)
        verify_anonymous_pages()
        release = client.publish(tag, public_commit, f"湘少英语三上点读 {tag}", notes,
                                 [apk, apk.with_suffix(".apk.sha256")], expected_private=False)
    finally:
        client.session.close()
    report = {"tag": tag, "sourceCommit": source_commit, "sourceRemainsPrivate": True,
              "publicCommit": public_commit, "repository": PUBLIC_PAGE,
              "releasePage": f"{PUBLIC_PAGE}/releases", "releaseStatus": release["release_status"],
              "apk": apk.name, "sha256": metadata["sha256"],
              "anonymousPagesVerified": True, "anonymousDownloadsVerified": True}
    (apk.parent / "public-gitcode-release.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Public release failed: {error}")
        raise SystemExit(1)
