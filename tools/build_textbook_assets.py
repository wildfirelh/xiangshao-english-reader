#!/usr/bin/env python3
"""Build Flutter assets from a text-layer PDF; page selections are 1-based.

Edge-TTS requires internet during the build. The resulting MP3s play offline.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import defaultdict
from dataclasses import dataclass
import json
import hashlib
import html
from pathlib import Path
import re
import sys
from types import SimpleNamespace

import edge_tts
import pymupdf as fitz
import requests
from PIL import Image
from deep_translator import GoogleTranslator, MyMemoryTranslator
from deep_translator import google as google_engine, mymemory as mymemory_engine

if __package__:
    from .patch_translations import correct_translation
else:
    from patch_translations import correct_translation

PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENGLISH = re.compile(r"[A-Za-z]")
TOKEN = re.compile(r"[A-Za-z0-9.,!?;:'\"‘’“”()&/…+\-]+")
ABBREVIATIONS = {"mr.", "mrs.", "ms.", "dr.", "e.g.", "i.e."}


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = staging_path(path) if path.is_relative_to(PROJECT_ROOT / "assets") else path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def staging_path(destination: Path) -> Path:
    # Flutter includes every file in a declared asset directory. Keep partial
    # downloads outside assets so concurrent Flutter builds cannot bundle them.
    directory = PROJECT_ROOT / ".asset-cache" / "staging"
    directory.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(str(destination).encode()).hexdigest()
    return directory / f"{key}{destination.suffix}.part"


def render_page_image(page: fitz.Page, destination: Path, dpi: int,
                      clip: fitz.Rect | None = None) -> None:
    pixmap = page.get_pixmap(dpi=dpi, alpha=False, clip=clip)
    temporary = staging_path(destination)
    if destination.suffix == ".webp":
        with Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples) as image:
            image.save(temporary, "WEBP", quality=85, method=6)
    else:
        pixmap.save(temporary, output="png")
    temporary.replace(destination)


def render_cover(document: fitz.Document, destination: Path, dpi: int = 200) -> None:
    first = document[0]
    clip = None
    if first.rect.width > first.rect.height and len(document) > 1:
        # This PDF's first page is a back/spine/front spread. The rightmost
        # portrait page is the front cover used on the shelf.
        width = min(document[1].rect.width, first.rect.width / 2)
        clip = fitz.Rect(first.rect.x1 - width, first.rect.y0, first.rect.x1, first.rect.y1)
    render_page_image(first, destination, dpi, clip)


def translate_text(text: str, args: argparse.Namespace) -> str:
    proxies = {"http": args.proxy, "https": args.proxy} if args.proxy else None
    translator = (
        MyMemoryTranslator(source="en-US", target="zh-CN", proxies=proxies)
        if args.translator == "mymemory"
        else GoogleTranslator(source="en", target="zh-CN", proxies=proxies)
    )
    result = translator.translate(text)
    if isinstance(result, str):
        result = html.unescape(result).strip()
    if not isinstance(result, str) or not result.strip():
        raise ValueError("Empty translation response")
    # MyMemory can return quota errors as translatedText with HTTP 200.
    if "MYMEMORY WARNING" in result.upper() or "USED ALL AVAILABLE FREE" in result.upper():
        raise RuntimeError("Translation quota exhausted")
    return result


async def translate_sentences(sentences: list[dict], args: argparse.Namespace,
                              cache_path: Path, previous_manifest: Path) -> None:
    # deep-translator 1.11.4 omits a requests timeout. Replace only these two
    # engines' local transport references, leaving requests itself untouched.
    def bounded_get(*positional, **kwargs):
        kwargs.setdefault("timeout", args.translation_timeout)
        return requests.get(*positional, **kwargs)

    transport = SimpleNamespace(get=bounded_get)
    google_engine.requests = transport
    mymemory_engine.requests = transport
    cache = {}
    if cache_path.is_file():
        try:
            saved = json.loads(cache_path.read_text(encoding="utf-8"))
            cache = {k: v for k, v in saved.items() if isinstance(v, str) and v.strip()}
        except (ValueError, AttributeError):
            print("WARNING: ignoring malformed translation cache", file=sys.stderr)
    if previous_manifest.is_file():
        previous = json.loads(previous_manifest.read_text(encoding="utf-8"))
        for page in previous.get("pages", []):
            for sentence in page.get("sentences", []):
                translation = sentence.get("translation")
                if isinstance(translation, str) and translation.strip():
                    cache.setdefault(sentence["text"], translation.strip())
    if args.refresh_translations:
        cache = {}
    grouped = defaultdict(list)
    for sentence in sentences:
        grouped[sentence["text"]].append(sentence)
    semaphore = asyncio.Semaphore(args.translation_concurrency)
    stats = {"cached": 0, "translated": 0, "failed": 0}

    async def translate(text: str, entries: list[dict]) -> None:
        if text in cache:
            translation = cache[text]
            stats["cached"] += 1
        else:
            translation = ""
            async with semaphore:
                for attempt in range(args.retries):
                    try:
                        translation = await asyncio.to_thread(translate_text, text, args)
                        cache[text] = translation
                        # Checkpoint each success, even if a later audio fails.
                        write_json(cache_path, cache)
                        stats["translated"] += 1
                        break
                    except Exception as error:
                        if attempt + 1 == args.retries:
                            stats["failed"] += 1
                            print(f"WARNING: translation unavailable for {text!r}: {error}", flush=True)
                        else:
                            await asyncio.sleep(min(2 ** (attempt + 1), 8))
                await asyncio.sleep(args.translation_delay)
        if args.book_id == "xiangshao_3_1":
            translation, _ = correct_translation(text, translation)
        for entry in entries:
            entry["translation"] = translation
        done = sum(stats.values())
        if done % 25 == 0 or done == len(grouped):
            print(f"Translations: {done}/{len(grouped)} unique texts ({stats})", flush=True)

    await asyncio.gather(*(translate(text, entries) for text, entries in grouped.items()))


def selected_pages(args: argparse.Namespace, count: int) -> list[int]:
    if args.pages:
        if args.start_page is not None or args.end_page is not None:
            raise ValueError("Use either --pages or --start-page/--end-page")
        return parse_pages(args.pages, count)
    first = args.start_page if args.start_page is not None else 8
    last = args.end_page if args.end_page is not None else 72
    return parse_pages(f"{first}-{last}", count)


@dataclass
class Word:
    text: str
    rect: fitz.Rect


def ends_sentence(text: str) -> bool:
    return text.lower() not in ABBREVIATIONS and bool(
        re.search(r"[.!?…][\"'’”)\]]*$", text)
    )


def joined_text(words: list[Word]) -> str:
    text = " ".join(w.text for w in words)
    text = re.sub(r"\s+([.,!?;:)])", r"\1", text)
    return re.sub(r"([(])\s+", r"\1", text).strip()


def bounds(words: list[Word]) -> fitz.Rect:
    rect = fitz.Rect(words[0].rect)
    for word in words[1:]:
        rect |= word.rect
    return rect


def normalized_rect(rect: fitz.Rect, page: fitz.Page) -> dict[str, float]:
    # Text coordinates are unrotated PDF points. Rotate into the rendered page
    # coordinate system before normalization (DPI cancels out of the ratio).
    box = (rect * page.rotation_matrix) & page.rect
    if box.is_empty:
        raise ValueError(f"Text rectangle is outside PDF page {page.number + 1}")
    frame = page.rect
    return dict(zip(("left", "top", "right", "bottom"), (
        round(max(0.0, min(1.0, value)), 7) for value in (
            (box.x0 - frame.x0) / frame.width,
            (box.y0 - frame.y0) / frame.height,
            (box.x1 - frame.x0) / frame.width,
            (box.y1 - frame.y0) / frame.height,
        )
    )))


def extract_sentences(page: fitz.Page) -> list[tuple[str, dict[str, float]]]:
    """Split at punctuation; join close, aligned continuation lines.

    Preserve individual columns/bubbles, including PDFs where each wrapped
    line is stored as a separate text block. This is geometric, not OCR or
    semantic understanding; unusual layouts still need a visual review.
    """
    grouped: dict[tuple[int, int], list[Word]] = defaultdict(list)
    for x0, y0, x1, y1, text, block, line, _ in page.get_text("words"):
        cleaned = " ".join(TOKEN.findall(text))
        if cleaned:
            grouped[block, line].append(Word(cleaned, fitz.Rect(x0, y0, x1, y1)))

    lines: list[list[Word]] = []
    for words in grouped.values():
        words.sort(key=lambda w: w.rect.x0)
        fragment: list[Word] = []
        for word in words:
            if fragment and word.rect.x0 - fragment[-1].rect.x1 > 1.8 * word.rect.height:
                if ENGLISH.search(joined_text(fragment)):
                    lines.append(fragment)
                fragment = []
            fragment.append(word)
        if fragment and ENGLISH.search(joined_text(fragment)):
            lines.append(fragment)
    lines.sort(key=lambda words: (bounds(words).y0, bounds(words).x0))

    used: set[int] = set()
    result = []
    for i, words in enumerate(lines):
        if i in used:
            continue
        chain = list(words)
        last = bounds(words)
        while not ends_sentence(chain[-1].text):
            candidates = []
            for j in range(i + 1, len(lines)):
                if j in used:
                    continue
                # Numbered exercise items are independent even when tightly set.
                if re.fullmatch(r"\d+[.)]", lines[j][0].text):
                    continue
                candidate = bounds(lines[j])
                gap = candidate.y0 - last.y1
                if (0 <= gap <= last.height * 0.65
                        and abs(candidate.x0 - last.x0) <= last.height * 0.35
                        and 0.8 <= candidate.height / last.height <= 1.25):
                    candidates.append((gap, j, candidate))
            if not candidates:
                break
            _, j, last = min(candidates, key=lambda item: item[0])
            used.add(j)
            chain.extend(lines[j])

        if re.fullmatch(r"\d+[.)]", chain[0].text):
            chain = chain[1:]
        chunks: list[list[Word]] = []
        sentence: list[Word] = []
        for word in chain:
            sentence.append(word)
            if ends_sentence(word.text):
                text = joined_text(sentence)
                if ENGLISH.search(text):
                    chunks.append(sentence)
                sentence = []
        if sentence:
            text = joined_text(sentence)
            if ENGLISH.search(text):
                chunks.append(sentence)
        # A wrapped sentence's enclosing rectangle can cover an earlier short
        # sentence in the same bubble. Keep that utterance as one tappable area.
        merged: list[list[Word]] = []
        for chunk in chunks:
            if merged and not (bounds(merged[-1]) & bounds(chunk)).is_empty:
                merged[-1].extend(chunk)
            else:
                merged.append(chunk)
        for chunk in merged:
            result.append((joined_text(chunk), normalized_rect(bounds(chunk), page)))
    return result


def parse_pages(selection: str | None, count: int) -> list[int]:
    if not selection:
        return list(range(1, count + 1))
    pages = set()
    for part in selection.split(","):
        match = re.fullmatch(r"\s*(\d+)(?:\s*-\s*(\d+))?\s*", part)
        if not match:
            raise ValueError(f"Invalid page selection: {part!r}")
        first = int(match[1])
        last = int(match[2] or match[1])
        if not 1 <= first <= last <= count:
            raise ValueError(f"Page range must be within 1..{count}: {part}")
        pages.update(range(first, last + 1))
    return sorted(pages)


async def synthesize(sentences: list[dict], args: argparse.Namespace) -> None:
    semaphore = asyncio.Semaphore(args.concurrency)
    failures = []
    stats = {"cached": 0, "downloaded": 0}

    async def save(sentence: dict) -> None:
        path = PROJECT_ROOT / sentence["audioPath"]
        if path.is_file() and path.stat().st_size > 0 and not args.refresh_audio:
            stats["cached"] += 1
            return
        async with semaphore:
            temporary = staging_path(path)
            for attempt in range(1, args.retries + 1):
                try:
                    speech = edge_tts.Communicate(
                        sentence["text"], args.voice, proxy=args.proxy,
                    )
                    await asyncio.wait_for(speech.save(str(temporary)), args.timeout)
                    if not temporary.is_file() or temporary.stat().st_size == 0:
                        raise RuntimeError("TTS returned empty audio")
                    temporary.replace(path)
                    stats["downloaded"] += 1
                    print(f"  Audio {sentence['id']}", flush=True)
                    return
                except Exception as error:
                    if attempt == args.retries:
                        failures.append(f"{sentence['id']}: {type(error).__name__}: {error}")
                    else:
                        await asyncio.sleep(min(2 ** attempt, 8))

    await asyncio.gather(*(save(sentence) for sentence in sentences))
    print(f"Audio: {stats['downloaded']} downloaded, {stats['cached']} cached", flush=True)
    if failures:
        raise RuntimeError("Audio synthesis failed; previous book.json retained.\n" + "\n".join(failures))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("pdf", nargs="?", type=Path, help="PDF path, relative to the working directory")
    result.add_argument("--output", type=Path, default=Path("assets/textbooks/xiangshao_3_1"))
    result.add_argument("--pages", help="Explicit physical PDF pages, e.g. 8-11 or 8,10-12")
    result.add_argument("--start-page", type=int, help="First physical PDF page (default: 8)")
    result.add_argument("--end-page", type=int, help="Last physical PDF page, inclusive (default: 72)")
    result.add_argument("--book-id", default="xiangshao_3_1")
    result.add_argument("--title", default="湘少版英语三年级上册")
    result.add_argument("--dpi", type=int, default=200)
    result.add_argument("--image-format", choices=("webp", "png"), default="webp")
    result.add_argument("--voice", default="en-US-AnaNeural")
    result.add_argument("--concurrency", type=int, default=3)
    result.add_argument("--retries", type=int, default=3)
    result.add_argument("--timeout", type=float, default=60)
    result.add_argument("--proxy", help="Optional HTTP proxy for Edge-TTS")
    result.add_argument("--refresh-audio", action="store_true", help="Regenerate cached audio after changing text or voice")
    result.add_argument("--translator", choices=("google", "mymemory"), default="mymemory")
    result.add_argument("--translation-concurrency", type=int, default=2)
    result.add_argument("--translation-timeout", type=float, default=20)
    result.add_argument("--translation-delay", type=float, default=0.3)
    result.add_argument("--refresh-translations", action="store_true")
    return result


def build(args: argparse.Namespace) -> None:
    if min(args.dpi, args.concurrency, args.retries, args.timeout,
           args.translation_concurrency, args.translation_timeout) <= 0 or args.translation_delay < 0:
        raise ValueError("DPI, concurrency, retries and timeout must be positive")
    pdf = args.pdf or next((p for p in (PROJECT_ROOT / "textbook.pdf", PROJECT_ROOT / "assets/textbook.pdf") if p.is_file()), None)
    if pdf is None or not pdf.is_file():
        raise FileNotFoundError(f"PDF not found: {pdf}. Supply a local PDF path.")
    output = (PROJECT_ROOT / args.output).resolve()
    # Paths published in the manifest must be Flutter asset paths.
    output.relative_to((PROJECT_ROOT / "assets").resolve())
    asset_prefix = output.relative_to(PROJECT_ROOT).as_posix()
    manifest = {"bookId": args.book_id, "title": args.title, "pages": []}
    with fitz.open(pdf) as document:
        selected = selected_pages(args, len(document))
        for folder in ("images", "audios"):
            (output / folder).mkdir(parents=True, exist_ok=True)
        render_cover(document, output / "images" / "cover.webp", args.dpi)
        unit = 0
        # Scan preceding pages too, so IDs are stable for full and partial runs.
        for index, page in enumerate(document, start=1):
            matches = re.findall(r"(?im)^\s*Unit\s+(\d+)\s*$", page.get_text())
            if matches:
                unit = int(matches[0])
            if index not in selected:
                continue
            image_name = f"page_{index:03d}.{args.image_format}"
            render_page_image(page, output / "images" / image_name, args.dpi)
            sentences = []
            for number, (text, rect) in enumerate(extract_sentences(page), start=1):
                sentence_id = f"u{unit}_p{index:03d}_s{number:03d}"
                sentences.append({
                    "id": sentence_id, "text": text, "translation": None,
                    "audioPath": f"{asset_prefix}/audios/{sentence_id}.mp3", "rect": rect,
                })
            manifest["pages"].append({
                "pageIndex": index, "imagePath": f"{asset_prefix}/images/{image_name}",
                "sentences": sentences,
            })
            print(f"Page {index}/{len(document)}: {len(sentences)} sentences, {args.dpi} DPI", flush=True)
            if not sentences:
                print(f"WARNING: page {index} has no English text layer; image only (no OCR).", file=sys.stderr)
    all_sentences = [s for p in manifest["pages"] for s in p["sentences"]]
    if not all_sentences:
        raise ValueError("No English sentences found. Scanned PDFs need OCR first; book.json retained.")
    cache_key = hashlib.sha256(asset_prefix.encode()).hexdigest()[:12]
    async def populate():
        await asyncio.gather(
            translate_sentences(all_sentences, args,
                                PROJECT_ROOT / ".asset-cache" / f"{cache_key}.en-zh-CN.json",
                                output / "book.json"),
            synthesize(all_sentences, args),
        )
    asyncio.run(populate())
    write_json(output / "book.json", manifest)
    missing = sum(not s["translation"].strip() for s in all_sentences)
    print(f"Translations missing: {missing}/{len(all_sentences)} (rerun to retry)")
    print(f"SUCCESS: {len(selected)} pages, {len(all_sentences)} sentences -> {output / 'book.json'}")


if __name__ == "__main__":
    try:
        build(parser().parse_args())
    except (Exception, KeyboardInterrupt) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
