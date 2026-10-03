import contextlib
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import requests

from tools import publish_gitcode_release as publisher


class FakeResponse:
    def __init__(self, status=200, payload=None, content=b"", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 400
        self.payload = payload
        self.content = content
        self.headers = headers or {}
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()

    def close(self):
        self.closed = True

    def json(self):
        return self.payload

    def iter_content(self, chunk_size):
        for offset in range(0, len(self.content), 3):
            yield self.content[offset:offset + 3]


class GitCodeReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / "xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk"
        self.apk.write_bytes(b"example APK bytes")
        self.checksum = self.apk.with_suffix(".apk.sha256")
        self.checksum.write_text(
            f"{hashlib.sha256(self.apk.read_bytes()).hexdigest()}  {self.apk.name}\n",
            encoding="utf-8",
        )
        self.files = [self.apk, self.checksum]
        self.token = "TEST-PRIVATE-TOKEN-DO-NOT-PRINT"
        self.signed_url = "https://storage.example.test/release?signature=TEST-SIGNED-SECRET"
        self.session = Mock(headers={})
        self.storage_sessions = []
        self.storage_get = Mock(side_effect=AssertionError("Unexpected external HTTP request"))
        self.storage_put = Mock(side_effect=AssertionError("Unexpected external HTTP request"))
        for method in ("request", "get"):
            getattr(self.session, method).side_effect = AssertionError("Unexpected API request")
        for target, attribute in (
            ("Session", "session_factory"),
            ("get", "module_get"),
            ("put", "module_put"),
        ):
            patcher = patch.object(publisher.requests, target)
            mocked = patcher.start()
            self.addCleanup(patcher.stop)
            setattr(self, attribute, mocked)
            mocked.side_effect = AssertionError("Unexpected external HTTP request")
        self.session_factory.side_effect = self.new_session
        self.api_session_created = False
        self.client = publisher.GitCodeRelease("test-owner/test-repo", self.token, "v1.2.0")
        self.notes = "本版增加教材点读。"
        self.head = "a" * 40

    def new_session(self):
        if not self.api_session_created:
            self.api_session_created = True
            return self.session
        storage = Mock(headers={}, get=self.storage_get, put=self.storage_put)
        self.storage_sessions.append(storage)
        return storage

    def tearDown(self):
        for storage in self.storage_sessions:
            self.assertFalse(storage.trust_env)
            self.assertNotIn("PRIVATE-TOKEN", storage.headers)
            storage.close.assert_called_once_with()
        self.module_get.assert_not_called()
        self.module_put.assert_not_called()

    def release(self, assets=(), status="pre"):
        return {
            "body": self.notes,
            "target_commitish": self.head,
            "release_status": status,
            "prerelease": status != "latest",
            "assets": [{"name": name} for name in assets],
        }

    def configure_publish(self, initial, downloads=None, *, expected_private=True):
        events = []
        releases = iter([initial, self.release([file.name for file in self.files], "latest")])

        def api(method, url, **kwargs):
            self.assertFalse(kwargs["allow_redirects"])
            suffix = url.removeprefix(self.client.endpoint)
            if (method, suffix) == ("GET", ""):
                return FakeResponse(payload={"private": expected_private})
            if (method, suffix) == ("GET", "/releases/tags/v1.2.0"):
                release = next(releases)
                return FakeResponse(404) if release is None else FakeResponse(payload=release)
            if (method, suffix) == ("POST", "/releases"):
                events.append("create")
                self.assertEqual(kwargs["json"]["release_status"], "pre")
                return FakeResponse(payload=self.release())
            if (method, suffix) == ("GET", "/releases/v1.2.0/upload_url"):
                name = kwargs["params"]["file_name"]
                return FakeResponse(payload={"url": self.signed_url, "headers": {"Content-Type": "application/octet-stream", "X-File": name}})
            if (method, suffix) == ("PATCH", "/releases/v1.2.0"):
                events.append("latest")
                self.assertEqual(kwargs["json"]["release_status"], "latest")
                return FakeResponse(payload=self.release([file.name for file in self.files], "latest"))
            self.fail(f"Unexpected API operation: {method} {suffix}")

        def upload(url, **kwargs):
            self.assertEqual(url, self.signed_url)
            self.assertNotIn("PRIVATE-TOKEN", kwargs["headers"])
            self.assertFalse(kwargs["allow_redirects"])
            name = kwargs["headers"]["X-File"]
            self.assertEqual(kwargs["data"].read(), next(file for file in self.files if file.name == name).read_bytes())
            events.append(f"upload:{name}")
            return FakeResponse()

        def download(url, **kwargs):
            self.assertFalse(kwargs["allow_redirects"])
            if expected_private:
                name = url.split("/attach_files/", 1)[1].removesuffix("/download")
            else:
                prefix = f"https://gitcode.com/{self.client.repository}/releases/download/v1.2.0/"
                self.assertTrue(url.startswith(prefix))
                name = url.removeprefix(prefix)
            file = next(file for file in self.files if file.name == name)
            events.append(f"verify:{name}")
            content = (downloads or {}).get(name, file.read_bytes())
            return FakeResponse(content=content)

        self.session.request.side_effect = api
        if expected_private:
            self.session.get.side_effect = download
        else:
            self.storage_get.side_effect = download
        self.storage_put.side_effect = upload
        return events

    def publish(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.client.publish("v1.2.0", self.head, "Test release", self.notes, self.files, **kwargs)

    def assert_redacted(self, error):
        message = str(error)
        self.assertNotIn(self.token, message)
        self.assertNotIn(self.signed_url, message)
        self.assertNotIn("TEST-SIGNED-SECRET", message)

    def test_upload_uses_storage_headers_without_private_token(self):
        headers = {"Content-Type": "application/octet-stream", "Authorization": "TEST-OBS-SIGNATURE"}
        self.session.request.side_effect = None
        self.session.request.return_value = FakeResponse(payload={"url": self.signed_url, "headers": headers})
        self.storage_put.side_effect = None
        self.storage_put.return_value = FakeResponse()
        self.client.upload(self.apk)
        self.assertEqual(self.session.headers["PRIVATE-TOKEN"], self.token)
        self.assertEqual(self.storage_put.call_args.kwargs["headers"], headers)
        self.assertNotIn(self.token, repr(self.storage_put.call_args.kwargs["headers"]))
        self.assertFalse(self.storage_put.call_args.kwargs["allow_redirects"])
        self.session.request.assert_called_once()
        self.assertFalse(self.session.request.call_args.kwargs["allow_redirects"])
        self.session.get.assert_not_called()

    def test_download_redirects_never_forward_api_token(self):
        first = FakeResponse(302, headers={"Location": self.signed_url})
        second_url = "https://storage2.example.test/file?signature=SECOND-SECRET"
        second = FakeResponse(307, headers={"Location": second_url})
        final = FakeResponse(content=self.apk.read_bytes())
        self.session.get.side_effect = None
        self.session.get.return_value = first
        self.storage_get.side_effect = [second, final]
        self.client.verify_download(self.apk)
        self.session.get.assert_called_once_with(
            f"{self.client.endpoint}/releases/v1.2.0/attach_files/{self.apk.name}/download",
            stream=True, timeout=(20, 60), allow_redirects=False,
        )
        self.assertEqual(self.storage_get.call_args_list, [
            call(self.signed_url, stream=True, timeout=(20, 60), allow_redirects=False),
            call(second_url, stream=True, timeout=(20, 60), allow_redirects=False),
        ])
        self.assertTrue(all(response.closed for response in (first, second, final)))

    def test_network_errors_do_not_expose_credentials_or_signed_urls(self):
        leaked = f"{self.signed_url} token={self.token}"
        self.session.request.side_effect = requests.RequestException(leaked)
        with self.assertRaises(RuntimeError) as error:
            self.client.request("GET", "")
        self.assert_redacted(error.exception)
        self.assertTrue(error.exception.__suppress_context__)
        self.session.request.side_effect = None
        self.session.request.return_value = FakeResponse(payload={"url": self.signed_url, "headers": {}})
        self.storage_put.side_effect = requests.RequestException(leaked)
        with self.assertRaises(RuntimeError) as error:
            self.client.upload(self.apk)
        self.assert_redacted(error.exception)
        self.assertTrue(error.exception.__suppress_context__)
        self.session.get.side_effect = None
        self.session.get.return_value = FakeResponse(302, headers={"Location": self.signed_url})
        self.storage_get.side_effect = requests.RequestException(leaked)
        with self.assertRaises(RuntimeError) as error:
            self.client.verify_download(self.apk)
        self.assert_redacted(error.exception)
        self.assertTrue(error.exception.__suppress_context__)

    def test_bad_attachment_urls_are_rejected_before_external_request(self):
        for url in ("http://storage.example.test/file", "https://name:secret@storage.example.test/file", "/relative/file"):
            with self.subTest(url=url):
                self.session.request.side_effect = None
                self.session.request.return_value = FakeResponse(payload={"url": url, "headers": {}})
                with self.assertRaisesRegex(RuntimeError, "invalid HTTPS URL"):
                    self.client.upload(self.apk)
        self.storage_put.assert_not_called()

    def test_both_attachments_uploaded_and_verified_before_latest(self):
        events = self.configure_publish(None)
        result = self.publish()
        self.assertEqual(events, [
            "create", f"upload:{self.apk.name}", f"verify:{self.apk.name}",
            f"upload:{self.checksum.name}", f"verify:{self.checksum.name}", "latest",
        ])
        self.assertEqual(result["release_status"], "latest")
        self.assertEqual(self.storage_put.call_count, 2)

    def test_remote_hash_mismatch_never_marks_latest(self):
        for file in self.files:
            with self.subTest(file=file.name):
                events = self.configure_publish(self.release([item.name for item in self.files]), {file.name: b"wrong bytes"})
                with self.assertRaisesRegex(RuntimeError, "Remote attachment differs"):
                    self.publish()
                self.assertNotIn("latest", events)
                self.assertNotIn("create", events)
        self.storage_put.assert_not_called()

    def test_existing_complete_release_skips_uploads_and_reverifies(self):
        events = self.configure_publish(self.release([file.name for file in self.files], "latest"))
        result = self.publish()
        self.assertEqual(events, [f"verify:{self.apk.name}", f"verify:{self.checksum.name}", "latest"])
        self.assertEqual(result["release_status"], "latest")
        self.storage_put.assert_not_called()
        self.assertFalse(any(item.args[0] == "POST" for item in self.session.request.call_args_list))

    def test_public_download_is_anonymous_from_first_request_through_redirects(self):
        first = FakeResponse(302, headers={"Location": self.signed_url})
        final = FakeResponse(content=self.apk.read_bytes())
        self.storage_get.side_effect = [first, final]
        self.client.verify_download(self.apk, anonymous=True)
        self.assertEqual(self.storage_get.call_args_list, [
            call(f"https://gitcode.com/{self.client.repository}/releases/download/v1.2.0/{self.apk.name}",
                 stream=True, timeout=(20, 60), allow_redirects=False),
            call(self.signed_url, stream=True, timeout=(20, 60), allow_redirects=False),
        ])
        self.session.get.assert_not_called()
        self.assertTrue(first.closed)
        self.assertTrue(final.closed)

    def test_public_publish_verifies_both_attachments_anonymously_before_latest(self):
        events = self.configure_publish(None, expected_private=False)
        result = self.publish(expected_private=False)
        self.assertEqual(events, [
            "create", f"upload:{self.apk.name}", f"verify:{self.apk.name}",
            f"upload:{self.checksum.name}", f"verify:{self.checksum.name}", "latest",
        ])
        self.assertEqual(result["release_status"], "latest")
        self.session.get.assert_not_called()
        self.assertEqual(self.storage_get.call_count, 2)
        for request in self.storage_get.call_args_list:
            self.assertNotIn("headers", request.kwargs)
            self.assertNotIn("auth", request.kwargs)
            self.assertNotIn(self.token, repr(request))

    def test_repository_privacy_must_match_exact_boolean_mode(self):
        for expected_private in (True, False):
            for actual in (not expected_private, None, 0, 1, "true", "false"):
                with self.subTest(expected_private=expected_private, actual=actual):
                    self.session.request.reset_mock()
                    self.session.request.side_effect = None
                    payload = {} if actual is None else {"private": actual}
                    self.session.request.return_value = FakeResponse(payload=payload)
                    with self.assertRaisesRegex(RuntimeError, "privacy does not match"):
                        self.publish(expected_private=expected_private)
                    self.session.request.assert_called_once()
        self.session.get.assert_not_called()
        self.storage_get.assert_not_called()
        self.storage_put.assert_not_called()


if __name__ == "__main__":
    unittest.main()
