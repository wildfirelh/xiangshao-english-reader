import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

TOOLS = str(Path(__file__).resolve().parent)
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import publish_gitee_release as publisher
import release_presentation


class GiteeManifestTests(unittest.TestCase):
    def item(self, abi="arm64-v8a", **changes):
        return {"abi": abi, "version": "1.4.0", "build_number": 5,
                "version_code": publisher.ABI_VERSION_OFFSETS[abi] + 5,
                "package_name": publisher.PACKAGE_NAME,
                "filename": f"xiangshao-english-reader-v1.4.0-build5-{abi}.apk",
                "sha256": "a" * 64, "size_bytes": 43_000_000, **changes}

    def test_manifest_separates_canonical_build_from_split_version_codes(self):
        items = [self.item(abi) for abi in publisher.ABI_VERSION_OFFSETS]
        result = publisher.make_update_manifest("1.4.0", 5, "中文说明", items)
        self.assertEqual(result["buildNumber"], 5)
        self.assertEqual(result["versionName"], "1.4.0")
        self.assertEqual(result["packageName"], publisher.PACKAGE_NAME)
        self.assertEqual(result["certSha256"], publisher.CERT_SHA256)
        self.assertEqual(result["minSdk"], 24)
        self.assertEqual(result["releaseNotes"], "中文说明")
        self.assertEqual(result["architectures"]["arm64-v8a"]["versionCode"], 2005)
        self.assertEqual(result["architectures"]["x86_64"]["versionCode"], 4005)
        self.assertTrue(all(value["url"].startswith(f"https://gitee.com/{publisher.REPOSITORY}/releases/download/v1.4.0/")
                            for value in result["architectures"].values()))

    def test_full_release_notes_keep_only_readable_features_in_update_manifest(self):
        notes = ("# 湘少英语三上点读 v1.4.0\n\n"
                 "## 功能更新\n\n"
                 "- **通知降音**：提示结束后恢复音量。\n"
                 "- 支持 `0.5x` 至 `2.0x` 六档倍速。\n\n"
                 "## 安装包\n\n| ABI | SHA-256 |\n| arm64 | abc |\n\n"
                 "## 开发验证\n\nflutter analyze 零告警。\n")
        result = publisher.make_update_manifest("1.4.0", 5, notes, [self.item()])
        self.assertEqual(result["releaseNotes"],
                         "通知降音：提示结束后恢复音量。\n支持 0.5x 至 2.0x 六档倍速。")
        self.assertNotIn("SHA-256", result["releaseNotes"])
        self.assertNotIn("flutter analyze", result["releaseNotes"])
        self.assertIn("## 安装包", notes)

    def test_simple_update_notes_are_preserved_and_trimmed(self):
        self.assertEqual(publisher.extract_update_notes("  中文功能说明\n第二行。\n"),
                         "中文功能说明\n第二行。")
        result = publisher.make_update_manifest("1.4.0", 5, "  中文说明  ", [self.item()])
        self.assertEqual(result["releaseNotes"], "中文说明")

    def test_rejects_wrong_version_package_hash_and_split_code(self):
        for change in ({"version": "1.3.0"}, {"build_number": 4}, {"version_code": 5},
                       {"package_name": "another.app"}, {"sha256": "bad"}, {"size_bytes": 0}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                publisher.make_update_manifest("1.4.0", 5, "说明", [self.item(**change)])

    def test_rejects_empty_artifacts_or_duplicate_abi(self):
        for artifacts in ([], [self.item(), self.item()]):
            with self.assertRaises(ValueError):
                publisher.make_update_manifest("1.4.0", 5, "说明", artifacts)

    def test_filename_path_traversal_and_unversioned_tag_rejected(self):
        for tag, filename in (("latest", "app.apk"), ("v1.4.0", "../secret")):
            with self.assertRaises(ValueError):
                publisher.download_url(tag, filename)

    def test_invalid_canonical_build_and_empty_notes_are_rejected(self):
        for version, number, notes in (("latest", 5, "说明"), ("1.4.0", True, "说明"),
                                       ("1.4.0", 0, "说明"), ("1.4.0", 5, "")):
            with self.subTest(version=version, number=number, notes=notes), self.assertRaises(ValueError):
                publisher.make_update_manifest(version, number, notes, [self.item()])


class GiteeCredentialsTests(unittest.TestCase):
    def test_environment_credentials_do_not_spawn_git(self):
        with patch.dict(os.environ, {"GITEE_TOKEN": " test-token "}, clear=True), \
             patch.object(publisher.subprocess, "run") as run:
            self.assertEqual(publisher.credentials(), "test-token")
        run.assert_not_called()

    def test_credential_manager_is_noninteractive_and_missing_secret_is_safe(self):
        result = subprocess.CompletedProcess([], 0, "username=user\npassword=secret\n", "")
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(publisher.subprocess, "run", return_value=result) as run:
            self.assertEqual(publisher.credentials(), "secret")
        self.assertEqual(run.call_args.kwargs["env"]["GCM_INTERACTIVE"], "never")
        self.assertTrue(run.call_args.kwargs["capture_output"])
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "secret-error")):
            with self.assertRaises(RuntimeError) as error:
                publisher.credentials()
        self.assertNotIn("secret-error", str(error.exception))

    def test_git_header_is_ephemeral_and_never_in_arguments(self):
        result = subprocess.CompletedProcess([], 0, "ok", "")
        with patch.object(publisher.subprocess, "run", return_value=result) as run:
            publisher.git("push", "gitee", "main", token="private-secret")
        self.assertNotIn("private-secret", repr(run.call_args.args))
        self.assertEqual(run.call_args.kwargs["env"]["GIT_CONFIG_KEY_0"], "http.https://gitee.com/.extraHeader")


class GiteeRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.client = publisher.GiteeRelease("test-token")
        self.addCleanup(self.client.session.close)
        self.repo = {"full_name": publisher.REPOSITORY, "fork": False,
                     "owner": {"login": publisher.OWNER}, "public": True, "private": False}

    def test_requires_existing_public_source_repo_without_changing_visibility(self):
        with patch.object(self.client, "request", return_value=self.repo) as request:
            self.assertEqual(self.client.repository(), self.repo)
        request.assert_called_once_with("GET", f"/repos/{publisher.REPOSITORY}", missing_ok=True)

    def test_private_fork_and_wrong_owner_never_published(self):
        for changes in ({"private": True}, {"public": False}, {"fork": True},
                        {"owner": {"login": "someone"}}, {"full_name": "other/repo"}):
            with self.subTest(changes=changes), patch.object(self.client, "request", return_value={**self.repo, **changes}):
                with self.assertRaises(RuntimeError):
                    self.client.repository()

    def test_wrong_authenticated_account_is_rejected(self):
        with patch.object(self.client, "request", return_value={"login": "someone"}):
            with self.assertRaisesRegex(RuntimeError, "authorized owner"):
                self.client.ensure_owner()


class GiteeMirrorTests(unittest.TestCase):
    def setUp(self):
        self.head = "b" * 40
        self.tag = "c" * 40
        self.refs = ""
        self.pushed = False
        self.calls = []

    def fake_git(self, *args, **kwargs):
        self.calls.append(args)
        if args == ("status", "--porcelain"):
            return ""
        if args in (("rev-parse", "HEAD"), ("rev-parse", "refs/heads/main")):
            return self.head
        if args == ("rev-parse", "refs/tags/v1.4.0^{}"):
            return self.head
        if args[0] == "for-each-ref":
            return f"refs/tags/v1.4.0 tag {self.tag}"
        if args[:2] == ("remote", "get-url"):
            return subprocess.CompletedProcess([], 0, publisher.REMOTE, "") if kwargs.get("check") is False else publisher.REMOTE
        if args == ("ls-remote", "gitee"):
            return self.refs if not self.pushed else f"{self.head}\trefs/heads/main\n{self.tag}\trefs/tags/v1.4.0"
        if args[0] == "fetch":
            return ""
        if args[0] == "merge-base":
            return subprocess.CompletedProcess([], 1, "", "")
        if args[0] == "push":
            self.assertNotIn("--force", args)
            self.assertNotIn("--mirror", args)
            self.assertIn("--atomic", args)
            self.pushed = True
            return ""
        self.fail(f"Unexpected Git call: {args}")

    def test_main_and_annotated_tags_are_pushed_without_rewriting(self):
        with patch.object(publisher, "git", side_effect=self.fake_git):
            self.assertEqual(publisher.mirror_repository("test-token"), self.head)
        self.assertTrue(self.pushed)

    def test_diverged_main_and_different_old_tag_are_rejected_without_push(self):
        for refs in (f"{'d' * 40}\trefs/heads/main", f"{'d' * 40}\trefs/tags/v1.4.0"):
            self.refs = refs
            with self.subTest(refs=refs), patch.object(publisher, "git", side_effect=self.fake_git):
                with self.assertRaises(RuntimeError):
                    publisher.mirror_repository("test-token")
            self.assertFalse(self.pushed)

    def test_dirty_worktree_is_rejected_before_network_access(self):
        with patch.object(publisher, "git", return_value=" M lib/main.dart") as git:
            with self.assertRaisesRegex(RuntimeError, "Commit source changes"):
                publisher.mirror_repository("test-token")
        git.assert_called_once_with("status", "--porcelain")


class GiteeDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / "app.apk"
        self.file.write_bytes(b"PK\x03\x04test apk")
        self.url = publisher.download_url("v1.4.0", self.file.name)

    def response(self, status, data=b"", **headers):
        response = Mock(status_code=status, headers=headers)
        response.iter_content.return_value = [data]
        return response

    def test_redirect_download_omits_credentials_and_cookies_and_verifies_full_bytes(self):
        first = self.response(302, Location="https://foruda.gitee.com/attachments/apk?signature=public")
        final = self.response(200, self.file.read_bytes())
        session = Mock()
        session.get.side_effect = [first, final]
        with patch.object(publisher.requests, "Session", return_value=session):
            publisher.verify_download(self.file, self.url)
        self.assertFalse(session.trust_env)
        self.assertEqual(session.cookies.clear.call_count, 2)
        self.assertTrue(all(not call.kwargs.get("allow_redirects") for call in session.get.call_args_list))
        self.assertTrue(all("headers" not in call.kwargs and "auth" not in call.kwargs for call in session.get.call_args_list))
        first.close.assert_called_once()
        final.close.assert_called_once()

    def test_html_login_response_and_corrupted_apk_fail_hash_verification(self):
        for data in (b"<html>login</html>", b"corrupted apk"):
            session = Mock()
            session.get.return_value = self.response(200, data)
            with self.subTest(data=data), patch.object(publisher.requests, "Session", return_value=session):
                with self.assertRaisesRegex(RuntimeError, "attachment differs"):
                    publisher.verify_download(self.file, self.url)

    def test_external_http_and_credential_urls_are_rejected(self):
        for url in ("http://gitee.com/download", "https://evil.example/file", "https://user:secret@gitee.com/file",
                    "https://gitee.com:444/file", "https://fakegitee.com/file"):
            with self.subTest(url=url), self.assertRaises(RuntimeError):
                publisher.secure_download_url(url)

    def test_redirect_chain_is_bounded(self):
        session = Mock()
        session.get.return_value = self.response(302, Location=self.url)
        with patch.object(publisher.requests, "Session", return_value=session):
            with self.assertRaises(RuntimeError):
                publisher.verify_download(self.file, self.url)
        self.assertEqual(session.get.call_count, 6)


class GiteePublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.apk = root / "app.apk"
        self.apk.write_bytes(b"apk bytes")
        self.checksum = root / "app.apk.sha256"
        self.checksum.write_text(hashlib.sha256(self.apk.read_bytes()).hexdigest())
        self.manifest = root / "update.json"
        self.manifest.write_text('{"schemaVersion":1}')
        self.files = [self.apk, self.checksum]
        self.release = {"id": 8, "tag_name": "v1.4.0", "target_commitish": "a" * 40,
                        "name": "湘少英语三上点读 v1.4.0", "body": "中文说明", "prerelease": False}
        self.client = publisher.GiteeRelease("test-token")
        self.addCleanup(self.client.session.close)

    def asset(self, file):
        return {"name": file.name, "size": file.stat().st_size,
                "browser_download_url": publisher.download_url(self.release["tag_name"], file.name)}

    def publish(self, existing=None, attachments=(), notes="中文说明"):
        latest = {**self.release, "assets": [self.asset(file) for file in [*self.files, self.manifest]]}
        with patch.object(self.client, "ensure_owner"), patch.object(self.client, "repository"), \
             patch.object(self.client, "release", return_value=existing), \
             patch.object(self.client, "attachments", return_value=list(attachments)), \
             patch.object(self.client, "request", side_effect=[self.release, latest] if existing is None else [latest]) as request, \
             patch.object(self.client, "upload", side_effect=lambda _, file: self.asset(file)) as upload, \
             patch.object(publisher, "verify_download") as verify:
            result = self.client.publish(self.release["tag_name"], "a" * 40, notes, self.files, self.manifest)
        return result, request, upload, verify

    def test_apks_are_verified_before_manifest_upload_and_latest_metadata(self):
        result, request, upload, verify = self.publish()
        self.assertEqual([call.args[1] for call in upload.call_args_list], [*self.files, self.manifest])
        self.assertEqual([call.args[0] for call in verify.call_args_list], [*self.files, self.manifest])
        self.assertEqual(request.call_args_list[0].kwargs["data"]["prerelease"], "false")
        self.assertEqual(request.call_args_list[0].kwargs["data"]["name"], "湘少英语三上点读 v1.4.0")
        self.assertEqual(request.call_args_list[-1].args, ("GET", f"/repos/{publisher.REPOSITORY}/releases/latest"))
        self.assertEqual(result["id"], 8)

    def test_new_app_name_is_published_from_the_versioned_notes_heading(self):
        notes = "# 小学英语点读 v1.5.0\n\n中文说明"
        self.release.update(tag_name="v1.5.0", name="小学英语点读 v1.5.0", body=notes)
        _, request, _, _ = self.publish(notes=notes)
        self.assertEqual(request.call_args_list[0].kwargs["data"]["name"], "小学英语点读 v1.5.0")

    def test_historical_heading_reuses_the_original_published_title(self):
        notes = "# 湘少英语三上点读 v1.4.0\n\n中文说明"
        existing = {**self.release, "body": notes}
        _, request, upload, _ = self.publish(existing, [self.asset(file) for file in [*self.files, self.manifest]],
                                            notes=notes)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(request.call_args.args[0], "GET")
        upload.assert_not_called()

    def test_rerun_reuses_immutable_release_and_verifies_existing_bytes(self):
        _, request, upload, verify = self.publish(self.release, [self.asset(file) for file in [*self.files, self.manifest]])
        upload.assert_not_called()
        self.assertEqual(request.call_count, 1)
        self.assertEqual(verify.call_count, 3)

    def test_registered_poster_prefix_reuses_apks_manifest_and_extra_image_attachment(self):
        prefix = "<!-- promotion:start -->\n![海报](https://example.com/poster.png)\n<!-- promotion:end -->"
        registry = self.apk.parent / "presentation.json"
        registry.write_text(json.dumps({"schemaVersion": 1, "releases": {
            "v1.4.0": {"gitee": {"prefix": prefix}},
        }}, ensure_ascii=False), encoding="utf-8")
        existing = {**self.release, "body": prefix + "\n\n中文说明"}
        attachments = [self.asset(file) for file in [*self.files, self.manifest]]
        attachments.append({"name": "poster.png", "size": 100,
                            "browser_download_url": "https://example.com/poster.png"})
        with patch.object(release_presentation, "REGISTRY", registry):
            _, request, upload, verify = self.publish(existing, attachments)
        upload.assert_not_called()
        self.assertEqual(request.call_count, 1)
        self.assertEqual(request.call_args.args[0], "GET")
        self.assertEqual(verify.call_count, 3)

    def test_registered_poster_does_not_allow_changes_to_original_release_notes(self):
        prefix = "<!-- promotion:start -->\n宣传图\n<!-- promotion:end -->"
        registry = self.apk.parent / "presentation.json"
        registry.write_text(json.dumps({"schemaVersion": 1, "releases": {
            "v1.4.0": {"gitee": {"prefix": prefix}},
        }}), encoding="utf-8")
        for body in (prefix + "\n\n修改说明", prefix + "\n\n中文说明\n额外内容"):
            with self.subTest(body=body), patch.object(release_presentation, "REGISTRY", registry):
                with self.assertRaisesRegex(RuntimeError, "immutable releases"):
                    self.publish({**self.release, "body": body})

    def test_different_notes_title_tag_commit_and_prerelease_are_never_overwritten(self):
        for changes in ({"body": "changed"}, {"target_commitish": "b" * 40},
                        {"name": "小学英语点读 v1.4.0"},
                        {"tag_name": "v1.3.0"}, {"prerelease": True}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.publish({**self.release, **changes})

    def test_corrupted_remote_apk_stops_before_update_manifest_upload(self):
        with patch.object(self.client, "ensure_owner"), patch.object(self.client, "repository"), \
             patch.object(self.client, "release", return_value=self.release), \
             patch.object(self.client, "attachments", return_value=[]), \
             patch.object(self.client, "upload", side_effect=lambda _, file: self.asset(file)) as upload, \
             patch.object(publisher, "verify_download", side_effect=RuntimeError("mismatched bytes")):
            with self.assertRaisesRegex(RuntimeError, "mismatched bytes"):
                self.client.publish("v1.4.0", "a" * 40, "中文说明", self.files, self.manifest)
        self.assertEqual([call.args[1] for call in upload.call_args_list], [self.apk])


if __name__ == "__main__":
    unittest.main()
