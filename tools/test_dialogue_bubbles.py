import asyncio
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pymupdf as fitz

from tools.build_textbook_assets import (
    build, cluster_dialogue_bubbles, configure_bubble_audio,
    configure_sentence_voice, extract_sentences, page_audio_entries, parser,
    populate_bubble_translations, speech_fingerprint, synthesize,
)
from tools.dialogue_processing import load_reviewed_context, prepare_page_dialogue


class DialogueBubbleTests(unittest.TestCase):
    def setUp(self):
        configuration = patch.multiple('tools.build_textbook_assets', VOLC_API_KEY='test-key',
            VOLC_APPID='', VOLC_TOKEN='', VOLC_RESOURCE_ID='seed-tts-2.0', VOICE_MAP={
                role: 'test-' + role for role in ('girl', 'boy', 'dino',
                'teacher_female', 'teacher_male', 'narrator')})
        configuration.start()
        self.addCleanup(configuration.stop)

    def entries(self, page, *, scene='scene-1', speaker='Peter'):
        return [{'id': f'u1_p001_s{i:03}', 'text': text, 'rect': rect,
                 'sceneId': scene, 'speaker': speaker, 'voiceRole': 'boy',
                 'voiceSource': 'reviewed_context', 'translation': ''}
                for i, (text, rect) in enumerate(extract_sentences(page), 1)]

    def test_sentence_punctuation_splits_become_one_natural_bubble(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), "Thank you. What is this?")
            entries = self.entries(page)
            # Simulate the legacy question-before-answer list, which must not
            # invert the original order inside a complete speech bubble.
            bubbles = cluster_dialogue_bubbles(page, list(reversed(entries)), [])
            self.assertEqual(len(bubbles), 1)
            self.assertEqual(bubbles[0]['text'], 'Thank you. What is this?')
            self.assertEqual(bubbles[0]['sentenceIds'], [s['id'] for s in entries])
            self.assertEqual(bubbles[0]['rect']['left'], entries[0]['rect']['left'])
            self.assertEqual(bubbles[0]['rect']['right'], entries[-1]['rect']['right'])
            self.assertEqual({s['bubbleId'] for s in entries}, {bubbles[0]['id']})

    def test_separate_pdf_blocks_can_be_lines_of_the_same_bubble(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Good morning.')
            page.insert_text((40, 57), "I'm Peter.")
            bubbles = cluster_dialogue_bubbles(page, self.entries(page), [])
            self.assertEqual(len(bubbles), 1)
            self.assertEqual(bubbles[0]['text'], "Good morning. I'm Peter.")

    def test_close_text_never_merges_different_panels_or_speakers(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Hello! Hello!')
            for difference in ('sceneId', 'speaker', 'voiceRole'):
                with self.subTest(difference=difference):
                    entries = self.entries(page)
                    entries[1][difference] = 'other'
                    self.assertEqual(len(cluster_dialogue_bubbles(page, entries, [])), 2)

    def test_wide_text_block_does_not_combine_separate_columns(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Hello!')
            page.insert_text((220, 40), 'Goodbye!')
            # A real PDF may store distant columns together. Use one wide block
            # to prove block membership cannot override the column gap.
            real_get_text = page.get_text
            def text(option, *args, **kwargs):
                if option == 'blocks':
                    return [(40, 25, 280, 44, 'Hello!\nGoodbye!', 0, 0)]
                return real_get_text(option, *args, **kwargs)
            entries = self.entries(page)
            with patch.object(page, 'get_text', side_effect=text):
                self.assertEqual(len(cluster_dialogue_bubbles(page, entries, [])), 2)

    def test_narration_labels_and_list_items_remain_independent(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), '1. Greet people\n2. Say your name\n3. Read letters')
            entries = self.entries(page, scene=None, speaker='Narrator')
            self.assertEqual(len(entries), 3)
            self.assertEqual(len(cluster_dialogue_bubbles(page, entries, [])), len(entries))

    def test_actual_unit_one_has_reviewed_whole_bubbles_and_precise_children(self):
        project = Path(__file__).resolve().parents[1]
        pdf = project / 'assets/textbook.pdf'
        if not pdf.exists():
            self.skipTest('Local textbook PDF is not installed')
        context = load_reviewed_context(pdf, 'xiangshao_3_1')
        expected = {
            8: [(10, 11), (12, 14), (13, 15), (21, 22)],
            9: [(4, 5), (8, 10), (9, 11), (19, 20)],
            11: [(3, 4)],
        }
        with fitz.open(pdf) as doc:
            for number, groups in expected.items():
                with self.subTest(page=number):
                    page = doc[number - 1]
                    entries = [{'id': f'u1_p{number:03}_s{i:03}', 'text': t, 'rect': r}
                               for i, (t, r) in enumerate(extract_sentences(page), 1)]
                    entries, regions = prepare_page_dialogue(page, entries, context.get(str(number)))
                    bubbles = cluster_dialogue_bubbles(page, entries, regions, context.get(str(number)))
                    actual = {tuple(b['sentenceIds']) for b in bubbles if len(b['sentenceIds']) > 1}
                    target = {tuple(f'u1_p{number:03}_s{i:03}' for i in group) for group in groups}
                    self.assertEqual(actual, target)
                    self.assertEqual(sum(len(b['sentenceIds']) for b in bubbles), len(entries))
                    for bubble in bubbles:
                        children = [next(s for s in entries if s['id'] == i) for i in bubble['sentenceIds']]
                        self.assertEqual(len({s.get('speaker') for s in children}), 1)
                        self.assertEqual(len({s.get('sceneId') for s in children}), 1)

    def test_scene_number_overrides_top_coordinate_for_comic_order(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Second picture.')
            page.insert_text((40, 200), 'First picture.')
            entries = self.entries(page)
            entries[0]['sceneId'] = 'scene-2'
            regions = [{'id': 'scene-1', 'number': 1, 'anchor': .1},
                       {'id': 'scene-2', 'number': 2, 'anchor': .1}]
            bubbles = cluster_dialogue_bubbles(page, entries, regions)
            self.assertEqual([b['text'] for b in bubbles], ['First picture.', 'Second picture.'])

    def test_reviewed_membership_overrides_geometry_but_not_voice_identity(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Hello!')
            page.insert_text((40, 100), 'Goodbye!')
            entries = self.entries(page)
            reviewed = {'bubbles': [{'sentenceIds': [s['id'] for s in entries]}]}
            self.assertEqual(len(cluster_dialogue_bubbles(page, entries, [], reviewed)), 1)
            entries[1]['speaker'] = 'Anne'
            with self.assertRaisesRegex(ValueError, 'scenes or speakers'):
                cluster_dialogue_bubbles(page, entries, [], reviewed)

    def test_bubble_cache_reuses_single_utterance_and_keeps_sentence_keys(self):
        with fitz.open() as doc, tempfile.TemporaryDirectory() as temp:
            page = doc.new_page(width=400, height=400)
            page.insert_text((40, 40), 'Hello!')
            page.insert_text((40, 100), "Good morning. I'm Peter.")
            entries = self.entries(page)
            for s in entries:
                configure_sentence_voice(s)
                s['speechFingerprint'] = speech_fingerprint(s)
                s['audioPath'] = 'assets/audios/' + s['id'] + '.mp3'
            keys = [s['speechFingerprint'] for s in entries]
            bubbles = cluster_dialogue_bubbles(page, entries, [])
            configure_bubble_audio(bubbles, entries, 'assets')
            self.assertEqual([speech_fingerprint(s) for s in entries], keys)
            self.assertEqual(bubbles[0]['audioPath'], entries[0]['audioPath'])
            self.assertNotEqual(bubbles[1]['audioPath'], entries[1]['audioPath'])
            self.assertEqual(bubbles[1]['text'], "Good morning. I'm Peter.")
            args = parser().parse_args(['--retries', '1'])
            audio = b'ID3' + b'mock audio' * 40
            cache = Path(temp) / '.asset-cache/speech-volc-http-v3-doubao2'
            cache.mkdir(parents=True)
            for s in entries:
                (cache / (s['speechFingerprint'] + '.mp3')).write_bytes(audio)
                (cache / (s['speechFingerprint'] + '.json')).write_text(json.dumps({
                    'sha256': hashlib.sha256(audio).hexdigest()}), encoding='utf-8')
            with patch('tools.build_textbook_assets.PROJECT_ROOT', Path(temp)), patch(
                'tools.build_textbook_assets.synthesize_http_audio', return_value=audio
            ) as remote:
                asyncio.run(synthesize(entries + bubbles, args))
                remote.assert_called_once()
                self.assertEqual(remote.call_args.args[0]['text'], "Good morning. I'm Peter.")
                asyncio.run(synthesize(entries + bubbles, args))
                self.assertEqual(remote.call_count, 1)

    def test_bubble_translation_uses_child_order_and_handles_missing(self):
        pages = [{'sentences': [{'id': 's1', 'translation': '你好。'},
                                {'id': 's2', 'translation': None}],
                  'bubbles': [{'sentenceIds': ['s1', 's2']}]}]
        populate_bubble_translations(pages)
        self.assertEqual(pages[0]['bubbles'][0]['translation'], '你好。')

    def test_partial_build_retains_other_pages_and_both_audio_tracks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pdf = root / 'textbook.pdf'
            with fitz.open() as doc:
                for words in ('Hello! Hello!', 'Goodbye! Goodbye!'):
                    doc.new_page().insert_text((40, 40), words)
                doc.save(pdf)
            args = parser().parse_args([str(pdf), '--pages', '1-2', '--dpi', '72'])
            async def fake_audio(entries, args):
                for s in entries:
                    destination = root / s['audioPath']
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(b'ID3' + b'mock audio' * 40)
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.translate_text', return_value='翻译'
            ), patch('tools.build_textbook_assets.synthesize', side_effect=fake_audio):
                build(args)
                path = root / args.output / 'book.json'
                original = json.loads(path.read_text(encoding='utf-8'))
                untouched = copy.deepcopy(original['pages'][1])
                stale = root / original['pages'][0]['bubbles'][0]['audioPath']
                # Replace a selected page's old bubble reference to exercise
                # retiring a superseded whole-bubble MP3 as well as sentences.
                orphan = stale.with_name('old-bubble.mp3')
                orphan.write_bytes(stale.read_bytes())
                original['pages'][0]['bubbles'][0]['audioPath'] = orphan.relative_to(root).as_posix()
                path.write_text(json.dumps(original), encoding='utf-8')
                args.pages = '1'
                args.reuse_images = True
                build(args)
            updated = json.loads(path.read_text(encoding='utf-8'))
            self.assertEqual(len(updated['pages']), 2)
            self.assertEqual(updated['pages'][1], untouched)
            self.assertTrue(all((root / s['audioPath']).exists() for s in page_audio_entries(updated['pages'])))
            self.assertFalse(orphan.exists())
            self.assertTrue((root / '.asset-cache/previous-audio/old-bubble.mp3').is_file())
            self.assertEqual(updated['pages'][0]['bubbles'][0]['translation'], '翻译 翻译')


if __name__ == '__main__':
    unittest.main()
