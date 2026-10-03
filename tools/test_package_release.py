import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.package_release import package_release


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "pubspec.yaml").write_text("version: 1.2.0+3\n", encoding="utf-8")
        self.apk = self.root / "app-arm64-v8a-release.apk"
        self.apk.write_bytes(b"example APK bytes")
        self.aapt = self.root / "aapt.exe"
        self.aapt.touch()

    def badging(self, version="1.2.0", code=2003, abi="arm64-v8a"):
        return subprocess.CompletedProcess(
            [], 0,
            stdout=f"package: name='com.example.reader' versionCode='{code}' versionName='{version}'\n"
                   f"native-code: '{abi}'\n",
            stderr="",
        )

    def test_versioned_name_hash_and_idempotence(self):
        with patch("tools.package_release.subprocess.run", return_value=self.badging()) as run:
            result = package_release(self.root, self.apk, self.aapt)
            repeated = package_release(self.root, self.apk, self.aapt)
        run.assert_called_with(
            [str(self.aapt), "dump", "badging", str(self.apk)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", check=False,
        )
        destination = self.root / "build/releases/v1.2.0/xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk"
        digest = hashlib.sha256(self.apk.read_bytes()).hexdigest()
        self.assertEqual(destination.read_bytes(), self.apk.read_bytes())
        self.assertEqual(result, repeated)
        self.assertEqual(result["sha256"], digest)
        self.assertEqual(result["size_bytes"], len(self.apk.read_bytes()))
        self.assertEqual(result["version_code"], 2003)
        self.assertEqual(destination.with_suffix(".apk.sha256").read_text(), f"{digest}  {destination.name}\n")
        self.assertEqual(json.loads(destination.with_suffix(".json").read_text()), result)

    def test_old_version_and_wrong_split_code_are_rejected(self):
        for badging in (
            self.badging(version="1.1.1"),
            self.badging(code=2002),
            self.badging(code=2003, abi="armeabi-v7a"),
        ):
            with self.subTest(badging=badging.stdout):
                with patch("tools.package_release.subprocess.run", return_value=badging):
                    with self.assertRaisesRegex(ValueError, "does not match"):
                        package_release(self.root, self.apk, self.aapt)
                self.assertFalse((self.root / "build/releases").exists())

    def test_existing_different_apk_is_not_overwritten(self):
        destination = self.root / "build/releases/v1.2.0/xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b"different APK bytes")
        with patch("tools.package_release.subprocess.run", return_value=self.badging()):
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                package_release(self.root, self.apk, self.aapt)
        self.assertEqual(destination.read_bytes(), b"different APK bytes")

    def test_x86_64_uses_flutter_split_offset(self):
        with patch("tools.package_release.subprocess.run", return_value=self.badging(code=4003, abi="x86_64")):
            result = package_release(self.root, self.apk, self.aapt)
        self.assertEqual(result["filename"], "xiangshao-english-reader-v1.2.0-build3-x86_64.apk")
        self.assertEqual(result["version_code"], 4003)


if __name__ == "__main__":
    unittest.main()
