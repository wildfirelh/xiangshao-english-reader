import 'package:flutter/foundation.dart';

abstract class SpeechEvaluator {
  Future<void> startRecording(String sentenceId);

  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  );

  void cancel();
}

class EvaluationResult {
  const EvaluationResult({required this.score, required this.details});

  final int score;
  final String details;
}

class MockSpeechEvaluator implements SpeechEvaluator {
  @override
  Future<void> startRecording(String sentenceId) async {
    debugPrint('MockSpeechEvaluator: startRecording($sentenceId)');
  }

  @override
  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  ) async {
    debugPrint(
      'MockSpeechEvaluator: stopAndEvaluate($sentenceId, $referenceText)',
    );
    return const EvaluationResult(score: 0, details: '尚未接入口语评测引擎');
  }

  @override
  void cancel() {
    debugPrint('MockSpeechEvaluator: cancel()');
  }
}
