"""Offline contract tests for Doubao 2.0 HTTP server-sent audio events."""

import base64
from contextlib import ExitStack
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import unittest
import uuid
from unittest.mock import Mock, patch

import requests

from tools import build_textbook_assets as builder


class VolcHttpTests(unittest.TestCase):
    def setUp(self):
        self.appid = 'test-app-id'
        self.token = 'test-secret-token-never-log'
        self.api_key = 'test-api-key-never-log'
        self.voices = {
            'girl': 'test-girl',
            'boy': 'test-boy',
            'dino': 'test-dino',
            'teacher_female': 'test-teacher-female',
            'teacher_male': 'test-teacher-male',
            'narrator': 'test-narrator',
        }
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.multiple(
            builder,
            VOLC_APPID=self.appid,
            VOLC_TOKEN=self.token,
            VOLC_API_KEY='<YOUR_API_KEY>',
            VOLC_RESOURCE_ID='seed-tts-2.0',
            API_URL='https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse',
            VOICE_MAP=self.voices.copy(),
            ROLE_SPEED_MAP=dict.fromkeys(self.voices, 1.0) | {'dino': 1.06},
            ROLE_PITCH_MAP=dict.fromkeys(self.voices, 0) | {'dino': 3},
        ))
        self.args = builder.parser().parse_args([])
        self.audio = b'ID3' + b'offline audio response' * 30

    def sentence(self, role='girl', text='Hello, Peter!'):
        sentence = {'id': 'p1_s1', 'text': text, 'voiceRole': role}
        builder.configure_sentence_voice(sentence)
        return sentence

    @staticmethod
    def event(payload, multiline=False):
        encoded = json.dumps(payload, indent=2 if multiline else None)
        return [b'event: message'] + [
            ('data: ' + line).encode('utf-8') for line in encoded.splitlines()
        ] + [b'']

    def response(self, *, status=200, events=None, lines=None):
        response = Mock()
        response.status_code = status
        if lines is None:
            if events is None:
                events = [
                    {'code': 0, 'data': base64.b64encode(self.audio).decode('ascii')},
                    {'code': 20000000, 'message': 'Success'},
                ]
            lines = [line for event in events for line in self.event(event)]
        response.iter_lines.return_value = iter(lines)
        return response

    def assert_private_error(self, response, *, retryable=None):
        with patch.object(builder.requests, 'post', return_value=response):
            with self.assertRaises(builder.VolcTtsError) as caught:
                builder.synthesize_http_audio(self.sentence(), self.args)
        for secret in (self.token, self.appid, self.api_key):
            self.assertNotIn(secret, str(caught.exception))
        response.close.assert_called_once()
        if retryable is not None:
            self.assertIs(caught.exception.retryable, retryable)
        return caught.exception

    def test_request_contract_decodes_stream_and_assigns_unique_request_ids(self):
        self.args.proxy = 'http://localhost:8080'
        sentence = self.sentence('dino', "Hello, I'm Dino!")
        responses = [self.response(), self.response()]
        with patch.object(builder.requests, 'post', side_effect=responses) as post:
            self.assertEqual(builder.synthesize_http_audio(sentence, self.args), self.audio)
            self.assertEqual(builder.synthesize_http_audio(sentence, self.args), self.audio)
        first, second = [call.kwargs for call in post.call_args_list]
        self.assertEqual(post.call_args_list[0].args[0], builder.API_URL)
        self.assertEqual(first['headers']['X-Api-App-Id'], self.appid)
        self.assertEqual(first['headers']['X-Api-Access-Key'], self.token)
        self.assertNotIn('X-Api-Key', first['headers'])
        self.assertEqual(first['headers']['X-Api-Resource-Id'], 'seed-tts-2.0')
        self.assertEqual(first['headers']['Accept'], 'text/event-stream')
        self.assertEqual(uuid.UUID(first['headers']['X-Api-Request-Id']).version, 4)
        self.assertNotEqual(
            first['headers']['X-Api-Request-Id'], second['headers']['X-Api-Request-Id'],
        )
        self.assertIs(first['stream'], True)
        self.assertIs(first['allow_redirects'], False)
        self.assertEqual(first['timeout'], self.args.timeout)
        self.assertEqual(first['proxies'], {
            'http': self.args.proxy, 'https': self.args.proxy,
        })
        body = first['json']
        self.assertEqual(body['user'], {'uid': 'textbook-asset-builder'})
        self.assertNotIn('app', body)
        params = body['req_params']
        self.assertEqual(params['text'], sentence['text'])
        self.assertEqual(params['speaker'], 'test-dino')
        self.assertEqual(params['audio_params'], {
            'format': 'mp3', 'sample_rate': 24000, 'bit_rate': 64000, 'speech_rate': 6,
        })
        self.assertIsInstance(params['additions'], str)
        self.assertEqual(json.loads(params['additions']), {
            'explicit_language': 'en', 'post_process': {'pitch': 3},
        })
        for response in responses:
            response.close.assert_called_once()

    def test_api_key_authentication_takes_priority_and_needs_no_legacy_credentials(self):
        with patch.multiple(builder, VOLC_API_KEY=self.api_key,
                            VOLC_APPID='', VOLC_TOKEN=''):
            builder.validate_tts_configuration()
            response = self.response()
            with patch.object(builder.requests, 'post', return_value=response) as post:
                self.assertEqual(builder.synthesize_http_audio(self.sentence(), self.args),
                                 self.audio)
        headers = post.call_args.kwargs['headers']
        self.assertEqual(headers['X-Api-Key'], self.api_key)
        self.assertNotIn('X-Api-App-Id', headers)
        self.assertNotIn('X-Api-Access-Key', headers)

    def test_api_key_placeholders_fall_back_to_legacy_credentials(self):
        for value in ('', '  ', '<YOUR_API_KEY>'):
            with self.subTest(value=value), patch.object(builder, 'VOLC_API_KEY', value):
                builder.validate_tts_configuration()
                with patch.object(builder.requests, 'post', return_value=self.response()) as post:
                    builder.synthesize_http_audio(self.sentence(), self.args)
                headers = post.call_args.kwargs['headers']
                self.assertEqual(headers['X-Api-App-Id'], self.appid)
                self.assertEqual(headers['X-Api-Access-Key'], self.token)
                self.assertNotIn('X-Api-Key', headers)

    def test_no_proxy_and_standard_role_uses_normal_rate_and_pitch(self):
        with patch.object(builder.requests, 'post', return_value=self.response()) as post:
            builder.synthesize_http_audio(self.sentence('boy'), self.args)
        self.assertIsNone(post.call_args.kwargs['proxies'])
        params = post.call_args.kwargs['json']['req_params']
        self.assertEqual(params['audio_params']['speech_rate'], 0)
        self.assertEqual(json.loads(params['additions'])['post_process']['pitch'], 0)

    def test_voice_roles_keep_distinct_speakers_and_dino_prosody(self):
        for role, voice in self.voices.items():
            with self.subTest(role=role):
                sentence = self.sentence(role)
                self.assertEqual(sentence['voice'], voice)
                self.assertEqual(sentence['speedRatio'], 1.06 if role == 'dino' else 1.0)
                self.assertEqual(sentence['pitchShift'], 3 if role == 'dino' else 0)
                self.assertEqual(sentence['ttsProvider'], 'volcengine-http-v3-doubao2')
        with patch.object(builder, 'ROLE_SPEED_MAP', {'dino': 1.12, 'girl': 0.9}), \
                patch.object(builder, 'ROLE_PITCH_MAP', {'dino': 5, 'girl': -2}):
            self.assertEqual(self.sentence('dino')['speedRatio'], 1.12)
            self.assertEqual(self.sentence('girl')['speedRatio'], 0.9)
            self.assertEqual(self.sentence('dino')['pitchShift'], 5)
            self.assertEqual(self.sentence('girl')['pitchShift'], -2)

    def test_configuration_accepts_actual_voices_only_for_selected_roles(self):
        builder.validate_tts_configuration()
        with patch.object(builder, 'VOICE_MAP', {
            role: voice if role == 'girl' else '<VOICE_TYPE_PLACEHOLDER>'
            for role, voice in self.voices.items()
        }):
            builder.validate_tts_configuration([{'voiceRole': 'girl'}])
            with self.assertRaises((ValueError, builder.VolcTtsError)):
                builder.validate_tts_configuration()

    def test_configuration_rejects_missing_auth_resource_and_voice_without_secret_leaks(self):
        for field in ('VOLC_APPID', 'VOLC_TOKEN', 'VOLC_RESOURCE_ID'):
            for value in ('', '  ', '<YOUR_VALUE>'):
                with self.subTest(field=field, value=value), patch.object(builder, field, value):
                    with self.assertRaises((ValueError, builder.VolcTtsError)) as caught:
                        builder.validate_tts_configuration()
                    for secret in (self.token, self.appid, self.api_key):
                        self.assertNotIn(secret, str(caught.exception))
        for value in ('', '  ', '<VOICE_TYPE_GIRL>'):
            with self.subTest(voice=value), patch.dict(builder.VOICE_MAP, {'girl': value}):
                with self.assertRaises((ValueError, builder.VolcTtsError)):
                    builder.validate_tts_configuration([{'voiceRole': 'girl'}])

    def test_configuration_rejects_unsupported_rate_and_pitch(self):
        for speed in (0.49, 2.01, float('nan'), float('inf')):
            with self.subTest(speed=speed), patch.dict(builder.ROLE_SPEED_MAP, {'girl': speed}):
                with self.assertRaises(ValueError):
                    self.sentence()
        for pitch in (-13, 13, 1.5, float('nan')):
            with self.subTest(pitch=pitch), patch.dict(builder.ROLE_PITCH_MAP, {'girl': pitch}):
                with self.assertRaises(ValueError):
                    self.sentence()

    def test_http_authentication_errors_and_redirects_are_terminal(self):
        for status in (301, 302, 307, 401, 403):
            with self.subTest(status=status):
                self.assert_private_error(self.response(status=status), retryable=False)

    def test_http_rate_limit_and_service_errors_are_retryable(self):
        for status in (429, 500, 502, 503, 504):
            with self.subTest(status=status):
                self.assert_private_error(self.response(status=status), retryable=True)

    def test_business_codes_and_concurrency_quota_select_safe_retry_policy(self):
        for code in (1, 45000000, 45000001, 45000002):
            with self.subTest(code=code):
                self.assert_private_error(self.response(events=[{
                    'code': code, 'message': 'Server error ' + self.token,
                }]), retryable=False)
        for code in (50000000, 50000001, 55000000):
            with self.subTest(code=code):
                self.assert_private_error(self.response(events=[{
                    'code': code, 'message': 'Server error ' + self.token,
                }]), retryable=True)
        self.assert_private_error(self.response(events=[{
            'code': 45000000,
            'message': 'quota exceeded for types: concurrency ' + self.token,
        }]), retryable=True)
        self.assert_private_error(self.response(events=[{
            'code': 45000000, 'message': 'quota exceeded for types: daily ' + self.token,
        }]), retryable=False)
        self.assert_private_error(self.response(events=[{
            'code': 45000001,
            'message': 'quota exceeded for types: concurrency ' + self.token,
        }]), retryable=False)

    def test_stream_combines_small_audio_chunks_with_metadata_and_multiline_events(self):
        parts = [self.audio[:3], self.audio[3:31], self.audio[31:]]
        lines = [b': keep alive', b'', b'id: ignored']
        lines += self.event({'code': 0, 'sentence': 'Hello!'}, multiline=True)
        for part in parts:
            lines += self.event({
                'code': 0, 'data': base64.b64encode(part).decode('ascii'),
            }, multiline=True)
        lines += self.event({'code': 0, 'data': '', 'usage': {'text_words': 2}})
        lines += self.event({'code': 20000000, 'message': 'Success'}, multiline=True)
        response = self.response(lines=lines)
        with patch.object(builder.requests, 'post', return_value=response):
            self.assertEqual(builder.synthesize_http_audio(self.sentence(), self.args), self.audio)
        response.close.assert_called_once()

    def test_real_http_chunk_boundaries_reassemble_sse_and_close_connection(self):
        audio = self.audio
        wire = b'\n'.join(self.event({
            'code': 0, 'data': base64.b64encode(audio[:37]).decode('ascii'),
        }) + self.event({
            'code': 0, 'data': base64.b64encode(audio[37:]).decode('ascii'),
        }) + self.event({'code': 20000000})) + b'\n'
        received = []

        class ChunkedHandler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                received.append((self.path, dict(self.headers), json.loads(body)))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Connection', 'close')
                self.end_headers()
                # Break both JSON strings and Base64 at unrelated transport boundaries.
                sizes = (1, 3, 17, 2, 11)
                chunks = []
                offset = 0
                while offset < len(wire):
                    size = sizes[len(chunks) % len(sizes)]
                    part = wire[offset:offset + size]
                    chunks.append(f'{len(part):x}\r\n'.encode() + part + b'\r\n')
                    offset += len(part)
                self.wfile.write(b''.join(chunks) + b'0\r\n\r\n')
                self.wfile.flush()

        server = ThreadingHTTPServer(('127.0.0.1', 0), ChunkedHandler)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        closed = []
        original_close = requests.Response.close

        def close_and_track(response):
            original_close(response)
            closed.append(response)

        try:
            url = f'http://127.0.0.1:{server.server_port}/tts'
            self.args.timeout = 5
            with patch.object(builder, 'API_URL', url), \
                    patch.object(requests.Response, 'close', new=close_and_track), \
                    patch.dict('os.environ', {'NO_PROXY': '127.0.0.1'}):
                self.assertEqual(builder.synthesize_http_audio(self.sentence(), self.args), audio)
            self.assertEqual(len(received), 1)
            path, headers, body = received[0]
            self.assertEqual(path, '/tts')
            self.assertEqual(headers['X-Api-App-Id'], self.appid)
            self.assertEqual(headers['X-Api-Access-Key'], self.token)
            self.assertEqual(headers['X-Api-Resource-Id'], 'seed-tts-2.0')
            self.assertEqual(body['req_params']['speaker'], self.voices['girl'])
            self.assertEqual(len(closed), 1)
            self.assertTrue(closed[0].raw.closed)
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=5)
        self.assertFalse(server_thread.is_alive())

    def test_final_success_record_does_not_require_trailing_blank_line(self):
        lines = self.event({
            'code': 0, 'data': base64.b64encode(self.audio).decode('ascii'),
        }) + self.event({'code': 20000000})[:-1]
        response = self.response(lines=lines)
        with patch.object(builder.requests, 'post', return_value=response):
            self.assertEqual(builder.synthesize_http_audio(self.sentence(), self.args), self.audio)
        response.close.assert_called_once()

    def test_canceled_or_failed_sse_event_cannot_masquerade_as_success(self):
        for event_id in ('151', '153'):
            for code in (0, 20000000):
                lines = self.event({
                    'code': 0, 'data': base64.b64encode(self.audio).decode('ascii'),
                }) + [f'event: {event_id}'.encode(),
                      f'data: {{"code": {code}}}'.encode(), b'']
                with self.subTest(event_id=event_id, code=code):
                    self.assert_private_error(self.response(lines=lines), retryable=False)

    def test_stream_requires_successful_terminal_event_and_nonempty_mp3(self):
        self.assert_private_error(self.response(events=[{
            'code': 0, 'data': base64.b64encode(self.audio).decode('ascii'),
        }]), retryable=True)
        for events in ([], [{'code': 20000000}], [
            {'code': 0, 'data': base64.b64encode(b'ID3').decode('ascii')},
            {'code': 20000000},
        ]):
            with self.subTest(events=events):
                self.assert_private_error(self.response(events=events))

    def test_error_after_valid_partial_audio_never_returns_partial_audio(self):
        self.assert_private_error(self.response(events=[
            {'code': 0, 'data': base64.b64encode(self.audio).decode('ascii')},
            {'code': 50000000, 'message': 'Interrupted ' + self.token},
        ]), retryable=True)

    def test_invalid_base64_and_non_mp3_audio_are_safe_errors(self):
        for value in ('*** not base64 ***', 'SGVsbG8=', 123, ['not-a-string']):
            with self.subTest(data=value):
                self.assert_private_error(self.response(events=[
                    {'code': 0, 'data': value}, {'code': 20000000},
                ]))

    def test_invalid_json_event_and_event_shape_are_safe_errors(self):
        self.assert_private_error(self.response(lines=[
            ('data: broken JSON ' + self.token).encode('utf-8'), b'',
        ]))
        for payload in ([], None, {'data': base64.b64encode(self.audio).decode('ascii')},
                        {'code': '0', 'data': base64.b64encode(self.audio).decode('ascii')}):
            with self.subTest(payload=payload):
                self.assert_private_error(self.response(events=[payload]))
        self.assert_private_error(self.response(lines=[b'data: \xff', b'']))

    def test_transport_failures_do_not_include_sensitive_exception_messages(self):
        for failure in (requests.Timeout('Timeout ' + self.token),
                        requests.ConnectionError('Connection error ' + self.token)):
            with self.subTest(failure=type(failure).__name__), patch.object(
                builder.requests, 'post', side_effect=failure,
            ):
                with self.assertRaises(builder.VolcTtsError) as caught:
                    builder.synthesize_http_audio(self.sentence(), self.args)
                self.assertIs(caught.exception.retryable, True)
                self.assertNotIn(self.token, str(caught.exception))

    def test_network_failure_midstream_closes_response_and_rejects_partial_audio(self):
        for failure in (requests.ReadTimeout('Read failed ' + self.token),
                        requests.exceptions.ChunkedEncodingError('Broken chunk ' + self.token)):
            def interrupted_lines():
                yield from self.event({
                    'code': 0, 'data': base64.b64encode(self.audio).decode('ascii'),
                })
                raise failure

            response = self.response()
            response.iter_lines.return_value = interrupted_lines()
            with self.subTest(failure=type(failure).__name__):
                self.assert_private_error(response, retryable=True)

    def test_fingerprint_separates_effective_audio_parameters_and_ignores_credentials(self):
        sentence = self.sentence()
        original = builder.speech_fingerprint(sentence)
        self.assertEqual(len(original), 64)
        with patch.multiple(builder, VOLC_TOKEN='different-token', VOLC_APPID='different-app',
                            VOLC_API_KEY='different-api-key'):
            self.assertEqual(builder.speech_fingerprint(sentence), original)
        for field, value in (
            ('text', 'Goodbye!'), ('voice', 'another-voice'), ('speedRatio', 0.8),
            ('pitchShift', 3),
        ):
            changed = copy.deepcopy(sentence)
            changed[field] = value
            with self.subTest(field=field):
                self.assertNotEqual(builder.speech_fingerprint(changed), original)
        for field, value in (
            ('API_URL', 'https://example.invalid/another-tts'),
            ('VOLC_RESOURCE_ID', 'another-resource'),
            ('AUDIO_SAMPLE_RATE', 16000), ('AUDIO_BITRATE', 160000),
        ):
            with self.subTest(field=field), patch.object(builder, field, value):
                self.assertNotEqual(builder.speech_fingerprint(sentence), original)
        rounded_same = copy.deepcopy(sentence)
        rounded_same['speedRatio'] = 1.0001
        self.assertEqual(builder.speech_fingerprint(rounded_same), original)


if __name__ == '__main__':
    unittest.main()
