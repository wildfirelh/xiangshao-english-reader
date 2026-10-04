import 'dart:async';

import 'package:audio_session/audio_session.dart'
    show
        AudioSession,
        AudioSessionConfiguration,
        AndroidAudioContentType,
        AndroidAudioUsage;
import 'package:english_point_reading/services/audio_interruption_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class TestAudioSession extends Fake implements AudioSession {
  final focusEvents = StreamController<AudioInterruptionEvent>.broadcast(
    sync: true,
  );
  final noisyEvents = StreamController<void>.broadcast(sync: true);
  int configurationCount = 0;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      focusEvents.stream;

  @override
  Stream<void> get becomingNoisyEventStream => noisyEvents.stream;

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurationCount++;
  }

  Future<void> closeStreams() async {
    await focusEvents.close();
    await noisyEvents.close();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('real AudioSession sends media speech and duck-without-pause configuration to the platform', () async {
    const channel = MethodChannel('com.ryanheise.audio_session');
    final configurations = <Map<String, dynamic>>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setConfiguration') {
        final arguments = call.arguments as List<dynamic>;
        configurations.add(Map<String, dynamic>.from(arguments.single as Map));
      }
      return null;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final source = SystemAudioInterruptionSource();
    addTearDown(source.dispose);
    await source.initialize();
    await source.initialize();
    expect(configurations, hasLength(1));
    final sent = AudioSessionConfiguration.fromJson(configurations.single);
    expect(sent.androidAudioAttributes!.usage, AndroidAudioUsage.media);
    expect(
      sent.androidAudioAttributes!.contentType,
      AndroidAudioContentType.speech,
    );
    expect(sent.androidWillPauseWhenDucked, isFalse);
    expect(
      (await AudioSession.instance).configuration!.androidWillPauseWhenDucked,
      isFalse,
    );
  });

  test('source forwards begin and end and maps unplugged headphones to pause without owning the session', () async {
    final session = TestAudioSession();
    addTearDown(session.closeStreams);
    final source = SystemAudioInterruptionSource(session: session);
    final received = <AudioInterruptionEvent>[];
    source.interruptions.listen(received.add);
    await source.initialize();
    final duckBegin = AudioInterruptionEvent(true, AudioInterruptionType.duck);
    final focusEnd = AudioInterruptionEvent(false, AudioInterruptionType.pause);
    session.focusEvents.add(duckBegin);
    session.focusEvents.add(focusEnd);
    session.noisyEvents.add(null);
    expect(received.take(2), [same(duckBegin), same(focusEnd)]);
    expect(received.last.begin, isTrue);
    expect(received.last.type, AudioInterruptionType.pause);
    session.focusEvents.addError(StateError('Native event failure'));
    session.noisyEvents.addError(StateError('Native route failure'));
    expect(received, hasLength(3));
    await source.dispose();
    session.focusEvents.add(duckBegin);
    session.noisyEvents.add(null);
    expect(received, hasLength(3));
    expect(session.focusEvents.isClosed, isFalse);
    expect(session.noisyEvents.isClosed, isFalse);
  });
}
