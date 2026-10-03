import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import pymupdf as fitz

from tools.build_textbook_assets import (
    build, extract_sentences, normalized_rect, parse_pages, parser,
    selected_pages, synthesize, translate_sentences, translate_text,
    configure_sentence_voice, speech_fingerprint, staging_path, VolcTtsError,
    check_or_test_tts,
)


class AssetBuilderTests(unittest.TestCase):
    def setUp(self):
        configuration = patch.multiple('tools.build_textbook_assets', VOLC_API_KEY='test-key',
            VOLC_APPID='', VOLC_TOKEN='', VOLC_RESOURCE_ID='seed-tts-2.0', VOICE_MAP={
                role: 'test-' + role for role in ('girl', 'boy', 'dino',
                'teacher_female', 'teacher_male', 'narrator')})
        configuration.start()
        self.addCleanup(configuration.stop)

    def test_name_corrections_survive_old_translation_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / 'translations.json'
            cache.write_text(json.dumps({'Peter': 'Peter'}), encoding='utf-8')
            args = parser().parse_args([])
            entries = [{'text': 'Peter'}]
            with patch('tools.build_textbook_assets.translate_text') as remote:
                asyncio.run(translate_sentences(entries, args, cache, Path(temp) / 'book.json'))
                remote.assert_not_called()
            self.assertEqual(entries[0]['translation'], '彼得')

    def test_html_encoded_whitespace_is_not_a_successful_translation(self):
        args = parser().parse_args([])
        with patch('tools.build_textbook_assets.MyMemoryTranslator') as translator:
            translator.return_value.translate.return_value = '&#10;'
            with self.assertRaisesRegex(ValueError, 'Empty translation'):
                translate_text('down.', args)

    def test_download_stages_outside_flutter_assets_then_publishes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'assets').mkdir()
            args = parser().parse_args([])
            staged = []
            def record_staging(destination):
                path = staging_path(destination)
                staged.append(path)
                return path
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.synthesize_http_audio', return_value=b'ID3' + b'mock downloaded audio' * 30
            ), patch('tools.build_textbook_assets.staging_path', side_effect=record_staging):
                asyncio.run(synthesize([{'id': 's1', 'text': 'Hello!',
                                         'audioPath': 'assets/s1.mp3'}], args))
            self.assertTrue(staged[0].is_relative_to(root / '.asset-cache'))
            self.assertTrue((root / 'assets/s1.mp3').read_bytes().startswith(b'ID3'))
            self.assertFalse(staged[0].exists())

    def test_translation_recovers_from_transient_network_error(self):
        with tempfile.TemporaryDirectory() as temp:
            args = parser().parse_args(['--retries', '2', '--translation-delay', '0'])
            entries = [{'text': 'Hello!'}]
            with patch('tools.build_textbook_assets.translate_text',
                       side_effect=[OSError('connection reset'), '你好！']) as remote, patch(
                'tools.build_textbook_assets.asyncio.sleep', new_callable=AsyncMock
            ):
                asyncio.run(translate_sentences(entries, args, Path(temp) / 'cache.json', Path(temp) / 'book.json'))
            self.assertEqual(remote.call_count, 2)
            self.assertEqual(entries[0]['translation'], '你好！')

    def test_default_body_range_and_explicit_range(self):
        self.assertEqual(selected_pages(parser().parse_args([]), 89), list(range(8, 73)))
        args = parser().parse_args(['--start-page', '13', '--end-page', '17'])
        self.assertEqual(selected_pages(args, 89), [13, 14, 15, 16, 17])
        for flags in [['--start-page', '73', '--end-page', '72'],
                      ['--pages', '8', '--start-page', '8']]:
            with self.assertRaises(ValueError):
                selected_pages(parser().parse_args(flags), 89)

    def test_translation_deduplicates_caches_and_retries_failed_entries(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / 'translations.json'
            manifest = Path(temp) / 'book.json'
            args = parser().parse_args(['--retries', '1', '--translation-delay', '0'])
            entries = [{'text': 'Hello!'}, {'text': 'Hello!'}, {'text': 'Goodbye!'}]
            def translate(text, args):
                if text == 'Goodbye!':
                    raise OSError('offline')
                return '你好！'
            with patch('tools.build_textbook_assets.translate_text', side_effect=translate) as remote:
                asyncio.run(translate_sentences(entries, args, cache, manifest))
                self.assertEqual(remote.call_count, 2)
            self.assertEqual([e['translation'] for e in entries], ['你好！', '你好！', ''])
            with patch('tools.build_textbook_assets.translate_text', return_value='再见！') as remote:
                asyncio.run(translate_sentences(entries, args, cache, manifest))
                remote.assert_called_once_with('Goodbye!', args)
            self.assertEqual(entries[-1]['translation'], '再见！')

    def test_translations_are_written_to_real_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pdf = root / 'textbook.pdf'
            with fitz.open() as document:
                page = document.new_page()
                page.insert_text((40, 40), 'Hello!')
                page.insert_text((40, 80), 'Goodbye!')
                document.save(pdf)
            args = parser().parse_args([str(pdf), '--start-page', '1', '--end-page', '1',
                                       '--retries', '1', '--translation-delay', '0'])
            async def fake_audio(sentences, args):
                for sentence in sentences:
                    (root / sentence['audioPath']).write_bytes(b'mock MP3')
            def translate(text, args):
                if text == 'Goodbye!':
                    raise OSError('offline')
                return '你好！'
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.translate_text', side_effect=translate
            ), patch('tools.build_textbook_assets.synthesize', side_effect=fake_audio):
                build(args)
            manifest = json.loads((root / args.output / 'book.json').read_text(encoding='utf-8'))
            self.assertEqual([s['translation'] for s in manifest['pages'][0]['sentences']], ['你好！', ''])

    def test_page_ranges_validate_and_deduplicate(self):
        self.assertEqual(parse_pages('8-11,9', 89), [8, 9, 10, 11])
        for selection in ['0', '5-2', '90', 'oops']:
            with self.assertRaises(ValueError):
                parse_pages(selection, 89)

    def test_wraps_columns_lists_and_abbreviations(self):
        with fitz.open() as doc:
            page = doc.new_page(width=400, height=400)
            for point, text in [
                ((20, 30), 'Good morning,'), ((20, 47), 'Lingling.'),
                ((230, 30), 'Hello, Mr. Brown.'),
                ((20, 100), '1. Greet people'), ((20, 116), '2. Say your name'),
                ((20, 160), '123'), ((20, 200), '!!!'),
                ((20, 250), "Hello, Tim. I'm"), ((20, 267), 'Dino Dinosaur.'),
            ]:
                page.insert_text(point, text, fontsize=11)
            texts = [text for text, _ in extract_sentences(page)]
            self.assertIn('Good morning, Lingling.', texts)
            self.assertIn('Hello, Mr. Brown.', texts)
            self.assertIn('Greet people', texts)
            self.assertIn('Say your name', texts)
            self.assertIn("Hello, Tim. I'm Dino Dinosaur.", texts)
            self.assertNotIn('123', texts)
            self.assertNotIn('!!!', texts)

    def test_rotated_coordinates_match_rendered_frame(self):
        with fitz.open() as doc:
            page = doc.new_page(width=200, height=100)
            page.set_rotation(90)
            self.assertEqual(normalized_rect(fitz.Rect(20, 10, 80, 30), page),
                             {'left': .7, 'top': .1, 'right': .9, 'bottom': .4})

    def test_cached_audio_does_not_request_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = parser().parse_args([])
            sentence = {'id': 'cached', 'text': 'Hello!', 'audioPath': 'cached.mp3'}
            import hashlib
            configure_sentence_voice(sentence)
            key = speech_fingerprint(sentence)
            cache = root / '.asset-cache/speech-volc-http-v3-doubao2'
            cache.mkdir(parents=True)
            data = b'ID3' + b'cached mp3' * 50
            (cache / f'{key}.mp3').write_bytes(data)
            (cache / f'{key}.json').write_text(json.dumps({'sha256': hashlib.sha256(data).hexdigest()}))
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.synthesize_http_audio'
            ) as communicate:
                asyncio.run(synthesize([sentence], args))
                communicate.assert_not_called()

    def test_failed_audio_is_not_published(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = parser().parse_args(['--concurrency', '1', '--retries', '1', '--timeout', '1'])
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.synthesize_http_audio', side_effect=VolcTtsError('offline', retryable=True)
            ):
                with self.assertRaisesRegex(RuntimeError, 'Audio synthesis failed'):
                    asyncio.run(synthesize([{'id': 's1', 'text': 'Hello!', 'audioPath': 's1.mp3'}], args))
                self.assertFalse((root / 's1.mp3').exists())

    def test_transient_http_failure_retries_and_terminal_error_does_not(self):
        for retryable, calls in [(True, 2), (False, 1)]:
            with self.subTest(retryable=retryable), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                args = parser().parse_args(['--retries', '2'])
                entries = [{'id': 's1', 'text': 'Hello!', 'audioPath': 'assets/s1.mp3'}]
                with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                    'tools.build_textbook_assets.synthesize_http_audio',
                    side_effect=[VolcTtsError('service error', retryable=retryable), b'ID3' + b'a' * 300]
                ) as remote, patch('tools.build_textbook_assets.asyncio.sleep', new_callable=AsyncMock):
                    if retryable:
                        asyncio.run(synthesize(entries, args))
                        self.assertTrue((root / 'assets/s1.mp3').is_file())
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'Audio synthesis failed'):
                            asyncio.run(synthesize(entries, args))
                        self.assertFalse((root / 'assets/s1.mp3').exists())
                    self.assertEqual(remote.call_count, calls)

    def test_missing_voice_configuration_preserves_existing_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pdf = root / 'textbook.pdf'
            with fitz.open() as doc:
                page = doc.new_page()
                page.insert_text((30, 40), 'Hello!')
                doc.save(pdf)
            args = parser().parse_args([str(pdf), '--pages', '1'])
            output = root / args.output
            (output / 'images').mkdir(parents=True)
            cover = output / 'images/cover.webp'
            cover.write_bytes(b'original image')
            manifest = output / 'book.json'
            manifest.write_text('{"pages": []}', encoding='utf-8')
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.VOICE_MAP', {'narrator': '<VOICE_TYPE_NARRATOR>'}
            ), patch('tools.build_textbook_assets.requests.post') as remote:
                with self.assertRaisesRegex(ValueError, 'VOICE_MAP'):
                    build(args)
                remote.assert_not_called()
            self.assertEqual(cover.read_bytes(), b'original image')
            self.assertEqual(manifest.read_text(), '{"pages": []}')
            self.assertEqual(len(list((output / 'images').iterdir())), 1)

    def test_plan_only_needs_no_credentials_and_does_not_publish_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pdf = root / 'textbook.pdf'
            with fitz.open() as doc:
                page = doc.new_page()
                page.insert_text((30, 40), 'Hello!')
                doc.save(pdf)
            args = parser().parse_args([str(pdf), '--pages', '1', '--plan-only'])
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.VOLC_API_KEY', '<YOUR_API_KEY>'
            ), patch('tools.build_textbook_assets.requests.post') as remote:
                build(args)
                remote.assert_not_called()
            self.assertFalse((root / 'assets').exists())
            plan = json.loads((root / '.asset-cache/dialogue-plan.json').read_text(encoding='utf-8'))
            self.assertEqual(plan['manifest']['pages'][0]['sentences'][0]['ttsProvider'], 'volcengine-http-v3-doubao2')

    def test_single_sentence_probe_writes_build_output_without_touching_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = parser().parse_args(['--tts-test-text', 'Hello, my name is Dino.', '--tts-test-role', 'dino'])
            with patch('tools.build_textbook_assets.PROJECT_ROOT', root), patch(
                'tools.build_textbook_assets.synthesize_http_audio', return_value=b'ID3' + b'a' * 300
            ) as remote:
                check_or_test_tts(args)
            self.assertTrue((root / 'build/tts-check/dino.mp3').is_file())
            self.assertFalse((root / 'assets').exists())
            self.assertEqual(remote.call_args.args[0]['pitchShift'], 3)
            self.assertEqual(remote.call_args.args[0]['voice'], 'test-dino')

    def test_local_config_check_does_not_call_api(self):
        args = parser().parse_args(['--check-tts-config'])
        with patch('tools.build_textbook_assets.requests.post') as remote:
            check_or_test_tts(args)
            remote.assert_not_called()

    def test_probe_rejects_invalid_batch_settings(self):
        args = parser().parse_args(['--tts-test-text', 'Hello!', '--concurrency', '0'])
        with self.assertRaisesRegex(ValueError, 'positive'):
            check_or_test_tts(args)


if __name__ == '__main__':
    unittest.main()
