#!/usr/bin/env python3
"""Correct textbook character names without changing English, audio or hotspots."""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path
import re

PROJECT_ROOT = Path(__file__).resolve().parents[1]
NAMES = {
    "Lingling": "玲玲", "Mingming": "明明", "Anne": "安妮",
    "Peter": "彼得", "Dongdong": "东东", "Tim": "蒂姆", "Dino": "迪诺",
    "Miss Li": "李老师", "Mr Zhang": "张老师", "Mr Yang": "杨老师",
}
# Only replace these known mistranslations when the English source names the
# corresponding character. Do not change ordinary uses of e.g. 恐龙 or 添.
ALIASES = {
    "Lingling": ("凌凌", "灵灵"), "Mingming": ("茗茗",),
    "Anne": ("三胞菌属",), "Tim": ("提姆",),
    "Miss Li": ("李小姐", "李女士"),
    "Mr Zhang": ("张先生",), "Mr Yang": ("杨先生",),
}
# Exact source + exact bad translation fixes for dropped names and ambiguous
# aliases. These must never be applied by a global substring replacement.
SENTENCE_FIXES = {
    "Happy birthday, Anne!": ("生日快乐！", "生日快乐，安妮！"),
    "Hello, I’m Tim.": ("你好，我是", "你好，我是蒂姆。"),
    "Hello, Tim. I’m Dino Dinosaur.": ("你好，提姆，我是恐龙", "你好，蒂姆。我是恐龙迪诺。"),
    "How old are you, Tim?": ("您的年龄是？", "蒂姆，你几岁了？"),
    "Tim, can you find me?": ("添，你能找到我吗？", "蒂姆，你能找到我吗？"),
    "Tim, it’s a black ant.": ("添，这是一只黑蚂蚁。", "蒂姆，这是一只黑蚂蚁。"),
    "Tim, what’s that?": ("添，那是什么？", "蒂姆，那是什么？"),
    "Dino, how old are you?": ("您的年龄是？", "迪诺，你几岁了？"),
    "Hello, I’m Dino!": ("你好，我是", "你好，我是迪诺！"),
    "Hello, I’m Dino.": ("你好，我是", "你好，我是迪诺。"),
    "Dino, is this your ruler?": ("恐龙，这是你的统治者吗？", "迪诺，这是你的尺子吗？"),
    "Good afternoon, Dino.": ("午安，恐龙", "下午好，迪诺。"),
    "I’m Dino.": ("我是恐龙。", "我是迪诺。"),
    "What colour is this tree, Dino?": ("这棵树是什么颜色的，恐龙？", "这棵树是什么颜色的，迪诺？"),
    "It’s a little Dino. Thank you! I like it very much.":
        ("这是一个小恐龙。谢谢！我非常喜欢。", "这是一个小迪诺。谢谢！我非常喜欢。"),
    "Good morning, Miss Li.": ("老师早！", "李老师，早上好！"),
}


def name_pattern(name: str) -> re.Pattern:
    # ASCII boundaries work even when Latin names touch Chinese characters.
    # \b would miss 我是Peter, while bare replacement would corrupt timing.
    parts = name.split()
    token = r"\s+".join(re.escape(part) + (r"\.?" if part in {"Mr", "Miss"} else "") for part in parts)
    return re.compile(r"(?<![A-Za-z0-9_])" + token + r"(?![A-Za-z0-9_])", re.IGNORECASE)


PATTERNS = {name: name_pattern(name) for name in NAMES}


def correct_translation(text: str, translation: str) -> tuple[str, Counter]:
    counts = Counter()
    fix = SENTENCE_FIXES.get(text)
    if fix and translation == fix[0]:
        return fix[1], Counter({"exact_sentence": 1})
    for name, canonical in NAMES.items():
        translation, count = PATTERNS[name].subn(lambda _: canonical, translation)
        counts[name] += count
        if PATTERNS[name].search(text):
            for alias in ALIASES.get(name, ()):
                if alias == canonical:
                    continue
                translation, count = re.subn(re.escape(alias), lambda _: canonical, translation)
                counts[name] += count
    return translation, +counts


def patch_book(book: dict) -> tuple[dict, dict]:
    result = copy.deepcopy(book)
    counts = Counter()
    changed = []
    scanned = 0
    for page in result["pages"]:
        for sentence in page["sentences"]:
            scanned += 1
            original = sentence.get("translation")
            if not isinstance(original, str):
                continue
            corrected, replacements = correct_translation(sentence["text"], original)
            if corrected != original:
                sentence["translation"] = corrected
                counts.update(replacements)
                changed.append({"id": sentence["id"], "before": original, "after": corrected})
    return result, {"scanned": scanned, "changed": len(changed),
                    "replacements": dict(counts), "changes": changed}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", nargs="?", type=Path,
                        default=PROJECT_ROOT / "assets/textbooks/xiangshao_3_1/book.json")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    original = args.manifest.read_bytes()
    patched, report = patch_book(json.loads(original.decode("utf-8")))
    if not args.dry_run and report["changed"]:
        archive = PROJECT_ROOT / ".asset-cache" / "translation-patches"
        archive.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(original).hexdigest()[:16]
        backup = archive / f"book-{digest}.json"
        if not backup.exists():
            backup.write_bytes(original)
        temporary = archive / "book.patched.json"
        temporary.write_text(json.dumps(patched, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(args.manifest)
        (archive / "latest-report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "changes"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
