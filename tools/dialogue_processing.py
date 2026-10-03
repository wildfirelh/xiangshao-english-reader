"""Conservative scene/role inference plus reviewed, PDF-specific context.

Coordinates are normalized; sentence IDs are assigned BEFORE any reordering.
Uncertain speakers remain Narrator instead of guessing from a mentioned name.
"""
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re

ROLE_CATEGORIES = {
    **dict.fromkeys(['Lingling', 'Anne', 'Lulu', 'Beibei', 'Jiajia', 'Lily',
                     'Lucy', 'Xiaoxiao', 'Girl', 'Children'], 'girl'),
    **dict.fromkeys(['Peter', 'Mingming', 'Dongdong', 'Tim', 'Benny', 'Taotao',
                     'Robbie', 'Boy'], 'boy'),
    **dict.fromkeys(['Miss Li', 'Mother', 'Grandmother', 'Aunt Carol'], 'teacher_female'),
    **dict.fromkeys(['Mr Zhang', 'Mr Yang', 'Mr Green', 'Uncle Ben', 'Man'], 'teacher_male'),
    'Dino': 'dino',
}
NAMES = sorted(ROLE_CATEGORIES, key=len, reverse=True)
NAME_PATTERN = '|'.join(re.escape(n).replace(r'\ ', r'\s+') for n in NAMES)
SECTION = re.compile(r"^(?:Look,? Listen|Read and Act|Let.s Act|Let.s Chant|Let.s Have Fun|Read and Trace|Listen and|Read and Match|Let.s Learn)", re.I)


def plain(text):
    return text.replace('’', "'").replace('‘', "'").strip()


def canonical_name(value):
    value = re.sub(r'\b(Mr|Miss|Ms)\.', r'\1', value.strip(), flags=re.I)
    return next((n for n in NAMES if n.lower() == value.lower()), None)


def detect_speaker_and_voice(text, context=None):
    context = context or {}
    speaker = canonical_name(context.get('speaker', ''))
    source = 'reviewed_context' if speaker else 'narrator_fallback'
    cleaned = plain(text)
    if not speaker and context.get('allow_text_inference', True):
        label = re.match(rf'^({NAME_PATTERN})\s*:', cleaned, re.I)
        introduction = re.search(rf"\b(?:I(?:'m| am)|My name is)\s+({NAME_PATTERN})(?![A-Za-z])", cleaned, re.I)
        if label or introduction:
            speaker = canonical_name((label or introduction)[1])
            source = 'speaker_label' if label else 'self_introduction'
        else:
            # A name in a greeting is the ADDRESSEE. Only infer the opposite
            # speaker when a reviewed two-person scene supplies both identities.
            participants = [canonical_name(p) for p in context.get('participants', [])]
            participants = [p for p in participants if p]
            addressed = re.search(rf'(?:^|,\s*)({NAME_PATTERN})[,.!?]', cleaned, re.I)
            if len(set(participants)) == 2 and addressed:
                recipient = canonical_name(addressed[1])
                if recipient in participants:
                    speaker = next(p for p in participants if p != recipient)
                    source = 'two_person_context'
    return {'speaker': speaker or 'Narrator',
            'voiceRole': ROLE_CATEGORIES.get(speaker, 'narrator'),
            'voiceSource': source}


def dialogue_priority(text):
    text = plain(text).lower().lstrip('(" ')
    text = re.sub(rf'^({NAME_PATTERN.lower()}),\s*', '', text, flags=re.I)
    if re.match(r"^(?:thank(?:s| you)|you(?:'re| are) welcome|goodbye|bye|see you)\b", text):
        return 3
    if re.match(r"^(?:what(?:'s| is| colour| color| number)|how old|who(?:'s| is)|is this|is that|can i|can you)\b", text):
        return 1
    greeting = re.match(r'^(?:hello|hi|good morning|good afternoon)\b(.*)', text)
    if greeting:
        suffix = greeting[1].strip(' ,.!')
        if not suffix or re.match(r"^(?:i'm|i am|my name|class)\b", suffix):
            return 1
    if re.match(r'^(?:stand up|sit down|follow me|raise your|touch your|put your|take care|look\b)', text):
        return 1
    if re.match(r'^(?:four and three|seven and three) is', text):
        return 1
    return 2


def sort_sentences_by_dialogue_logic(sentences):
    return sorted(sentences, key=lambda s: (dialogue_priority(s['text']),
                  s['rect']['top'], s['rect']['left']))


def load_reviewed_context(pdf, book_id):
    source = Path(__file__).with_name('textbook_context') / f'{book_id}.json'
    if not source.exists():
        return {}
    context = json.loads(source.read_text(encoding='utf-8'))
    digest = hashlib.sha256(Path(pdf).read_bytes()).hexdigest()
    # Never apply human-reviewed coordinates/roles to a different edition.
    return context.get('pages', {}) if digest == context.get('pdf_sha256') else {}


