import json
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = str(Path(__file__).resolve().parent)
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
from release_presentation import release_body_matches


class ReleasePresentationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.registry = Path(self.temp.name) / "releases.json"
        self.notes = "# 小学英语点读 v1.7.1\n\n原版功能说明。"
        self.prefix = ("<!-- promotion:start -->\n"
                       "![宣传图](https://raw.githubusercontent.com/owner/repo/"
                       + "a" * 40 + "/docs/promo/v1.7.1-poster.png)\n"
                       "[下载](https://github.com/owner/repo/releases/tag/v1.7.1)\n"
                       "<!-- promotion:end -->")
        self.write_registry({"schemaVersion": 1, "releases": {
            "v1.7.1": {"github": {"prefix": self.prefix},
                       "gitee": {"prefix": self.prefix.replace("github.com", "gitee.com")}},
        }})

    def write_registry(self, value):
        self.registry.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def matches(self, body, *, tag="v1.7.1", platform="github", notes=None):
        return release_body_matches(body, self.notes if notes is None else notes,
                                    tag=tag, platform=platform, registry_path=self.registry)

    def test_original_notes_remain_valid_with_or_without_registration(self):
        self.assertTrue(self.matches(" \n" + self.notes + "\n "))
        self.registry.unlink()
        self.assertTrue(self.matches(self.notes))

    def test_only_the_exact_registered_prefix_and_original_notes_are_accepted(self):
        self.assertTrue(self.matches(self.prefix + "\n\n" + self.notes))
        self.assertTrue(self.matches("\n" + self.prefix + "\n\n" + self.notes + "\n"))
        self.assertFalse(self.matches(self.prefix + "\n\n" + self.notes.replace("原版", "改版")))
        self.assertFalse(self.matches(self.prefix + "\n\n" + self.notes + "\n\n新增其他内容"))

    def test_changed_image_url_and_appended_promotion_are_rejected(self):
        self.assertFalse(self.matches(self.prefix.replace("poster.png", "other.png") + "\n\n" + self.notes))
        self.assertFalse(self.matches(self.notes + "\n\n" + self.prefix))

    def test_wrong_version_platform_and_missing_registration_reject_the_prefix(self):
        body = self.prefix + "\n\n" + self.notes
        self.assertFalse(self.matches(body, tag="v1.7.0"))
        self.assertFalse(self.matches(body, platform="gitee"))
        self.registry.unlink()
        self.assertFalse(self.matches(body))

    def test_platform_without_prefix_registration_only_accepts_original_notes(self):
        self.write_registry({"schemaVersion": 1, "releases": {
            "v1.7.1": {"github": {"prefix": self.prefix}},
        }})
        self.assertTrue(self.matches(self.notes, platform="gitee"))
        self.assertFalse(self.matches(self.prefix + "\n\n" + self.notes, platform="gitee"))

    def test_invalid_registry_schema_and_requested_prefix_fail_closed(self):
        values = [[], {"schemaVersion": True, "releases": {}},
                  {"schemaVersion": 2, "releases": {}},
                  {"schemaVersion": 1, "releases": []},
                  {"schemaVersion": 1, "releases": {"v1.7.1": []}},
                  {"schemaVersion": 1, "releases": {"v1.7.1": {"github": []}}},
                  {"schemaVersion": 1, "releases": {"v1.7.1": {"github": {"prefix": " "}}}},
                  {"schemaVersion": 1, "releases": {"v1.7.1": {"github": {"prefix": None}}}}]
        for value in values:
            with self.subTest(value=value):
                self.write_registry(value)
                with self.assertRaises(ValueError):
                    self.matches(self.prefix + "\n\n" + self.notes)
                self.assertTrue(self.matches(self.notes))

    def test_invalid_json_and_body_types_are_rejected_without_network_access(self):
        self.registry.write_text("not json", encoding="utf-8")
        with self.assertRaises(ValueError):
            self.matches(self.prefix + "\n\n" + self.notes)
        self.assertFalse(self.matches(None))
        self.assertFalse(self.matches({"body": self.notes}))
        with self.assertRaises(ValueError):
            self.matches(self.notes, platform="atomgit")


if __name__ == "__main__":
    unittest.main()
