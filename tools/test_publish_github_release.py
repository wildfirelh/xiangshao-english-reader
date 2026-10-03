import hashlib
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
import publish_github_release as publisher


class GitHubRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.client = publisher.GitHubRelease("test-token")
        self.addCleanup(self.client.session.close)
        self.repo = f"{publisher.DEFAULT_OWNER}/{publisher.PUBLIC_NAME}"
        self.details = {"full_name": self.repo, "owner": {"login": publisher.DEFAULT_OWNER},
                        "private": False, "fork": False}

    def test_creates_empty_named_repository_with_expected_privacy(self):
        with patch.object(self.client, "request", side_effect=[None, self.details]) as request:
            self.client.ensure_repository(self.repo, private=False)
        payload = request.call_args.kwargs["json"]
        self.assertEqual(payload["name"], publisher.PUBLIC_NAME)
        self.assertIs(payload["private"], False)
        self.assertIs(payload["auto_init"], False)
        self.assertNotIn("license_template", payload)

    def test_never_changes_privacy_identity_or_forked_repository(self):
        for replacement in ({"private": True}, {"private": "false"}, {"fork": True},
                            {"full_name": "someone/other"}, {"owner": {"login": "someone"}}):
            with self.subTest(replacement=replacement), \
                 patch.object(self.client, "request", return_value={**self.details, **replacement}) as request:
                with self.assertRaises(RuntimeError):
                    self.client.ensure_repository(self.repo, private=False)
                self.assertEqual(request.call_count, 1)

    def test_credentials_and_account_must_match(self):
        with patch.dict(os.environ, {"GH_TOKEN": "environment-token", "GITHUB_TOKEN": "other"}, clear=True), \
             patch.object(publisher.subprocess, "run") as run:
            self.assertEqual(publisher.credentials(), "environment-token")
            run.assert_not_called()
        completed = subprocess.CompletedProcess([], 0, stdout="cli-secret\n", stderr="")
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(publisher.subprocess, "run", return_value=completed) as run:
            self.assertEqual(publisher.credentials(), "cli-secret")
            self.assertEqual(run.call_args.args[0][0], str(publisher.GH))
            self.assertTrue(run.call_args.kwargs["capture_output"])
        with patch.object(self.client, "request", return_value={"login": "another-account"}):
            with self.assertRaisesRegex(RuntimeError, "differs from GH_OWNER"):
                self.client.owner(publisher.DEFAULT_OWNER)