def detect_scene_markers(page):
    candidates = []
    for block in page.get_text('dict')['blocks']:
        for line in block.get('lines', []):
            for span in line['spans']:
                text = span['text'].strip()
                if not re.fullmatch(r'[1-9]', text):
                    continue
                import pymupdf as fitz
                r = fitz.Rect(span['bbox']) * page.rotation_matrix
                if not .15 < r.y0 / page.rect.height < .90 or not 8 <= span['size'] <= 16:
                    continue
                candidates.append({'number': int(text), 'font': span['font'],
                    'left': (r.x0 - page.rect.x0) / page.rect.width,
                    'bottom': (r.y1 - page.rect.y0) / page.rect.height})
    preferred = [m for m in candidates if m['font'] == 'FOPTitleStyleFont']
    pools = [preferred] if preferred else list(_by_font(candidates).values())
    for pool in pools:
        numbers = sorted(m['number'] for m in pool)
        # Duplicate music notes, page numbers and exercise choice numbers are
        # not a unique 1..N comic sequence.
        if len(numbers) >= 2 and numbers == list(range(1, len(numbers) + 1)):
            return sorted(pool, key=lambda m: m['number'])
    return []


def _by_font(markers):
    groups = defaultdict(list)
    for marker in markers:
        groups[marker['font']].append(marker)
    return groups


def numbered_scene_regions(page, sentences):
    markers = detect_scene_markers(page)
    if not markers:
        return []
    first = min(m['bottom'] for m in markers)
    headers = [s['rect']['bottom'] for s in sentences
               if SECTION.match(plain(s['text'])) and s['rect']['bottom'] < first - .035]
    section_top = max(headers, default=.12) + .01
    rows = []
    for marker in sorted(markers, key=lambda m: (m['bottom'], m['left'])):
        if not rows or abs(marker['bottom'] - rows[-1][0]['bottom']) > .035:
            rows.append([])
        rows[-1].append(marker)
    regions = []
    top = section_top
    for row in rows:
        row.sort(key=lambda m: m['left'])
        bottom = min(.94, max(m['bottom'] for m in row) + .012)
        for i, marker in enumerate(row):
            left = 0 if i == 0 else marker['left'] - .028
            right = 1 if i + 1 == len(row) else row[i + 1]['left'] - .028
            regions.append({'id': f"scene-{marker['number']}", 'number': marker['number'],
                            'rect': [left, top, right, bottom], 'anchor': section_top,
                            'source': 'pdf_sequence_marker'})
        top = bottom
    return regions


def prepare_page_dialogue(page, sentences, reviewed=None):
    reviewed = reviewed or {}
    regions = numbered_scene_regions(page, sentences)
    for i, region in enumerate(reviewed.get('regions', [])):
        regions.append({**region, 'anchor': region.get('anchor', region['rect'][1]),
                        'number': region.get('number', i + 1), 'source': 'reviewed_panel'})
    groups = defaultdict(list)
    slots = []
    for sentence in sentences:
        r = sentence['rect']; x = (r['left'] + r['right']) / 2; y = (r['top'] + r['bottom']) / 2
        matches = [g for g in regions if g['rect'][0] <= x <= g['rect'][2]
                   and g['rect'][1] <= y <= g['rect'][3]]
        # Explicit panels can refine the inferred boundary around a speech bubble.
        region = next((g for g in matches if g['source'] == 'reviewed_panel'), matches[0] if matches else None)
        assignment = reviewed.get('scene_assignments', {}).get(sentence['id'])
        if assignment:
            if assignment['text'] != sentence['text'] or assignment['rect'] != sentence['rect']:
                raise ValueError(f"Reviewed scene no longer matches {sentence['id']}")
            region = next((g for g in regions if g['id'] == assignment['sceneId']), None)
            if region is None:
                raise ValueError(f"Missing numbered scene for {sentence['id']}")
        sentence['sceneId'] = region['id'] if region else None
        role = reviewed.get('speakers', {}).get(sentence['id'], {})
        if role and (role['text'] != sentence['text'] or role['rect'] != sentence['rect']):
            raise ValueError(f"Reviewed speaker no longer matches {sentence['id']}")
        # Self introductions in multiple-choice answers and vocabulary lists are
        # narration unless the context explicitly says this is a dialogue.
        context = {'allow_text_inference': region is not None, **role}
        sentence.update(detect_speaker_and_voice(sentence['text'], context))
        if region:
            groups[region['id']].append(sentence)
        else:
            slots.append(((r['top'], 0, r['left']), [sentence]))
    for region in regions:
        entries = groups.pop(region['id'], [])
        if entries:
            slots.append(((region['anchor'], region['number'], 0), sort_sentences_by_dialogue_logic(entries)))
    result = [s for _, entries in sorted(slots, key=lambda item: item[0]) for s in entries]
    assert {s['id'] for s in result} == {s['id'] for s in sentences} and len(result) == len(sentences)
    return result, regions
