import 'package:english_point_reading/models/speech_evaluation.dart';
import 'package:english_point_reading/services/speech_alignment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('offline speech word alignment', () {
    test('keeps textbook punctuation and ignores casing for exact matches', () {
      final result = evaluateSpeech('Hello, Peter!', 'HELLO peter');

      expect(result.score, 100);
      expect(result.words.map((word) => word.word), ['Hello,', 'Peter!']);
      expect(
        result.words.map((word) => word.status),
        everyElement(ScoreStatus.correct),
      );
      expect(result.words.map((word) => word.confidence), everyElement(isNull));
      expect(result.hasNativeConfidence, isFalse);
      expect(result.details, contains('文本匹配'));
      expect(result.details, contains('不代表专业发音准确度'));
    });

    test('smart apostrophes align with expanded ASR contractions', () {
      final result = evaluateSpeech('“I’m Lingling.”', 'I am Lingling');

      expect(result.score, 100);
      expect(result.words.map((word) => word.word), ['“I’m', 'Lingling.”']);
      expect(result.words.first.recognizedWord, 'I am');
      expect(result.words.first.status, ScoreStatus.correct);
    });

    test('expanded reference matches recognized contractions', () {
      final result = evaluateSpeech('What is your name?', "What's your name");

      expect(result.score, 100);
      expect(result.words, hasLength(4));
      expect(result.words[0].status, ScoreStatus.correct);
      expect(result.words[1].status, ScoreStatus.correct);
    });

    test('contraction display is not duplicated', () {
      final word = alignWords("I'm", "I'm").single;
      expect(word.recognizedWord, "I'm");
      expect(word.word, "I'm");
      expect(word.score, 100);
    });

    test('negated contractions preserve meaning', () {
      expect(evaluateSpeech("It isn't mine.", 'It is not mine').score, 100);
      expect(evaluateSpeech('I cannot swim.', "I can't swim").score, 100);
      expect(
        evaluateSpeech("It isn't mine.", 'It is mine').score,
        lessThan(100),
      );
    });

    test('an omitted part of a contraction stays visible as an error', () {
      final result = evaluateSpeech("I'm Peter.", 'I Peter');

      expect(result.words.first.status, ScoreStatus.error);
      expect(result.words.first.score, 50);
      expect(result.words.last.status, ScoreStatus.correct);
      expect(result.score, 67);
    });

    test('ASR split textbook names merge without changing source spelling', () {
      for (final name in ['Lingling', 'Mingming', 'Dongdong']) {
        final half = name.substring(0, name.length ~/ 2);
        final result = evaluateSpeech('Hello, $name!', 'hello $half $half');

        expect(result.score, 100, reason: name);
        expect(result.words.last.word, '$name!');
        expect(result.words.last.status, ScoreStatus.correct);
        expect(result.words.last.recognizedWord, '$half $half');
      }
    });

    test('does not merge unrelated repeated words', () {
      final result = evaluateSpeech('Hello, Peter.', 'hello hello peter');

      expect(
        result.words.map((word) => word.status),
        everyElement(ScoreStatus.correct),
      );
      expect(result.score, lessThan(100));
    });

    test('common spoken numeric text agrees with written ages', () {
      final result = evaluateSpeech("I'm 8.", 'I am eight');
      expect(result.score, 100);
      expect(result.words.last.word, '8.');
      expect(result.words.last.recognizedWord, 'eight');
    });

    test('teacher abbreviations match expanded recognized titles', () {
      expect(
        evaluateSpeech('Hello, Mr. Yang!', 'hello mister yang').score,
        100,
      );
    });

    test('missing middle word does not shift subsequent matches', () {
      final result = evaluateSpeech('My name is Peter.', 'my is peter');

      expect(result.words.map((word) => word.status), [
        ScoreStatus.correct,
        ScoreStatus.error,
        ScoreStatus.correct,
        ScoreStatus.correct,
      ]);
      expect(result.words[1].recognizedWord, isNull);
      expect(result.words[1].score, 0);
      expect(result.score, 75);
    });

    test('missing initial word remains aligned to the other words', () {
      final words = alignWords('Hello, Peter.', 'peter');

      expect(words.first.status, ScoreStatus.error);
      expect(words.last.status, ScoreStatus.correct);
    });

    test('a real substitution is red even with high native confidence', () {
      final result = evaluateSpeech(
        'My name is Peter.',
        'my name is dino',
        confidences: [1, 1, 1, 0.99],
      );

      expect(result.words.last.recognizedWord, 'dino');
      expect(result.words.last.status, ScoreStatus.error);
      expect(result.words.last.score, 0);
      expect(result.score, 75);
    });

    test('conservative fuzzy spelling provides yellow text feedback', () {
      final result = evaluateSpeech('Good morning.', 'good mornin');

      expect(result.words.last.status, ScoreStatus.warning);
      expect(result.words.last.score, inInclusiveRange(50, 84));
      expect(result.words.last.confidence, isNull);
      expect(result.score, inInclusiveRange(70, 99));
    });

    test(
      'short English substitutions are errors instead of fuzzy successes',
      () {
        for (final pair in [
          ['cat', 'bat'],
          ['is', 'it'],
          ['boy', 'toy'],
          ['fine', 'nine'],
        ]) {
          final word = alignWords(pair[0], pair[1]).single;
          expect(word.status, ScoreStatus.error, reason: '$pair');
          expect(word.score, 0);
        }
      },
    );

    test(
      'extra words reduce the score without marking target words missing',
      () {
        final result = evaluateSpeech('Hello Peter.', 'well hello Peter today');

        expect(
          result.words.map((word) => word.status),
          everyElement(ScoreStatus.correct),
        );
        expect(result.score, 50);
      },
    );

    test('repeating a correct word is not a perfect reading', () {
      expect(evaluateSpeech('Hello!', 'hello hello hello').score, 33);
    });

    test('completely different speech gives zero', () {
      final result = evaluateSpeech('Hello, Peter!', 'purple dinosaur');
      expect(result.score, 0);
      expect(
        result.words.map((word) => word.status),
        everyElement(ScoreStatus.error),
      );
    });

    test(
      'silence yields omissions, no recording success or native confidence',
      () {
        final result = evaluateSpeech(
          'Good morning.',
          '',
          confidences: const [],
        );

        expect(result.score, 0);
        expect(result.words, hasLength(2));
        expect(
          result.words.map((word) => word.status),
          everyElement(ScoreStatus.error),
        );
        expect(
          result.words.map((word) => word.confidence),
          everyElement(isNull),
        );
        expect(result.hasNativeConfidence, isFalse);
        expect(result.details, contains('没有识别到'));
      },
    );

    test('empty or punctuation-only targets can never receive 100', () {
      for (final reference in ['', '   ', '!?...', '中文']) {
        final result = evaluateSpeech(reference, 'hello');
        expect(result.score, 0, reason: reference);
        expect(result.words, isEmpty);
        expect(result.details, contains('没有可评测'));
      }
      expect(evaluateSpeech('', '').score, 0);
    });

    test(
      'non-English transcript cannot masquerade as recognized target speech',
      () {
        final result = evaluateSpeech('Hello, Peter.', '你好，彼得！');
        expect(result.score, 0);
        expect(
          result.words.map((word) => word.status),
          everyElement(ScoreStatus.error),
        );
      },
    );

    test('retains recording and measured inference timing metadata', () {
      const duration = Duration(milliseconds: 42);
      final result = evaluateSpeech(
        'Hello',
        'hello',
        recordingPath: '/private/practice.wav',
        inferenceDuration: duration,
      );

      expect(result.recordingPath, '/private/practice.wav');
      expect(result.inferenceDuration, duration);
      expect(result.recognizedText, 'hello');
    });

    test('feedback list cannot be mutated by a consumer', () {
      final words = alignWords('Hello', 'hello');
      expect(() => words.clear(), throwsUnsupportedError);
    });
  });

  group('actual native word confidence', () {
    test('uses exact 0.85 and 0.50 threshold boundaries', () {
      final result = evaluateSpeech(
        'Hello Peter Good morning.',
        'hello peter good morning',
        confidences: [0.85, 0.849, 0.50, 0.499],
      );

      expect(result.words.map((word) => word.status), [
        ScoreStatus.correct,
        ScoreStatus.warning,
        ScoreStatus.warning,
        ScoreStatus.error,
      ]);
      expect(result.words.map((word) => word.confidence), [
        0.85,
        0.849,
        0.50,
        0.499,
      ]);
      expect(result.hasNativeConfidence, isTrue);
      expect(result.details, contains('词级置信度'));
    });

    test(
      'confidence follows recognized words across omissions and insertions',
      () {
        final result = evaluateSpeech(
          'My name is Peter.',
          'well my is peter',
          confidences: [0.95, 0.9, 0.6, 0.4],
        );

        expect(result.words.map((word) => word.confidence), [
          0.9,
          null,
          0.6,
          0.4,
        ]);
        expect(result.words.map((word) => word.status), [
          ScoreStatus.correct,
          ScoreStatus.error,
          ScoreStatus.warning,
          ScoreStatus.error,
        ]);
      },
    );

    test(
      'expansion inherits supplied confidence, never generates another value',
      () {
        final words = alignWords(
          'I am Peter.',
          "I'm Peter",
          confidences: [0.65, 0.99],
        );

        expect(words.map((word) => word.confidence), [0.65, 0.65, 0.99]);
        expect(words.map((word) => word.status), [
          ScoreStatus.warning,
          ScoreStatus.warning,
          ScoreStatus.correct,
        ]);
      },
    );

    test('split names use the lower native probability', () {
      final word = alignWords(
        'Lingling',
        'ling ling',
        confidences: [0.95, 0.6],
      ).single;

      expect(word.confidence, 0.6);
      expect(word.status, ScoreStatus.warning);
    });

    test(
      'partially missed contraction has no whole-word native probability',
      () {
        final word = alignWords("I'm", 'I', confidences: [0.98]).single;

        expect(word.status, ScoreStatus.error);
        expect(word.confidence, isNull);
        expect(word.score, 49);
      },
    );

    test(
      'high native confidence does not turn fuzzy text into exact agreement',
      () {
        final word = alignWords(
          'morning',
          'mornin',
          confidences: [0.99],
        ).single;

        expect(word.status, ScoreStatus.warning);
        expect(word.confidence, 0.99);
        expect(word.score, lessThan(85));
      },
    );

    test(
      'rejects confidence lists that cannot be mapped to recognized words',
      () {
        expect(
          () => alignWords('Hello Peter', 'hello peter', confidences: [0.9]),
          throwsArgumentError,
        );
        expect(
          () => evaluateSpeech('Hello', '', confidences: [0.9]),
          throwsArgumentError,
        );
      },
    );

    test('rejects invalid native probability values', () {
      for (final value in [-0.01, 1.01, double.nan, double.infinity]) {
        expect(
          () => alignWords('Hello', 'hello', confidences: [value]),
          throwsArgumentError,
          reason: '$value',
        );
      }
    });

    test('low confidence cannot score a perfect attempt', () {
      final result = evaluateSpeech(
        'Hello Peter',
        'hello peter',
        confidences: [0.2, 0.3],
      );

      expect(
        result.words.map((word) => word.status),
        everyElement(ScoreStatus.error),
      );
      expect(result.score, lessThan(50));
    });

    test('all confidence and mismatch scores stay within 0–100', () {
      for (final transcript in [
        '',
        'hello',
        'hello Peter',
        'hello Peter extra extra',
        'world Dino',
      ]) {
        final result = evaluateSpeech('Hello Peter.', transcript);
        expect(result.score, inInclusiveRange(0, 100));
        expect(
          result.words.map((word) => word.score),
          everyElement(inInclusiveRange(0, 100)),
        );
      }
    });
  });

  test('legacy const EvaluationResult constructor remains compatible', () {
    const result = EvaluationResult(score: 0, details: 'not initialized');
    expect(result.words, isEmpty);
    expect(result.recognizedText, '');
    expect(result.recordingPath, isNull);
    expect(result.hasNativeConfidence, isFalse);
    expect(result.inferenceDuration, Duration.zero);
  });
}