class GitHubMirrorTests(unittest.TestCase):
    def setUp(self):
        self.repo = f"{publisher.DEFAULT_OWNER}/{publisher.PUBLIC_NAME}"
        self.head, self.tag_object, self.app_commit = "b" * 40, "c" * 40, "a" * 40
        self.remote_refs = ""
        self.paths = "README.md\nreleases/v1.2.0.md"
        self.pushed = False
        self.calls = []

    def fake_git(self, cwd, *args, **kwargs):
        self.calls.append(args)
        if args == ("status", "--porcelain"):
            return ""
        if args in (("rev-parse", "HEAD"), ("rev-parse", "refs/heads/main")):
            return self.head
        if args == ("rev-parse", "refs/tags/v1.2.0^{}"):
            return self.app_commit
        if args[0] == "for-each-ref":
            return f"refs/tags/v1.2.0 tag {self.tag_object}"
        if args[0] == "log" or args == ("ls-files",):
            return self.paths
        if args == ("ls-files", "--others", "--exclude-standard"):
            return ""
        if args[:2] == ("remote", "get-url"):
            url = f"https://github.com/{self.repo}.git"
            return subprocess.CompletedProcess([], 0, stdout=url, stderr="") if kwargs.get("check") is False else url
        if args == ("ls-remote", "github"):
            return self.remote_refs if not self.pushed else (
                f"{self.head}\trefs/heads/main\n{self.tag_object}\trefs/tags/v1.2.0\n"
                f"{self.app_commit}\trefs/tags/v1.2.0^{{}}")
        if args[0] == "push":
            self.assertIn("--atomic", args)
            self.assertNotIn("--force", args)
            self.assertNotIn("--mirror", args)
            self.pushed = True
            return ""
        if args[0] == "fetch":
            return ""
        if args[0] == "merge-base":
            return subprocess.CompletedProcess([], 1, stdout="", stderr="")
        self.fail(f"Unexpected Git call: {args}")

    def mirror(self):
        with patch.object(publisher, "git_command", side_effect=self.fake_git):
            return publisher.mirror_repository(Path("mock"), self.repo, "mock-token", public=True)

    def test_empty_repository_receives_main_and_annotated_tag_without_force(self):
        self.assertEqual(self.mirror(), {"main": self.head, "annotatedVersionTags": 1})
        self.assertTrue(self.pushed)

    def test_different_tag_and_divergent_main_are_rejected_without_push(self):
        for refs in (f"{'d' * 40}\trefs/tags/v1.2.0", f"{'d' * 40}\trefs/heads/main"):
            with self.subTest(refs=refs):
                self.remote_refs = refs
                with self.assertRaises(RuntimeError):
                    self.mirror()
                self.assertFalse(self.pushed)

    def test_public_history_cannot_include_deleted_source(self):
        self.paths += "\nlib/main.dart"
        with self.assertRaisesRegex(RuntimeError, "only release documentation"):
            self.mirror()
        self.assertFalse(any(args[0] == "push" for args in self.calls))

    def test_git_credentials_are_ephemeral_and_absent_from_arguments(self):
        complete = subprocess.CompletedProcess([], 0, stdout="ok", stderr="")
        with patch.object(publisher.subprocess, "run", return_value=complete) as run:
            publisher.git_command(Path("mock"), "push", "github", "main", token="secret-token")
        args, kwargs = run.call_args
        self.assertNotIn("secret-token", repr(args))
        self.assertEqual(kwargs["env"]["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraHeader")
        self.assertNotIn("secret-token", kwargs["env"]["GIT_CONFIG_VALUE_0"])


class GitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.apk = root / "xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk"
        self.apk.write_bytes(b"mock apk")
        self.checksum = self.apk.with_suffix(".apk.sha256")
        self.checksum.write_text(hashlib.sha256(self.apk.read_bytes()).hexdigest() + "  " + self.apk.name + "\n")
        self.files = [self.apk, self.checksum]
        self.client = publisher.GitHubRelease("mock-token")
        self.addCleanup(self.client.session.close)
        self.repo = f"{publisher.DEFAULT_OWNER}/{publisher.PUBLIC_NAME}"
        self.commit = "a" * 40
        self.release = {"id": 7, "tag_name": "v1.2.0", "name": "湘少英语三上点读 v1.2.0",
                        "target_commitish": self.commit, "body": "中文说明", "draft": True, "prerelease": False}

    def publish(self, *, existing=None, assets=()):
        final = {**self.release, "draft": False}
        with patch.object(self.client, "ensure_repository"), \
             patch.object(self.client, "release", return_value=existing), \
             patch.object(self.client, "request", side_effect=[self.release, final] if existing is None else [final]) as request, \
             patch.object(self.client, "list_items", side_effect=[
                 list(assets), [{"name": file.name, "refreshed": True} for file in self.files]]), \
             patch.object(self.client, "upload", side_effect=lambda repo, release, file: {"name": file.name}) as upload, \
             patch.object(self.client, "verify_download") as verify:
            result = self.client.publish(self.repo, "v1.2.0", self.commit, "中文说明", self.files)
        return result, request, upload, verify

    def test_draft_verified_before_publication_and_anonymous_after(self):
        result, request, upload, verify = self.publish()
        self.assertEqual(result[1], 2)
        self.assertEqual(upload.call_count, 2)
        self.assertTrue(request.call_args_list[0].kwargs["json"]["draft"])
        self.assertEqual(request.call_args_list[-1].kwargs["json"],
                         {"draft": False, "prerelease": False, "make_latest": "true"})
        self.assertEqual([call.kwargs["anonymous"] for call in verify.call_args_list], [False, False, True, True])
        self.assertTrue(all(call.args[1].get("refreshed") for call in verify.call_args_list[2:]))
        self.assertTrue(all(not call.args[1].get("refreshed") for call in verify.call_args_list[:2]))

    def test_published_release_reused_without_upload_or_patch(self):
        existing = {**self.release, "draft": False}
        result, request, upload, verify = self.publish(existing=existing, assets=[{"name": f.name} for f in self.files])
        self.assertEqual(result[0], existing)
        request.assert_not_called()
        upload.assert_not_called()
        self.assertTrue(all(call.kwargs["anonymous"] for call in verify.call_args_list))

    def test_existing_release_content_mismatch_never_clobbered(self):
        for changes in ({"body": "changed"}, {"target_commitish": "b" * 40}, {"prerelease": True}):
            with self.subTest(changes=changes), \
                 patch.object(self.client, "ensure_repository"), \
                 patch.object(self.client, "release", return_value={**self.release, **changes}), \
                 patch.object(self.client, "request") as request, \
                 patch.object(self.client, "upload") as upload:
                with self.assertRaisesRegex(RuntimeError, "refusing to overwrite"):
                    self.client.publish(self.repo, "v1.2.0", self.commit, "中文说明", self.files)
                request.assert_not_called()
                upload.assert_not_called()

    def test_published_release_missing_assets_and_unexpected_assets_are_rejected(self):
        for existing, assets in (
            ({**self.release, "draft": False}, []),
            (self.release, [{"name": "textbook.pdf"}]),
        ):
            with self.subTest(assets=assets), \
                 patch.object(self.client, "ensure_repository"), \
                 patch.object(self.client, "release", return_value=existing), \
                 patch.object(self.client, "list_items", return_value=assets), \
                 patch.object(self.client, "request") as request, \
                 patch.object(self.client, "upload") as upload:
                with self.assertRaises(RuntimeError):
                    self.client.publish(self.repo, "v1.2.0", self.commit, "中文说明", self.files)
                request.assert_not_called()
                upload.assert_not_called()

    def test_only_apk_and_its_sidecar_can_be_published(self):
        with patch.object(self.client, "ensure_repository") as ensure:
            with self.assertRaisesRegex(RuntimeError, "only the versioned APK"):
                self.client.publish(self.repo, "v1.2.0", self.commit, "中文说明", self.files + [Path("source.zip")])
        ensure.assert_not_called()

    def test_draft_is_found_through_authenticated_release_list(self):
        with patch.object(self.client, "request", return_value=None), \
             patch.object(self.client, "list_items", return_value=[self.release]):
            self.assertEqual(self.client.release(self.repo, "v1.2.0"), self.release)

    def test_download_hash_verified_and_auth_never_sent_to_storage(self):
        asset = {"id": 99, "size": self.apk.stat().st_size, "state": "uploaded",
                 "digest": "sha256:" + hashlib.sha256(self.apk.read_bytes()).hexdigest(),
                 "browser_download_url": f"https://github.com/{self.repo}/releases/download/v1.2.0/{self.apk.name}"}
        redirect = Mock(status_code=302, headers={"Location": "https://release-assets.githubusercontent.com/mock?signature=hidden"})
        response = Mock(status_code=200)
        response.iter_content.return_value = [self.apk.read_bytes()]
        storage = Mock()
        storage.get.return_value = response
        with patch.object(self.client.session, "get", return_value=redirect) as get, \
             patch.object(publisher.requests, "Session", return_value=storage):
            self.client.verify_download(self.repo, asset, self.apk, anonymous=False)
        self.assertEqual(get.call_args.kwargs["headers"], {"Accept": "application/octet-stream"})
        self.assertIs(storage.trust_env, False)
        self.assertNotIn("headers", storage.get.call_args.kwargs)
        self.assertNotIn("auth", storage.get.call_args.kwargs)
        response.iter_content.return_value = [b"different file"]
        with patch.object(publisher.requests, "Session", return_value=storage), \
             self.assertRaisesRegex(RuntimeError, "differs from local"):
            self.client.verify_download(self.repo, asset, self.apk, anonymous=True)

    def test_unapproved_upload_endpoint_rejected_before_credentials_sent(self):
        with patch.object(self.client.session, "post") as post:
            with self.assertRaisesRegex(RuntimeError, "unexpected upload"):
                self.client.upload(self.repo, {"id": 7, "upload_url": "https://other-host/assets"}, self.apk)
        post.assert_not_called()

    def test_anonymous_download_retries_short_publication_404_then_verifies_hash(self):
        asset = {"id": 99, "size": self.apk.stat().st_size, "state": "uploaded",
                 "browser_download_url": f"https://github.com/{self.repo}/releases/download/v1.2.0/{self.apk.name}"}
        missing = [Mock(status_code=404), Mock(status_code=404)]
        success = Mock(status_code=200)
        success.iter_content.return_value = [self.apk.read_bytes()]
        storage = Mock()
        storage.get.side_effect = [*missing, success]
        with patch.object(publisher.requests, "Session", return_value=storage), \
             patch.object(publisher.time, "sleep") as sleep, \
             patch.object(self.client.session, "get") as authenticated_get:
            self.client.verify_download(self.repo, asset, self.apk, anonymous=True)
        self.assertEqual(storage.get.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 4])
        self.assertTrue(all(response.close.called for response in missing))
        authenticated_get.assert_not_called()

    def test_anonymous_404_retry_is_bounded_and_other_failures_are_immediate(self):
        asset = {"id": 99, "size": self.apk.stat().st_size, "state": "uploaded",
                 "browser_download_url": f"https://github.com/{self.repo}/releases/download/v1.2.0/{self.apk.name}"}
        for status, attempts, sleeps in ((404, 3, 2), (403, 1, 0), (500, 1, 0)):
            with self.subTest(status=status):
                storage = Mock()
                storage.get.return_value = Mock(status_code=status)
                with patch.object(publisher.requests, "Session", return_value=storage), \
                     patch.object(publisher.time, "sleep") as sleep:
                    with self.assertRaisesRegex(RuntimeError, f"HTTP {status}"):
                        self.client.verify_download(self.repo, asset, self.apk, anonymous=True)
                self.assertEqual(storage.get.call_count, attempts)
                self.assertEqual(sleep.call_count, sleeps)

    def test_metadata_and_hash_mismatch_never_retry(self):
        asset = {"id": 99, "size": self.apk.stat().st_size, "state": "uploaded",
                 "browser_download_url": f"https://github.com/{self.repo}/releases/download/v1.2.0/{self.apk.name}"}
        storage = Mock()
        storage.get.return_value = Mock(status_code=200)
        storage.get.return_value.iter_content.return_value = [b"bad hash"]
        with patch.object(publisher.requests, "Session", return_value=storage), \
             patch.object(publisher.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "differs from local"):
                self.client.verify_download(self.repo, asset, self.apk, anonymous=True)
            self.assertEqual(storage.get.call_count, 1)
            storage.get.reset_mock()
            with self.assertRaisesRegex(RuntimeError, "metadata differs"):
                self.client.verify_download(self.repo, {**asset, "size": 0}, self.apk, anonymous=True)
            storage.get.assert_not_called()
            sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
