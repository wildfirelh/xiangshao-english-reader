import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// The native API returns token timestamps, but does not return probabilities.
/// Keeping this distinction prevents text similarity being called confidence.
class SpeechRecognitionSnapshot {
  const SpeechRecognitionSnapshot({
    required this.text,
    this.tokens = const [],
    this.timestamps = const [],
  });

  final String text;
  final List<String> tokens;
  final List<double> timestamps;
}

abstract class SpeechRecognitionBackend {
  Future<void> prepare();
  Future<void> begin();
  void acceptPcm(Uint8List bytes);
  Future<SpeechRecognitionSnapshot> finish();
  Future<void> cancel();
  Future<void> dispose();
}

class SherpaModelPaths {
  const SherpaModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  Map<String, String> toMap() => {
    'encoder': encoder,
    'decoder': decoder,
    'joiner': joiner,
    'tokens': tokens,
  };
}

/// One long lived isolate owns every C++ recognizer and stream pointer. PCM is
/// decoded as it arrives, so finishing usually only flushes trailing context.
class SherpaRecognitionWorker implements SpeechRecognitionBackend {
  SherpaRecognitionWorker({required this.modelProvider, this.libraryPath});

  final Future<SherpaModelPaths> Function() modelProvider;
  final String? libraryPath;
  Isolate? _isolate;
  ReceivePort? _messages;
  ReceivePort? _failures;
  ReceivePort? _exits;
  SendPort? _commands;
  final _pending = <int, Completer<Object?>>{};
  Completer<void>? _started;
  Future<void>? _preparing;
  Future<void>? _disposing;
  int _commandId = 0;
  bool _disposed = false;
  bool _active = false;
  Object? _streamFailure;

  @override
  Future<void> prepare() {
    if (_disposed) return Future.error(StateError('Recognizer disposed'));
    return _preparing ??= _prepare().catchError((Object error) {
      _preparing = null;
      throw error;
    });
  }

