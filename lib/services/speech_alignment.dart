import 'dart:math' as math;

import '../models/speech_evaluation.dart';

/// Aligns each displayed textbook word with a recognized word sequence.
///
/// [confidences], when supplied, must contain a real recognizer probability for
/// each recognized lexical word, before contraction expansion. A missing list
/// means only text agreement can be assessed; no acoustic confidence is invented.
List<WordEvaluation> alignWords(
  String referenceText,
  String recognizedText, {
  List<double>? confidences,
}) => _align(referenceText, recognizedText, confidences).words;

/// Returns a 0–100 practice score, with omissions and extra words penalized.
///
/// With no native [confidences], this is transcript agreement feedback rather
/// than a measurement of phonemes, accent, or pronunciation accuracy.
EvaluationResult evaluateSpeech(
  String referenceText,
  String recognizedText, {
  List<double>? confidences,
  String? recordingPath,
  Duration inferenceDuration = Duration.zero,
}) {
  final alignment = _align(referenceText, recognizedText, confidences);
  final native = confidences != null && alignment.recognizedCount > 0;
  final int score;
  if (alignment.referenceCount == 0) {
    score = 0;
  } else {
    // Confidence/text quality and completeness both contribute. Insertions
    // reduce the result so repeating the target amid unrelated words cannot
    // earn the same score as reading it once accurately.
    final quality = alignment.totalScore / alignment.referenceCount;
    final completeness =
        100 * alignment.matchedCount / alignment.referenceCount;
    final precision =
        alignment.referenceCount /
        (alignment.referenceCount + alignment.insertionCount);
    score = ((quality * 0.85 + completeness * 0.15) * precision).round().clamp(
      0,
      100,
    );
  }

  final String details;
  if (alignment.referenceCount == 0) {
    details = '当前文本没有可评测的英文单词。';
  } else if (alignment.recognizedCount == 0) {
    details = '没有识别到英文语音，请靠近麦克风再读一次。';
  } else if (native) {
    details = '已根据识别器词级置信度、文本匹配和朗读完整度生成练习反馈。';
  } else {
    details =
        '本地识别模型未提供词级置信度；分数与颜色表示文本匹配和朗读完整度，'
        '不代表专业发音准确度。';
  }

  return EvaluationResult(
    score: score,
    details: details,
    words: alignment.words,
    recognizedText: recognizedText,
    recordingPath: recordingPath,
    hasNativeConfidence: native,
    inferenceDuration: inferenceDuration,
  );
}

// Retain textbook punctuation for display, but align the lexical middle only.
final _wordPattern = RegExp(
  r'''[“‘"'(\[]*([a-zA-Z]+(?:['’‘][a-zA-Z]+)*|\d+)[”’"'),.!?:;\]…—–-]*''',
);

const _contractions = <String, List<String>>{
  "i'm": ['i', 'am'],
  "you're": ['you', 'are'],
  "we're": ['we', 'are'],
  "they're": ['they', 'are'],
  "he's": ['he', 'is'],
  "she's": ['she', 'is'],
  "it's": ['it', 'is'],
  "that's": ['that', 'is'],
  "there's": ['there', 'is'],
  "here's": ['here', 'is'],
  "what's": ['what', 'is'],
  "who's": ['who', 'is'],
  "where's": ['where', 'is'],
  "how's": ['how', 'is'],
  "let's": ['let', 'us'],
  "can't": ['can', 'not'],
  'cannot': ['can', 'not'],
  "won't": ['will', 'not'],
  "don't": ['do', 'not'],
  "doesn't": ['does', 'not'],
  "didn't": ['did', 'not'],
  "isn't": ['is', 'not'],
  "aren't": ['are', 'not'],
  "wasn't": ['was', 'not'],
  "weren't": ['were', 'not'],
  "haven't": ['have', 'not'],
  "hasn't": ['has', 'not'],
  "hadn't": ['had', 'not'],
  "shouldn't": ['should', 'not'],
  "wouldn't": ['would', 'not'],
  "couldn't": ['could', 'not'],
  "i've": ['i', 'have'],
  "you've": ['you', 'have'],
  "we've": ['we', 'have'],
  "they've": ['they', 'have'],
  "i'll": ['i', 'will'],
  "you'll": ['you', 'will'],
  "he'll": ['he', 'will'],
  "she'll": ['she', 'will'],
  "we'll": ['we', 'will'],
  "they'll": ['they', 'will'],
  "i'd": ['i', 'would'],
  "you'd": ['you', 'would'],
  "we'd": ['we', 'would'],
  "they'd": ['they', 'would'],
};

const _numbers = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];
const _tens = [
  '',
  '',
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];
const _splitNames = {'lingling', 'mingming', 'dongdong'};

