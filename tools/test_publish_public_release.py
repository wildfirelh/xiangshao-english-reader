import subprocess
import sys
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


# The CLI's sibling imports must work both under discovery and module execution.
TOOLS = str(Path(__file__).resolve().parent)
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import publish_public_release as publisher


class FakeResponse:
    def __init__(self, status=200):
        self.status_code = status
        self.ok = 200 <= status < 300

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        pass


class FakeAnonymousSession:
    def __init__(self, get):
        self.get = get
        self.trust_env = True
        self.headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()

    def close(self):
        pass


class PublicReleaseScopeTests(unittest.TestCase):
    def test_only_public_release_documents_and_checksums_are_allowed(self):
        publisher.validate_public_paths([
            "README.md", "releases/v1.2.0.md",
            "checksums/xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk.sha256",
            "checksums/xiangshao-english-reader-v1.2.0-build3-armeabi-v7a.apk.sha256",
            "checksums/xiangshao-english-reader-v1.2.0-build3-x86_64.apk.sha256",
        ])
        forbidden = [
            "lib/main.dart", "assets/textbooks/book.json", "assets/images/page.webp",
            "assets/audios/one.mp3", "textbooks/book.pdf", "book.PDF",
            ".env", ".env.volc", ".env.volc.example", "android/key.properties",
            "android/app/build.gradle.kts", "tools/publish_public_release.py",
            "pubspec.yaml", "README.md/../lib/main.dart", "../README.md",
            "releases/v1.2.0.md.bak", "checksums/source.zip.sha256",
            "xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk",
        ]
        for path in forbidden:
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                publisher.validate_public_paths(["README.md", path])

    def test_existing_repository_must_be_the_authorized_public_repository(self):
        client = Mock()
        client.request.return_value = {"full_name": publisher.PUBLIC_REPOSITORY, "private": False}
        publisher.ensure_public_repository(client)
        client.session.post.assert_not_called()
        for repo in (
            {"full_name": publisher.SOURCE_REPOSITORY, "private": False},
            {"full_name": "another-owner/xiangshao-english-reader-releases", "private": False},
            {"full_name": publisher.PUBLIC_REPOSITORY, "private": True},
            {"full_name": publisher.PUBLIC_REPOSITORY, "private": None},
            {"full_name": publisher.PUBLIC_REPOSITORY, "private": "false"},
        ):
            with self.subTest(repo=repo):
                client.request.return_value = repo
                with self.assertRaises(RuntimeError):
                    publisher.ensure_public_repository(client)
        client.session.post.assert_not_called()

    def test_creation_requests_only_the_named_public_release_repository(self):
        client = Mock()
        client.request.side_effect = [None, {"full_name": publisher.PUBLIC_REPOSITORY, "private": False}]
        client.session.post.return_value = FakeResponse()
        publisher.ensure_public_repository(client)
        args, kwargs = client.session.post.call_args
        self.assertEqual(args, (f"{publisher.API}/user/repos",))
        self.assertEqual(kwargs["json"]["name"], "xiangshao-english-reader-releases")
        self.assertEqual(kwargs["json"]["path"], "xiangshao-english-reader-releases")
        self.assertIs(kwargs["json"]["private"], False)
        self.assertIs(kwargs["json"]["auto_init"], False)
        self.assertFalse(kwargs["allow_redirects"])


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.head = "b" * 40
        self.app_commit = "a" * 40
        self.tag = "v1.2.0"
        self.source = Mock()
        self.source.request.return_value = {"private": True}
        self.changed = []
        self.origin = f"https://gitcode.com/{publisher.SOURCE_REPOSITORY}.git"

    def fake_git(self, *args):
        if args == ("remote", "get-url", "origin"):
            return self.origin
        if args == ("status", "--porcelain"):
            return ""
        if args == ("rev-parse", "HEAD"):
            return self.head
        if args == ("rev-parse", f"{self.tag}^{{commit}}"):
            return self.app_commit
        if args == ("ls-remote", "origin", "refs/heads/main", f"refs/tags/{self.tag}^{{}}"):
            return f"{self.head}\trefs/heads/main\n{self.app_commit}\trefs/tags/{self.tag}^{{}}"
        if args[:2] == ("diff", "--name-only"):
            self.assertEqual(args, (
                "diff", "--name-only", self.app_commit, self.head, "--",
                "pubspec.yaml", "lib", "android", "assets",
            ))
            protected = args[args.index("--") + 1:]
            return "\n".join(
                path for path in self.changed
                if any(path == prefix or path.startswith(prefix + "/") for prefix in protected)
            )
        self.fail(f"Unexpected Git operation: {args}")

    def snapshot(self):
        with patch.object(publisher, "git", side_effect=self.fake_git), \
             patch.object(publisher, "GitCodeRelease", return_value=self.source) as factory:
            result = publisher.source_snapshot(self.tag, "mock-token")
        factory.assert_called_once_with(publisher.SOURCE_REPOSITORY, "mock-token", self.tag)
        self.source.session.close.assert_called()
        return result

    def test_publisher_and_documentation_commits_after_app_tag_are_allowed(self):
        self.changed = [
            "AGENTS.md", "README.md", "CHANGELOG.md", "tools/publish_public_release.py",
            "tools/test_publish_public_release.py",
        ]
        self.assertNotEqual(self.head, self.app_commit)
        self.assertEqual(self.snapshot(), self.app_commit)

    def test_any_app_or_textbook_change_after_app_tag_is_rejected(self):
        for path in ("lib/main.dart", "assets/book.json", "android/app/build.gradle.kts", "pubspec.yaml"):
            with self.subTest(path=path):
                self.changed = [path]
                with self.assertRaisesRegex(RuntimeError, "changed after"):
                    self.snapshot()

    def test_source_must_remain_private(self):
        for value in (False, None, "true", 1):
            with self.subTest(privacy=value):
                self.source.request.return_value = {"private": value}
                with self.assertRaisesRegex(RuntimeError, "remain private"):
                    self.snapshot()
                self.source.session.close.assert_called()

    def test_different_source_origin_is_rejected_before_api_access(self):
        self.origin = publisher.PUBLIC_REMOTE
        with patch.object(publisher, "git", side_effect=self.fake_git), \
             patch.object(publisher, "GitCodeRelease") as factory:
            with self.assertRaisesRegex(RuntimeError, "private source repository"):
                publisher.source_snapshot(self.tag, "mock-token")
        factory.assert_not_called()