  Future<void> _prepare() async {
    final paths = await modelProvider();
    if (_disposed) throw StateError('Recognizer disposed');
    _started = Completer<void>();
    _messages = ReceivePort()..listen(_onMessage);
    _failures = ReceivePort()
      ..listen((message) {
        _fail(StateError('Offline recognition failed: $message'));
      });
    _exits = ReceivePort()
      ..listen((_) {
        if (!_disposed) _fail(StateError('Offline recognizer exited'));
      });
    _isolate = await Isolate.spawn<List<Object?>>(
      _recognitionMain,
      [_messages!.sendPort, paths.toMap(), libraryPath],
      onError: _failures!.sendPort,
      onExit: _exits!.sendPort,
      errorsAreFatal: true,
      debugName: 'offline-english-recognizer',
    );
    try {
      await _started!.future.timeout(const Duration(seconds: 30));
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  void _onMessage(dynamic message) {
    final response = message as Map;
    if (response['type'] == 'ready') {
      _commands = response['port'] as SendPort;
      if (!(_started?.isCompleted ?? true)) _started!.complete();
      return;
    }
    if (response['type'] == 'fatal') {
      _fail(StateError(response['error'] as String));
      return;
    }
    final id = response['id'] as int;
    if (id == 0) {
      _streamFailure = StateError(response['error'] as String);
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (response.containsKey('error')) {
      completer.completeError(StateError(response['error'] as String));
    } else {
      completer.complete(response['result']);
    }
  }

  void _fail(Object error) {
    if (!(_started?.isCompleted ?? true)) _started!.completeError(error);
    for (final request in _pending.values) {
      if (!request.isCompleted) request.completeError(error);
    }
    _pending.clear();
    _commands = null;
    _streamFailure = error;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _messages?.close();
    _failures?.close();
    _exits?.close();
  }

  Future<Object?> _request(String command) {
    final port = _commands;
    if (port == null) return Future.error(StateError('Recognizer unavailable'));
    final id = ++_commandId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send({'id': id, 'command': command});
    return completer.future;
  }

  @override
  Future<void> begin() async {
    await prepare();
    if (_disposed) throw StateError('Recognizer disposed');
    _streamFailure = null;
    await _request('begin');
    _active = true;
  }

  @override
  void acceptPcm(Uint8List bytes) {
    if (!_active || _disposed || bytes.isEmpty) return;
    _commands?.send({
      'id': 0,
      'command': 'pcm',
      'bytes': TransferableTypedData.fromList([bytes]),
    });
  }

  @override
  Future<SpeechRecognitionSnapshot> finish() async {
    if (!_active || _disposed) throw StateError('No active utterance');
    _active = false;
    final result = (await _request('finish')) as Map;
    final failure = _streamFailure;
    if (failure != null) throw failure;
    return SpeechRecognitionSnapshot(
      text: result['text'] as String,
      tokens: List<String>.from(result['tokens'] as List),
      timestamps: List<double>.from(result['timestamps'] as List),
    );
  }

  @override
  Future<void> cancel() async {
    _active = false;
    if (_commands != null) await _request('cancel');
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _active = false;
    try {
      // Wait for construction before sending dispose: killing a loading
      // isolate immediately would skip the recognizer's native free().
      try {
        await _preparing;
      } catch (_) {
        // Initialization already failed; no native instance remains.
      }
      if (_commands != null) {
        try {
          await _request('dispose').timeout(const Duration(seconds: 3));
        } finally {
          _isolate?.kill(priority: Isolate.immediate);
        }
      }
    } finally {
      _commands = null;
      _messages?.close();
      _failures?.close();
      _exits?.close();
      _isolate = null;
    }
  }
}

void _recognitionMain(List<Object?> arguments) {
  final replies = arguments[0] as SendPort;
  final paths = arguments[1] as Map<String, String>;
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  final commands = ReceivePort();
  try {
    sherpa.initBindings(arguments[2] as String?);
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: paths['encoder']!,
            decoder: paths['decoder']!,
            joiner: paths['joiner']!,
          ),
          tokens: paths['tokens']!,
          modelType: 'zipformer2',
          numThreads: 2,
          debug: false,
        ),
        enableEndpoint: false,
        // No reference text or hotwords enter the recognizer. Recognition
        // must remain independent of the answer being assessed.
        decodingMethod: 'greedy_search',
      ),
    );
  } catch (error) {
    recognizer?.free();
    commands.close();
    replies.send({'type': 'fatal', 'error': error.toString()});
    return;
  }
  final engine = recognizer;
  var trailingByte = <int>[];
  void decode() {
    while (engine.isReady(stream!)) {
      engine.decode(stream!);
    }
  }

  replies.send({'type': 'ready', 'port': commands.sendPort});
  commands.listen((dynamic message) {
    final command = message as Map;
    final id = command['id'] as int;
    try {
      Object? result;
      switch (command['command']) {
        case 'begin':
          stream?.free();
          stream = engine.createStream();
          trailingByte = [];
        case 'pcm':
          if (stream == null) break;
          final incoming = (command['bytes'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final bytes = Uint8List.fromList([...trailingByte, ...incoming]);
          final count = bytes.length ~/ 2;
          trailingByte = bytes.length.isOdd ? [bytes.last] : [];
          final view = ByteData.sublistView(bytes);
          final samples = Float32List(count);
          for (var i = 0; i < count; i++) {
            samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
          }
          stream!.acceptWaveform(samples: samples, sampleRate: 16000);
          decode();
        case 'finish':
          if (stream == null) throw StateError('No active stream');
          // The encoder needs right context. Padding is recognition-only and
          // is deliberately absent from the user's WAV recording.
          stream!.acceptWaveform(samples: Float32List(5120), sampleRate: 16000);
          stream!.inputFinished();
          decode();
          final hypothesis = engine.getResult(stream!);
          result = {
            'text': hypothesis.text,
            'tokens': hypothesis.tokens,
            'timestamps': hypothesis.timestamps,
          };
          stream!.free();
          stream = null;
        case 'cancel':
          stream?.free();
          stream = null;
          trailingByte = [];
        case 'dispose':
          stream?.free();
          stream = null;
          engine.free();
          commands.close();
      }
      if (id != 0) replies.send({'id': id, 'result': result});
    } catch (error) {
      replies.send({'id': id, 'error': error.toString()});
    }
  });
}
