/// Word feedback for an offline follow-along practice attempt.
enum ScoreStatus { correct, warning, error }

class WordEvaluation {
  const WordEvaluation({
    required this.word,
    required this.status,
    required this.score,
    this.recognizedWord,
    this.confidence,
  }) : assert(score >= 0 && score <= 100),
       assert(confidence == null || (confidence >= 0 && confidence <= 1));

  /// Original textbook spelling, including its surrounding punctuation.
  final String word;
  final ScoreStatus status;
  final int score;
  final String? recognizedWord;

  /// A probability supplied by the recognizer, never a text similarity value.
  ///
  /// Sherpa's streaming Dart API does not expose word confidence. Its results
  /// therefore leave this null and provide text agreement feedback instead.
  final double? confidence;
}

class EvaluationResult {
  const EvaluationResult({
    required this.score,
    required this.details,
    this.words = const [],
    this.recognizedText = '',
    this.recordingPath,
    this.hasNativeConfidence = false,
    this.inferenceDuration = Duration.zero,
  }) : assert(score >= 0 && score <= 100);

  final int score;
  final String details;
  final List<WordEvaluation> words;
  final String recognizedText;
  final String? recordingPath;
  final bool hasNativeConfidence;
  final Duration inferenceDuration;
}