List<String> _expand(String word) {
  final contraction = _contractions[word];
  if (contraction != null) return contraction;
  if (word == 'mr') return const ['mister'];
  if (word == 'mrs') return const ['missus'];
  final number = int.tryParse(word);
  if (number != null && number >= 0 && number <= 100) {
    if (number < 20) return [_numbers[number]];
    if (number == 100) return const ['one', 'hundred'];
    return [_tens[number ~/ 10], if (number % 10 != 0) _numbers[number % 10]];
  }
  return [word];
}

List<_DisplayWord> _tokenize(String text) => [
  for (final match in _wordPattern.allMatches(text))
    _DisplayWord(
      match.group(0)!,
      match.group(1)!.replaceAll(RegExp('[’‘]'), "'").toLowerCase(),
    ),
];

List<_Unit> _units(List<_DisplayWord> words, List<double>? confidences) => [
  for (var index = 0; index < words.length; index++)
    for (final normalized in _expand(words[index].normalized))
      _Unit(
        normalized: normalized,
        sourceIndex: index,
        display: words[index].display,
        confidence: confidences?[index],
      ),
];

// The English ASR can split Chinese character names into two English tokens.
// Merge only known textbook names present in the target, never arbitrary pairs.
List<_Unit> _mergeNames(List<_Unit> units, List<_Unit> reference) {
  final names = reference.map((word) => word.normalized).toSet();
  final merged = <_Unit>[];
  for (var index = 0; index < units.length; index++) {
    final current = units[index];
    if (index + 1 < units.length) {
      final next = units[index + 1];
      final name = '${current.normalized}${next.normalized}';
      if (_splitNames.contains(name) && names.contains(name)) {
        merged.add(
          _Unit(
            normalized: name,
            sourceIndex: current.sourceIndex,
            display: '${current.display} ${next.display}',
            confidence: current.confidence == null || next.confidence == null
                ? null
                : math.min(current.confidence!, next.confidence!),
          ),
        );
        index++;
        continue;
      }
    }
    merged.add(current);
  }
  return merged;
}

_Alignment _align(
  String referenceText,
  String recognizedText,
  List<double>? confidences,
) {
  final displayWords = _tokenize(referenceText);
  final recognizedWords = _tokenize(recognizedText);
  if (confidences != null) {
    if (confidences.length != recognizedWords.length) {
      throw ArgumentError.value(
        confidences,
        'confidences',
        'Expected one native probability per recognized lexical word '
            '(${recognizedWords.length}).',
      );
    }
    if (confidences.any((value) => !value.isFinite || value < 0 || value > 1)) {
      throw ArgumentError.value(
        confidences,
        'confidences',
        'Native probabilities must be finite and in [0, 1].',
      );
    }
  }
  final reference = _units(displayWords, null);
  final recognized = _mergeNames(
    _units(recognizedWords, confidences),
    reference,
  );
  final costs = List.generate(
    reference.length + 1,
    (_) => List<double>.filled(recognized.length + 1, 0),
  );
  final steps = List.generate(
    reference.length + 1,
    (_) => List<_Step?>.filled(recognized.length + 1, null),
  );
  for (var row = 1; row <= reference.length; row++) {
    costs[row][0] = row.toDouble();
    steps[row][0] = _Step.delete;
  }
  for (var col = 1; col <= recognized.length; col++) {
    costs[0][col] = col.toDouble();
    steps[0][col] = _Step.insert;
  }
  for (var row = 1; row <= reference.length; row++) {
    for (var col = 1; col <= recognized.length; col++) {
      final agreement = _agreement(
        reference[row - 1].normalized,
        recognized[col - 1].normalized,
      );
      final substitution = agreement == 1
          ? 0.0
          : agreement > 0
          ? 1 - agreement
          : 1.4;
      var best = costs[row - 1][col - 1] + substitution;
      var step = _Step.pair;
      final deletion = costs[row - 1][col] + 1;
      if (deletion < best) {
        best = deletion;
        step = _Step.delete;
      }
      final insertion = costs[row][col - 1] + 1;
      if (insertion < best) {
        best = insertion;
        step = _Step.insert;
      }
      costs[row][col] = best;
      steps[row][col] = step;
    }
  }

  final aligned = List<_UnitFeedback?>.filled(reference.length, null);
  var row = reference.length;
  var col = recognized.length;
  var insertions = 0;
  while (row > 0 || col > 0) {
    switch (steps[row][col]!) {
      case _Step.pair:
        aligned[row - 1] = _feedback(reference[row - 1], recognized[col - 1]);
        row--;
        col--;
      case _Step.delete:
        aligned[row - 1] = const _UnitFeedback(
          status: ScoreStatus.error,
          score: 0,
          matched: false,
        );
        row--;
      case _Step.insert:
        insertions++;
        col--;
    }
  }

  final grouped = List.generate(displayWords.length, (_) => <_UnitFeedback>[]);
  for (var index = 0; index < reference.length; index++) {
    grouped[reference[index].sourceIndex].add(aligned[index]!);
  }
  final evaluations = <WordEvaluation>[];
  for (var index = 0; index < displayWords.length; index++) {
    final parts = grouped[index];
    final recognizedDisplays = <String>[];
    final recognizedSources = <int>{};
    for (final part in parts) {
      final heard = part.recognized;
      // One recognized contraction may match two normalized target words.
      // Avoid displaying "I'm I'm" when merging the target contraction.
      if (heard != null && recognizedSources.add(heard.sourceIndex)) {
        recognizedDisplays.add(heard.display);
      }
    }
    final nativeConfidences = parts
        .map((part) => part.recognized?.confidence)
        .whereType<double>()
        .toList();
    final fullyMatched = parts.every((part) => part.matched);
    final status = parts.any((part) => part.status == ScoreStatus.error)
        ? ScoreStatus.error
        : parts.any((part) => part.status == ScoreStatus.warning)
        ? ScoreStatus.warning
        : ScoreStatus.correct;
    evaluations.add(
      WordEvaluation(
        word: displayWords[index].display,
        status: status,
        score:
            (parts.fold<double>(0, (total, part) => total + part.score) /
                    parts.length)
                .round()
                .clamp(0, 100),
        recognizedWord: recognizedDisplays.isEmpty
            ? null
            : recognizedDisplays.join(' '),
        confidence: fullyMatched && nativeConfidences.length == parts.length
            ? nativeConfidences.reduce(math.min)
            : null,
      ),
    );
  }
  return _Alignment(
    words: List.unmodifiable(evaluations),
    referenceCount: reference.length,
    recognizedCount: recognized.length,
    insertionCount: insertions,
    matchedCount: aligned.where((part) => part!.matched).length,
    totalScore: aligned.fold<double>(0, (sum, part) => sum + part!.score),
  );
}