class AnonymousPublicAccessTests(unittest.TestCase):
    def check_pages(self, result):
        get = Mock(return_value=FakeResponse())
        session = FakeAnonymousSession(get)
        with patch.object(publisher.requests, "get", side_effect=AssertionError("Use anonymous Session")), \
             patch.object(publisher.requests, "Session", return_value=session) as session_factory, \
             patch.object(publisher, "public_git", return_value=result) as public_git:
            publisher.verify_anonymous_pages()
        session_factory.assert_called_once_with()
        self.assertIs(session.trust_env, False)
        self.assertEqual(get.call_count, 2)
        self.assertEqual([call.args[0] for call in get.call_args_list], [
            publisher.PUBLIC_PAGE, publisher.PUBLIC_PAGE + "/releases",
        ])
        for invocation in get.call_args_list:
            self.assertNotIn("auth", invocation.kwargs)
            self.assertNotIn("cookies", invocation.kwargs)
            self.assertNotIn("headers", invocation.kwargs)
            self.assertFalse(invocation.kwargs["allow_redirects"])
        args, kwargs = public_git.call_args
        self.assertIn("credential.helper=", args)
        self.assertIn("core.askPass=", args)
        self.assertIn("http.extraHeader=", args)
        self.assertIn("ls-remote", args)
        self.assertIn(publisher.PUBLIC_REMOTE, args)
        self.assertIn("refs/heads/main", args)
        self.assertFalse(kwargs["check"])
        self.assertTrue(kwargs["anonymous"])

    def test_anonymous_pages_also_require_git_main_ref(self):
        self.check_pages(subprocess.CompletedProcess([], 0, stdout="a" * 40 + "\trefs/heads/main\n"))

    def test_html_200_does_not_allow_missing_anonymous_git_access(self):
        for result in (
            subprocess.CompletedProcess([], 128, stdout=""),
            subprocess.CompletedProcess([], 0, stdout=""),
        ):
            with self.subTest(returncode=result.returncode), \
                 self.assertRaisesRegex(RuntimeError, "without Git credentials"):
                self.check_pages(result)

    def test_anonymous_git_removes_credential_environment_injections(self):
        fake_environment = {
            "PATH": "mock-path", "GIT_ASKPASS": "mock-git-askpass", "SSH_ASKPASS": "mock-ssh-askpass",
            "GIT_CONFIG_PARAMETERS": "mock-config", "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "http.extraHeader", "GIT_CONFIG_VALUE_0": "mock-header",
            "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "mock-helper",
        }
        completed = subprocess.CompletedProcess([], 0, stdout="mock-main-ref", stderr="")
        with patch.object(publisher.os, "environ", fake_environment), \
             patch.object(publisher.subprocess, "run", return_value=completed) as run:
            result = publisher.public_git(
                "-c", "credential.helper=", "-c", "core.askPass=", "-c", "http.extraHeader=",
                "ls-remote", "--exit-code", publisher.PUBLIC_REMOTE, "refs/heads/main",
                anonymous=True, check=False,
            )
        self.assertIs(result, completed)
        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment["PATH"], "mock-path")
        self.assertEqual(environment["GIT_ASKPASS"], "")
        self.assertEqual(environment["SSH_ASKPASS"], "")
        self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        self.assertNotIn("GIT_CONFIG_PARAMETERS", environment)
        self.assertNotIn("GIT_CONFIG_COUNT", environment)
        self.assertFalse(any(key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) for key in environment))
        self.assertEqual(fake_environment["GIT_ASKPASS"], "mock-git-askpass")


if __name__ == "__main__":
    unittest.main()
