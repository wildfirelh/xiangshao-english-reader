import contextlib
import hashlib
import io
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
import publish_github_release as publisher


class ReleaseTitleTests(unittest.TestCase):
    def test_versioned_first_heading_preserves_the_release_app_name(self):
        for tag, name in (("v1.2.0", "湘少英语三上点读"),
                          ("v1.4.0", "湘少英语三上点读"),
                          ("v1.5.0", "小学英语点读")):
            with self.subTest(tag=tag):
                self.assertEqual(publisher.release_title(tag, f"# {name} {tag}\n\n中文说明"),
                                 f"{name} {tag}")

    def test_notes_without_a_first_heading_keep_the_legacy_title(self):
        for notes in ("中文说明", "", "中文说明\n# 小学英语点读 v1.5.0"):
            with self.subTest(notes=notes):
                self.assertEqual(publisher.release_title("v1.5.0", notes),
                                 "湘少英语三上点读 v1.5.0")

    def test_heading_with_missing_name_or_wrong_version_is_rejected(self):
        for notes in ("# 小学英语点读 v1.4.0", "# v1.5.0", "# 小学英语点读"):
            with self.subTest(notes=notes), self.assertRaises(ValueError):
                publisher.release_title("v1.5.0", notes)


class GitHubRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.client = publisher.GitHubRelease("test-token")
        self.addCleanup(self.client.session.close)
        self.repo = f"{publisher.DEFAULT_OWNER}/{publisher.PUBLIC_NAME}"
        self.details = {"full_name": self.repo, "owner": {"login": publisher.DEFAULT_OWNER},
                        "private": False, "fork": False}

    def test_uses_the_existing_public_source_repository_without_creation(self):
        with patch.object(self.client, "request", return_value=self.details) as request:
            self.client.ensure_repository(self.repo, private=False)
        request.assert_called_once_with("GET", f"/repos/{self.repo}")
        self.assertEqual(publisher.PUBLIC_NAME, publisher.SOURCE_NAME)
        self.assertNotIn("-releases", self.repo)

    def test_rejects_old_download_repository_and_private_mode_before_api_access(self):
        with patch.object(self.client, "request") as request:
            for repository, private in (
                (self.repo + "-releases", False), ("someone/other", False), (self.repo, True),
            ):
                with self.subTest(repository=repository, private=private):
                    with self.assertRaisesRegex(RuntimeError, "authorized public"):
                        self.client.ensure_repository(repository, private=private)
        request.assert_not_called()

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
            return publisher.mirror_repository(publisher.ROOT, self.repo, "mock-token")

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

    def test_the_same_repository_mirrors_full_source_history(self):
        self.paths += "\nlib/main.dart\nassets/textbooks/xiangshao_3_1/book.json"
        self.assertEqual(self.mirror()["main"], self.head)
        self.assertTrue(self.pushed)

    def test_another_checkout_or_repository_cannot_be_mirrored(self):
        with patch.object(publisher, "git_command") as run:
            for cwd, repository in ((Path("mock"), self.repo), (publisher.ROOT, self.repo + "-releases")):
                with self.subTest(cwd=cwd, repository=repository):
                    with self.assertRaisesRegex(RuntimeError, "authorized source"):
                        publisher.mirror_repository(cwd, repository, "mock-token")
        run.assert_not_called()

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

    def publish(self, *, existing=None, assets=(), notes="中文说明"):
        final = {**self.release, "draft": False}
        with patch.object(self.client, "ensure_repository"), \
             patch.object(self.client, "release", return_value=existing), \
             patch.object(self.client, "request", side_effect=[self.release, final] if existing is None else [final]) as request, \
             patch.object(self.client, "list_items", side_effect=[
                 list(assets), [{"name": file.name, "refreshed": True} for file in self.files]]), \
             patch.object(self.client, "upload", side_effect=lambda repo, release, file: {"name": file.name}) as upload, \
             patch.object(self.client, "verify_download") as verify:
            result = self.client.publish(self.repo, self.release["tag_name"], self.commit, notes, self.files)
        return result, request, upload, verify

    def test_draft_verified_before_publication_and_anonymous_after(self):
        result, request, upload, verify = self.publish()
        self.assertEqual(result[1], 2)
        self.assertEqual(upload.call_count, 2)
        self.assertTrue(request.call_args_list[0].kwargs["json"]["draft"])
        self.assertEqual(request.call_args_list[0].kwargs["json"]["target_commitish"], self.commit)
        self.assertEqual(request.call_args_list[0].kwargs["json"]["name"], "湘少英语三上点读 v1.2.0")
        self.assertEqual(request.call_args_list[-1].kwargs["json"],
                         {"draft": False, "prerelease": False, "make_latest": "true"})
        self.assertEqual([call.kwargs["anonymous"] for call in verify.call_args_list], [False, False, True, True])
        self.assertTrue(all(call.args[1].get("refreshed") for call in verify.call_args_list[2:]))
        self.assertTrue(all(not call.args[1].get("refreshed") for call in verify.call_args_list[:2]))

    def test_new_app_name_is_published_from_the_versioned_notes_heading(self):
        self.apk = self.apk.with_name("xiangshao-english-reader-v1.5.0-build6-arm64-v8a.apk")
        self.apk.write_bytes(b"mock apk")
        self.checksum = self.apk.with_suffix(".apk.sha256")
        self.checksum.write_text(hashlib.sha256(self.apk.read_bytes()).hexdigest())
        self.files = [self.apk, self.checksum]
        notes = "# 小学英语点读 v1.5.0\n\n中文说明"
        self.release.update(tag_name="v1.5.0", name="小学英语点读 v1.5.0", body=notes)
        _, request, _, _ = self.publish(notes=notes)
        self.assertEqual(request.call_args_list[0].kwargs["json"]["name"], "小学英语点读 v1.5.0")

    def test_historical_heading_reuses_the_original_published_title(self):
        notes = "# 湘少英语三上点读 v1.2.0\n\n中文说明"
        existing = {**self.release, "body": notes, "draft": False}
        _, request, upload, _ = self.publish(existing=existing, assets=[{"name": f.name} for f in self.files],
                                            notes=notes)
        request.assert_not_called()
        upload.assert_not_called()

    def test_published_release_reused_without_upload_or_patch(self):
        existing = {**self.release, "draft": False}
        result, request, upload, verify = self.publish(existing=existing, assets=[{"name": f.name} for f in self.files])
        self.assertEqual(result[0], existing)
        request.assert_not_called()
        upload.assert_not_called()
        self.assertTrue(all(call.kwargs["anonymous"] for call in verify.call_args_list))

    def test_existing_release_content_mismatch_never_clobbered(self):
        for changes in ({"body": "changed"}, {"name": "小学英语点读 v1.2.0"},
                        {"target_commitish": "b" * 40}, {"prerelease": True}):
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


class GitHubSourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.head = "b" * 40
        self.app_commit = "a" * 40
        self.status = ""
        self.tag_kind = "tag"
        self.changed_paths = ""
        self.branch_head = self.head
        self.ancestor_result = 0
        self.calls = []

    def fake_git(self, cwd, *args, **kwargs):
        self.calls.append(args)
        if args == ("status", "--porcelain"):
            return self.status
        if args == ("rev-parse", "HEAD"):
            return self.head
        if args == ("rev-parse", "refs/heads/main"):
            return self.branch_head
        if args == ("cat-file", "-t", "refs/tags/v1.4.0"):
            return self.tag_kind
        if args == ("rev-parse", "v1.4.0^{commit}"):
            return self.app_commit
        if args == ("merge-base", "--is-ancestor", self.app_commit, self.head):
            return subprocess.CompletedProcess([], self.ancestor_result)
        if args == ("diff", "--name-only", self.app_commit, self.head, "--",
                    "pubspec.yaml", "lib", "android", "assets"):
            return self.changed_paths
        self.fail(f"Unexpected Git call: {args}")

    def snapshot(self):
        with patch.object(publisher, "git_command", side_effect=self.fake_git), \
             patch.object(publisher.requests, "Session") as session, \
             patch.object(publisher, "credentials") as credentials:
            result = publisher.source_snapshot("v1.4.0")
        session.assert_not_called()
        credentials.assert_not_called()
        self.assertFalse(any(args[0] in ("remote", "ls-remote", "fetch", "push")
                             for args in self.calls))
        return result

    def test_local_tag_validation_needs_no_atomgit_remote_credentials_or_network(self):
        self.assertEqual(self.snapshot(), self.app_commit)

    def test_dirty_worktree_wrong_branch_and_lightweight_tag_are_rejected(self):
        for attribute, value in (("status", " M README.md"), ("branch_head", "c" * 40),
                                 ("tag_kind", "commit")):
            with self.subTest(attribute=attribute):
                original = getattr(self, attribute)
                setattr(self, attribute, value)
                try:
                    with self.assertRaises(RuntimeError):
                        self.snapshot()
                finally:
                    setattr(self, attribute, original)

    def test_app_changes_after_version_tag_are_rejected(self):
        for path in ("pubspec.yaml", "lib/main.dart", "android/app/build.gradle.kts",
                     "assets/textbooks/xiangshao_3_1/book.json"):
            with self.subTest(path=path):
                self.changed_paths = path
                with self.assertRaisesRegex(RuntimeError, "changed after"):
                    self.snapshot()

    def test_tag_outside_main_history_is_rejected(self):
        self.ancestor_result = 1
        with self.assertRaisesRegex(RuntimeError, "current main history"):
            self.snapshot()

    def test_invalid_tag_is_rejected_without_git_or_network(self):
        with patch.object(publisher, "git_command") as git, \
             patch.object(publisher.requests, "Session") as session:
            with self.assertRaisesRegex(RuntimeError, "Invalid App version tag"):
                publisher.source_snapshot("latest")
        git.assert_not_called()
        session.assert_not_called()