double _agreement(String target, String heard) {
  if (target == heard) return 1;
  // Short-word changes usually mean another real word (cat/bat, is/it), so
  // avoid falsely marking them as small pronunciation differences. Likewise,
  // ASR substitutions are text evidence, not proof of a particular phoneme.
  final longest = math.max(target.length, heard.length);
  if (math.min(target.length, heard.length) < 4 || target[0] != heard[0]) {
    return 0;
  }
  final distance = _editDistance(target, heard);
  if (distance > 2 || distance / longest > 0.30) return 0;
  return (1 - distance / longest) * 0.90;
}

int _editDistance(String left, String right) {
  var previous = List.generate(right.length + 1, (index) => index);
  for (var row = 1; row <= left.length; row++) {
    final current = List<int>.filled(right.length + 1, 0);
    current[0] = row;
    for (var col = 1; col <= right.length; col++) {
      current[col] = math.min(
        math.min(previous[col] + 1, current[col - 1] + 1),
        previous[col - 1] + (left[row - 1] == right[col - 1] ? 0 : 1),
      );
    }
    previous = current;
  }
  return previous.last;
}

_UnitFeedback _feedback(_Unit target, _Unit heard) {
  final agreement = _agreement(target.normalized, heard.normalized);
  if (agreement == 0) {
    return _UnitFeedback(
      status: ScoreStatus.error,
      score: 0,
      matched: false,
      recognized: heard,
    );
  }
  final confidence = heard.confidence;
  final ScoreStatus status;
  if (confidence != null && confidence < 0.50) {
    status = ScoreStatus.error;
  } else if (agreement < 1 || (confidence != null && confidence < 0.85)) {
    status = ScoreStatus.warning;
  } else {
    status = ScoreStatus.correct;
  }
  return _UnitFeedback(
    status: status,
    score: 100 * agreement * (confidence ?? 1),
    matched: true,
    recognized: heard,
  );
}

enum _Step { pair, delete, insert }

class _DisplayWord {
  const _DisplayWord(this.display, this.normalized);
  final String display;
  final String normalized;
}

class _Unit {
  const _Unit({
    required this.normalized,
    required this.sourceIndex,
    required this.display,
    this.confidence,
  });
  final String normalized;
  final int sourceIndex;
  final String display;
  final double? confidence;
}

class _UnitFeedback {
  const _UnitFeedback({
    required this.status,
    required this.score,
    required this.matched,
    this.recognized,
  });
  final ScoreStatus status;
  final double score;
  final bool matched;
  final _Unit? recognized;
}

class _Alignment {
  const _Alignment({
    required this.words,
    required this.referenceCount,
    required this.recognizedCount,
    required this.insertionCount,
    required this.matchedCount,
    required this.totalScore,
  });
  final List<WordEvaluation> words;
  final int referenceCount;
  final int recognizedCount;
  final int insertionCount;
  final int matchedCount;
  final double totalScore;
}
