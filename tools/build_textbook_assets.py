#!/usr/bin/env python3
"""Build Flutter assets from a text-layer PDF; page selections are 1-based.

Volcengine HTTP TTS requires credentials and internet during the build.
The resulting MP3s play offline; --plan-only needs no credentials or network.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
from collections import defaultdict
from dataclasses import dataclass
import json
import hashlib
import html
import math
import os
from pathlib import Path
import re
import shutil
import sys
import uuid
from types import SimpleNamespace

import pymupdf as fitz
import requests
from PIL import Image
from dotenv import load_dotenv
from deep_translator import GoogleTranslator, MyMemoryTranslator
from deep_translator import google as google_engine, mymemory as mymemory_engine

if __package__:
    from .patch_translations import correct_translation
    from .dialogue_processing import (detect_speaker_and_voice,
        sort_sentences_by_dialogue_logic, load_reviewed_context,
        prepare_page_dialogue)
else:
    from patch_translations import correct_translation
    from dialogue_processing import (detect_speaker_and_voice,
        sort_sentences_by_dialogue_logic, load_reviewed_context,
        prepare_page_dialogue)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
# Private local configuration; existing process environment takes precedence.
load_dotenv(PROJECT_ROOT / '.env.volc', override=False, interpolate=False)

# ==================== 豆包 2.0 凭据（由用户后续填入） ====================
VOLC_API_KEY = os.environ.get("VOLC_API_KEY", "<YOUR_API_KEY>")
# Legacy console authentication remains available when API Key is not set.
VOLC_APPID = os.environ.get("VOLC_APPID", "")
VOLC_TOKEN = os.environ.get("VOLC_TOKEN", "")
VOLC_RESOURCE_ID = os.environ.get("VOLC_RESOURCE_ID", "seed-tts-2.0")
API_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse"

# ==================== 角色音色映射表（填写已授权的 2.0 speaker ID） ====================
VOICE_MAP = {
    "girl": os.environ.get("VOLC_VOICE_GIRL", "<VOICE_TYPE_GIRL>"),
    "boy": os.environ.get("VOLC_VOICE_BOY", "<VOICE_TYPE_BOY>"),
    "dino": os.environ.get("VOLC_VOICE_DINO", "<VOICE_TYPE_DINO>"),
    "teacher_female": os.environ.get("VOLC_VOICE_TEACHER_F", "<VOICE_TYPE_TEACHER_F>"),
    "teacher_male": os.environ.get("VOLC_VOICE_TEACHER_M", "<VOICE_TYPE_TEACHER_M>"),
    "narrator": os.environ.get("VOLC_VOICE_NARRATOR", "<VOICE_TYPE_NARRATOR>"),
}
ROLE_SPEED_MAP = dict.fromkeys(VOICE_MAP, 1.0)
ROLE_SPEED_MAP["dino"] = 1.06
ROLE_PITCH_MAP = dict.fromkeys(VOICE_MAP, 0)
ROLE_PITCH_MAP["dino"] = 3  # V3 post_process.pitch, integer -12..12, not Hz.
AUDIO_SAMPLE_RATE = 24000
AUDIO_BITRATE = 64000  # V3 bit_rate is in bps.

ENGLISH = re.compile(r"[A-Za-z]")
TOKEN = re.compile(r"[A-Za-z0-9.,!?;:'\"‘’“”()&/…+\-]+")
ABBREVIATIONS = {"mr.", "mrs.", "ms.", "dr.", "e.g.", "i.e."}


class VolcTtsError(RuntimeError):
    def __init__(self, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.retryable = retryable


def configured(value) -> bool:
    return isinstance(value, str) and bool(value.strip()) and not re.search(r"[<>\r\n]", value)


def validate_tts_configuration(sentences=None) -> None:
    missing = []
    if not configured(VOLC_API_KEY) and not (configured(VOLC_APPID) and configured(VOLC_TOKEN)):
        missing.append('VOLC_API_KEY (or both VOLC_APPID and VOLC_TOKEN)')
    if VOLC_RESOURCE_ID not in {'seed-tts-2.0', 'seed-icl-2.0'}:
        missing.append('VOLC_RESOURCE_ID (seed-tts-2.0 or seed-icl-2.0)')
    if sentences is None:
        missing.extend(f"VOICE_MAP[{role}]" for role in VOICE_MAP if not configured(VOICE_MAP[role]))
    else:
        missing.extend(f"VOICE_MAP[{s.get('voiceRole', 'narrator')}]" for s in sentences
                       if not configured(s.get('voice', VOICE_MAP.get(s.get('voiceRole', 'narrator')))))
    if missing:
        raise ValueError("Configure Volcengine TTS before generating audio: " + ", ".join(sorted(set(missing)))
                         + ". Fill .env.volc or environment variables; --plan-only works without credentials.")


def configure_sentence_voice(sentence: dict, narrator_voice=None) -> None:
    role = sentence.get('voiceRole', 'narrator')
    if role not in VOICE_MAP:
        role = 'narrator'
    sentence['voiceRole'] = role
    sentence['voice'] = narrator_voice if role == 'narrator' and narrator_voice else VOICE_MAP[role]
    speed = ROLE_SPEED_MAP.get(role, 1.0)
    if not isinstance(speed, (int, float)) or not math.isfinite(speed) or not 0.5 <= speed <= 2.0:
        raise ValueError(f"ROLE_SPEED_MAP[{role}] must be within 0.5..2.0")
    sentence['speedRatio'] = speed
    pitch = ROLE_PITCH_MAP.get(role, 0)
    if type(pitch) is not int or not -12 <= pitch <= 12:
        raise ValueError(f"ROLE_PITCH_MAP[{role}] must be an integer within -12..12")
    sentence['pitchShift'] = pitch
    sentence['ttsProvider'] = 'volcengine-http-v3-doubao2'
    sentence.pop('pitch', None)
    sentence.pop('rate', None)


def tts_audio_parameters(sentence: dict) -> dict:
    speed = sentence.get('speedRatio', 1.0)
    if not isinstance(speed, (int, float)) or not math.isfinite(speed) or not 0.5 <= speed <= 2.0:
        raise VolcTtsError('TTS speedRatio must be within 0.5..2.0')
    if AUDIO_SAMPLE_RATE not in {8000, 16000, 22050, 24000, 32000, 44100, 48000}:
        raise VolcTtsError('Unsupported V3 MP3 sample rate')
    if AUDIO_BITRATE not in {64000, 160000}:
        raise VolcTtsError('V3 MP3 bit_rate must be 64000 or 160000 bps')
    return {'format': 'mp3', 'sample_rate': AUDIO_SAMPLE_RATE, 'bit_rate': AUDIO_BITRATE,
            'speech_rate': round((speed - 1) * 100)}


def tts_additions(sentence: dict) -> dict:
    pitch = sentence.get('pitchShift', 0)
    if type(pitch) is not int or not -12 <= pitch <= 12:
        raise VolcTtsError('TTS pitchShift must be an integer within -12..12')
    return {'explicit_language': 'en', 'post_process': {'pitch': pitch}}


def speech_fingerprint(sentence: dict) -> str:
    spec = {'text': sentence['text'], 'speaker': sentence['voice'],
            'engine': 'volcengine-http-v3-doubao2', 'endpoint': API_URL,
            'resource_id': VOLC_RESOURCE_ID, 'audio_params': tts_audio_parameters(sentence),
            'additions': tts_additions(sentence)}
    return hashlib.sha256(json.dumps(spec, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def valid_mp3_bytes(data: bytes) -> bool:
    return len(data) >= 256 and (data.startswith(b'ID3') or (data[0] == 0xff and data[1] & 0xe0 == 0xe0))


def iter_tts_events(response):
    """Decode SSE records, including multiple data lines and a final unpadded record."""
    data_lines = []
    event_type = None
    for raw in response.iter_lines():
        try:
            line = raw.decode('utf-8') if isinstance(raw, bytes) else raw
        except UnicodeError:
            raise VolcTtsError('Volcengine TTS returned invalid UTF-8', retryable=True) from None
        if not line:
            if data_lines:
                yield parse_tts_event('\n'.join(data_lines), event_type)
                data_lines = []
            event_type = None
        elif line.startswith('data:'):
            data_lines.append(line[5:].lstrip(' '))
        elif line.startswith('event:'):
            event_type = line[6:].strip()
        elif not line.startswith((':', 'id:', 'retry:')):
            raise VolcTtsError('Volcengine TTS returned unexpected SSE content', retryable=True)
    if data_lines:
        yield parse_tts_event('\n'.join(data_lines), event_type)


def parse_tts_event(payload, event_type=None):
    try:
        event = json.loads(payload)
    except (ValueError, TypeError):
        raise VolcTtsError('Volcengine TTS returned malformed event JSON', retryable=True) from None
    if not isinstance(event, dict) or type(event.get('code')) is not int:
        raise VolcTtsError('Volcengine TTS event has no valid business code')
    event['_event'] = event_type
    return event


def synthesize_http_audio(sentence: dict, args: argparse.Namespace) -> bytes:
    """One V3 HTTP SSE synthesis; require a successful terminal event before saving."""
    validate_tts_configuration([sentence])
    text = sentence['text']
    if not isinstance(text, str) or not text.strip():
        raise VolcTtsError('TTS text must be nonempty')
    headers = {'Content-Type': 'application/json', 'Accept': 'text/event-stream',
               'X-Api-Resource-Id': VOLC_RESOURCE_ID, 'X-Api-Request-Id': str(uuid.uuid4())}
    if configured(VOLC_API_KEY):
        headers['X-Api-Key'] = VOLC_API_KEY
    else:
        headers.update({'X-Api-App-Id': VOLC_APPID, 'X-Api-Access-Key': VOLC_TOKEN})
    payload = {
        'user': {'uid': 'textbook-asset-builder'},
        'req_params': {'text': text, 'speaker': sentence['voice'],
                       'audio_params': tts_audio_parameters(sentence),
                       'additions': json.dumps(tts_additions(sentence), ensure_ascii=False)},
    }
    proxies = {'http': args.proxy, 'https': args.proxy} if args.proxy else None
    try:
        response = requests.post(API_URL, headers=headers, json=payload, stream=True,
                                 timeout=args.timeout, proxies=proxies, allow_redirects=False)
    except requests.RequestException:
        # Do not print transport exceptions: URLs, proxies or headers may contain secrets.
        raise VolcTtsError('Volcengine TTS network request failed', retryable=True) from None
    try:
        status = response.status_code
        if status != 200:
            raise VolcTtsError(f'Volcengine TTS HTTP status {status}', retryable=status == 429 or status >= 500)
        chunks = []
        finished = False
        try:
            for event in iter_tts_events(response):
                code = event['code']
                if code not in {0, 20000000}:
                    message = event.get('message', '')
                    concurrency_limited = code == 45000000 and isinstance(message, str) and 'quota exceeded for types: concurrency' in message.lower()
                    raise VolcTtsError(f'Volcengine TTS business code {code}',
                                       retryable=code >= 50000000 or concurrency_limited)
                if event['_event'] in {'151', '153'}:
                    raise VolcTtsError('Volcengine TTS session canceled or failed')
                encoded = event.get('data')
                if encoded is not None and encoded != '':
                    if not isinstance(encoded, str):
                        raise VolcTtsError('Volcengine TTS returned invalid audio data', retryable=True)
                    try:
                        chunks.append(base64.b64decode(encoded, validate=True))
                    except (ValueError, binascii.Error):
                        raise VolcTtsError('Volcengine TTS returned invalid Base64 audio', retryable=True) from None
                if code == 20000000:
                    finished = True
                    break
        except requests.RequestException:
            raise VolcTtsError('Volcengine TTS stream interrupted', retryable=True) from None
        if not finished:
            raise VolcTtsError('Volcengine TTS stream ended without a successful terminal event', retryable=True)
        data = b''.join(chunks)
        if not valid_mp3_bytes(data):
            raise VolcTtsError('Volcengine TTS returned empty or invalid MP3', retryable=True)
        return data
    finally:
        response.close()


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
    for sentence in sentences:
        if sentence.get('ttsProvider') != 'volcengine-http-v3-doubao2':
            configure_sentence_voice(sentence, getattr(args, 'voice', None))
    validate_tts_configuration(sentences)
    semaphore = asyncio.Semaphore(args.concurrency)
    failures = []
    stats = {"cached": 0, "downloaded": 0}
    grouped = defaultdict(list)
    cache_dir = PROJECT_ROOT / '.asset-cache' / 'speech-volc-http-v3-doubao2'
    cache_dir.mkdir(parents=True, exist_ok=True)
    for sentence in sentences:
        key = speech_fingerprint(sentence)
        if sentence.get('speechFingerprint', key) != key:
            raise ValueError(f"Speech fingerprint mismatch: {sentence['id']}")
        grouped[key].append(sentence)

    def valid_mp3(path):
        if not path.is_file() or path.stat().st_size < 256:
            return False
        return valid_mp3_bytes(path.read_bytes())

    async def save(key, entries):
        sentence = entries[0]
        path = cache_dir / f'{key}.mp3'
        metadata_path = path.with_suffix('.json')
        if valid_mp3(path) and metadata_path.is_file() and not args.refresh_audio:
            try:
                metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
                if metadata.get('sha256') == hashlib.sha256(path.read_bytes()).hexdigest():
                    stats['cached'] += 1
                    return
            except (ValueError, AttributeError):
                pass  # A damaged cache entry is regenerated, never published.
        async with semaphore:
            temporary = staging_path(path)
            for attempt in range(1, args.retries + 1):
                try:
                    audio = await asyncio.to_thread(synthesize_http_audio, sentence, args)
                    temporary.write_bytes(audio)
                    if not valid_mp3(temporary):
                        raise RuntimeError("TTS returned empty or invalid MP3")
                    temporary.replace(path)
                    write_json(metadata_path, {'speechFingerprint': key,
                               'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
                    stats["downloaded"] += 1
                    done = sum(stats.values())
                    if done % 10 == 0 or done == len(grouped):
                        print(f"Audio profiles: {done}/{len(grouped)} ({stats})", flush=True)
                    return
                except Exception as error:
                    retryable = isinstance(error, VolcTtsError) and error.retryable
                    if attempt == args.retries or not retryable:
                        failures.append(f"{sentence['id']}: {type(error).__name__}: {error}")
                        break
                    else:
                        await asyncio.sleep(min(2 ** attempt, 8))

    await asyncio.gather(*(save(key, entries) for key, entries in grouped.items()))
    print(f"Audio: {stats['downloaded']} downloaded, {stats['cached']} cached", flush=True)
    if failures:
        raise RuntimeError("Audio synthesis failed; previous book.json retained.\n" + "\n".join(failures))
    # Publish immutable, fingerprinted assets only after every profile succeeds.
    for key, entries in grouped.items():
        for sentence in entries:
            path = PROJECT_ROOT / sentence['audioPath']
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = staging_path(path)
            shutil.copyfile(cache_dir / f'{key}.mp3', temporary)
            temporary.replace(path)


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
    result.add_argument("--reuse-images", action="store_true", help="Keep existing page images when only speech/order changes")
    result.add_argument("--voice", help="Override only narrator speaker ID; character speakers use VOICE_MAP")
    result.add_argument("--concurrency", type=int, default=3)
    result.add_argument("--retries", type=int, default=3)
    result.add_argument("--timeout", type=float, default=60)
    result.add_argument("--proxy", help="Optional HTTP proxy for TTS and translation")
    result.add_argument("--refresh-audio", action="store_true", help="Regenerate cached audio after changing text or voice")
    result.add_argument("--translator", choices=("google", "mymemory"), default="mymemory")
    result.add_argument("--translation-concurrency", type=int, default=2)
    result.add_argument("--translation-timeout", type=float, default=20)
    result.add_argument("--translation-delay", type=float, default=0.3)
    result.add_argument("--refresh-translations", action="store_true")
    result.add_argument("--plan-only", action="store_true", help="Write review plan outside assets without TTS or manifest changes")
    result.add_argument("--check-tts-config", action="store_true", help="Validate all local TTS settings without network or asset changes")
    result.add_argument("--tts-test-text", help="Synthesize one sentence into build/tts-check, without rebuilding textbook assets")
    result.add_argument("--tts-test-role", choices=tuple(VOICE_MAP), default='narrator')
    return result


def check_or_test_tts(args: argparse.Namespace) -> None:
    validate_build_options(args)
    if args.check_tts_config:
        validate_tts_configuration()
        print('Doubao 2.0 TTS configuration is ready (offline validation; no network call).')
    if args.tts_test_text:
        sentence = {'id': f'test-{args.tts_test_role}', 'text': args.tts_test_text,
                    'voiceRole': args.tts_test_role,
                    'audioPath': f'build/tts-check/{args.tts_test_role}.mp3'}
        configure_sentence_voice(sentence, args.voice)
        validate_tts_configuration([sentence])
        asyncio.run(synthesize([sentence], args))
        print(f"Test audio saved: {PROJECT_ROOT / sentence['audioPath']}")


def build(args: argparse.Namespace) -> None:
    validate_build_options(args)
    if not args.plan_only:
        validate_tts_configuration([])  # Fail before touching images when credentials are missing.
    build_assets(args)


def validate_build_options(args: argparse.Namespace) -> None:
    if min(args.dpi, args.concurrency, args.retries, args.timeout,
           args.translation_concurrency, args.translation_timeout) <= 0 or args.translation_delay < 0:
        raise ValueError("DPI, concurrency, retries and timeout must be positive")


def build_assets(args: argparse.Namespace) -> None:
    pdf = args.pdf or next((p for p in (PROJECT_ROOT / "textbook.pdf", PROJECT_ROOT / "assets/textbook.pdf") if p.is_file()), None)
    if pdf is None or not pdf.is_file():
        raise FileNotFoundError(f"PDF not found: {pdf}. Supply a local PDF path.")
    output = (PROJECT_ROOT / args.output).resolve()
    # Paths published in the manifest must be Flutter asset paths.
    output.relative_to((PROJECT_ROOT / "assets").resolve())
    asset_prefix = output.relative_to(PROJECT_ROOT).as_posix()
    manifest = {"bookId": args.book_id, "title": args.title, "pages": []}
    reviewed = load_reviewed_context(pdf, args.book_id)
    scene_report = {}
    old_manifest = json.loads((output / 'book.json').read_text(encoding='utf-8')) if (output / 'book.json').exists() else None
    with fitz.open(pdf) as document:
        selected = selected_pages(args, len(document))
        unit = 0
        # Scan preceding pages too, so IDs are stable for full and partial runs.
        for index, page in enumerate(document, start=1):
            matches = re.findall(r"(?im)^\s*Unit\s+(\d+)\s*$", page.get_text())
            if matches:
                unit = int(matches[0])
            if index not in selected:
                continue
            image_name = f"page_{index:03d}.{args.image_format}"
            sentences = []
            for number, (text, rect) in enumerate(extract_sentences(page), start=1):
                sentence_id = f"u{unit}_p{index:03d}_s{number:03d}"
                sentences.append({
                    "id": sentence_id, "text": text, "translation": None,
                    "audioPath": f"{asset_prefix}/audios/{sentence_id}.mp3", "rect": rect,
                })
            sentences, regions = prepare_page_dialogue(page, sentences, reviewed.get(str(index)))
            scene_report[str(index)] = regions
            for sentence in sentences:
                configure_sentence_voice(sentence, args.voice)
                key = speech_fingerprint(sentence)
                sentence['speechFingerprint'] = key
                sentence['audioPath'] = f"{asset_prefix}/audios/{sentence['id']}_{key[:16]}.mp3"
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
        if not args.plan_only:
            # Resolve and validate every selected role before writing any assets.
            validate_tts_configuration(all_sentences)
            for folder in ("images", "audios"):
                (output / folder).mkdir(parents=True, exist_ok=True)
            if not (args.reuse_images and (output / 'images/cover.webp').is_file()):
                render_cover(document, output / "images" / "cover.webp", args.dpi)
            for index in selected:
                image = output / "images" / f"page_{index:03d}.{args.image_format}"
                if not (args.reuse_images and image.is_file()):
                    render_page_image(document[index - 1], image, args.dpi)
    plan = PROJECT_ROOT / '.asset-cache' / 'dialogue-plan.json'
    write_json(plan, {'manifest': manifest, 'scenes': scene_report})
    if args.plan_only:
        print(f'Dialogue review plan: {plan}')
        return
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
    # Retire only previously referenced generated MP3s after the new manifest is
    # committed. Keep a local backup; obsolete audio must not bloat the APK.
    if old_manifest:
        archive = PROJECT_ROOT / '.asset-cache' / 'previous-audio'
        active = {s['audioPath'] for s in all_sentences}
        for old_page in old_manifest.get('pages', []):
            for old in old_page.get('sentences', []):
                old_path = (PROJECT_ROOT / old['audioPath']).resolve()
                if old['audioPath'] not in active and old_path.is_file() and old_path.parent == (output / 'audios').resolve():
                    archive.mkdir(parents=True, exist_ok=True)
                    old_path.replace(archive / old_path.name)
    missing = sum(not s["translation"].strip() for s in all_sentences)
    print(f"Translations missing: {missing}/{len(all_sentences)} (rerun to retry)")
    print(f"SUCCESS: {len(selected)} pages, {len(all_sentences)} sentences -> {output / 'book.json'}")


if __name__ == "__main__":
    try:
        args = parser().parse_args()
        if args.check_tts_config or args.tts_test_text:
            check_or_test_tts(args)
        else:
            build(args)
    except (Exception, KeyboardInterrupt) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