class GitHubMainTests(unittest.TestCase):
    def test_one_source_repo_is_mirrored_and_release_targets_its_app_tag(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = "原版中文版本说明"
            (root / "releases").mkdir()
            (root / "releases/v1.2.0.md").write_text(notes, encoding="utf-8")
            apk = root / "build/releases/v1.2.0/xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk"
            apk.parent.mkdir(parents=True)
            app_commit, main_commit = "a" * 40, "b" * 40
            repository = "wildfirelh/xiangshao-english-reader"
            client = Mock()
            client.owner.return_value = "wildfirelh"
            client.publish.return_value = ({"id": 7}, 2)
            with patch.object(publisher, "ROOT", root), \
                 patch.object(sys, "argv", ["publish_github_release.py"]), \
                 patch.object(publisher, "read_version", return_value=("1.2.0", 3)), \
                 patch.object(publisher, "package_release", return_value={"filename": apk.name, "sha256": "test-digest"}), \
                 patch.object(publisher, "credentials", return_value="gh-test-token"), \
                 patch.object(publisher, "source_snapshot", return_value=app_commit) as snapshot, \
                 patch.object(publisher, "git", return_value=notes) as git, \
                 patch.object(publisher, "mirror_repository", return_value={"main": main_commit, "annotatedVersionTags": 1}) as mirror, \
                 patch.object(publisher, "verify_anonymous_pages") as verify, \
                 patch.object(publisher, "GitHubRelease", return_value=client), \
                 contextlib.redirect_stdout(io.StringIO()):
                publisher.main()
            snapshot.assert_called_once_with("v1.2.0")
            git.assert_called_once_with("show", f"{app_commit}:releases/v1.2.0.md")
            mirror.assert_called_once_with(root, repository, "gh-test-token")
            self.assertEqual(client.publish.call_args.args[:3], (repository, "v1.2.0", app_commit))
            self.assertTrue(all(call.args == (repository,) and call.kwargs == {"private": False}
                                for call in client.ensure_repository.call_args_list))
            verify.assert_called_once_with(repository, "v1.2.0")
            report = json.loads((apk.parent / "github-release.json").read_text(encoding="utf-8"))
            self.assertEqual(report["sourceCommit"], app_commit)
            self.assertEqual(report["sourceMirror"]["main"], main_commit)
            self.assertTrue(report["sourcePublic"])
            self.assertNotIn("publicMirror", report)
            self.assertNotIn("sourceRemainsPrivate", report)


if __name__ == "__main__":
    unittest.main()
