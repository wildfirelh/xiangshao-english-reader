import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/repositories/textbook_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses a page and its normalized sentence rectangle', () {
    final book = Textbook.fromJson({
      'bookId': 'example',
      'title': 'Example',
      'pages': [
        {
          'pageIndex': 1,
          'imagePath': 'assets/example/page_1.png',
          'sentences': [
            {
              'id': 's1',
              'text': 'Hello!',
              'audioPath': 'assets/example/s1.mp3',
              'rect': {'left': 0.1, 'top': 0.2, 'right': 0.8, 'bottom': 0.3},
            },
          ],
        },
      ],
    });

    expect(book.bookId, 'example');
    expect(book.pages.single.sentences.single.translation, isNull);
    expect(book.pages.single.sentences.single.rect.right, 0.8);
    expect(book.pages.single.bubbles, isEmpty);
    expect(book.pages.single.sentences.single.bubbleId, isNull);
    expect(book.pages.single.playbackBubbles.single.sentenceIds, ['s1']);
    expect(
      book.pages.single.playbackBubbles.single.audioPath,
      'assets/example/s1.mp3',
    );
  });

  test(
    'parses complete bubbles while preserving independent sentence clips',
    () {
      final page = TextbookPage.fromJson({
        'pageIndex': 8,
        'imagePath': '',
        'sentences': [
          {
            'id': 's1',
            'bubbleId': 'b1',
            'text': 'Hello!',
            'audioPath': 'assets/s1.mp3',
            'rect': {'left': 0.1, 'top': 0.2, 'right': 0.8, 'bottom': 0.3},
          },
          {
            'id': 's2',
            'bubbleId': 'b1',
            'text': "I'm Lingling.",
            'audioPath': 'assets/s2.mp3',
            'rect': {'left': 0.1, 'top': 0.3, 'right': 0.8, 'bottom': 0.4},
          },
        ],
        'bubbles': [
          {
            'id': 'b1',
            'text': "Hello! I'm Lingling.",
            'translation': '你好！我是玲玲。',
            'audioPath': 'assets/b1.mp3',
            'rect': {'left': 0.1, 'top': 0.2, 'right': 0.8, 'bottom': 0.4},
            'sentenceIds': ['s1', 's2'],
          },
        ],
      });
      expect(page.bubbles.single.sentenceIds, ['s1', 's2']);
      expect(page.bubbles.single.translation, '你好！我是玲玲。');
      expect(page.bubbles.single.rect.bottom, 0.4);
      expect(page.playbackBubbles, same(page.bubbles));
      expect(page.sentences.first.bubbleId, 'b1');
      expect(page.sentences.first.audioPath, 'assets/s1.mp3');
      expect(page.playbackBubbles.single.audioPath, 'assets/b1.mp3');
    },
  );

  test('rejects a rectangle outside the page', () {
    expect(
      () => NormalizedRect.fromJson({
        'left': 0.2,
        'top': 0.2,
        'right': 1.2,
        'bottom': 0.4,
      }),
      throwsFormatException,
    );
  });

  test('loads bundled textbook JSON', () async {
    final book = await TextbookRepository().loadBookFromAsset(
      'assets/textbooks/xiangshao_3_1/book.json',
    );
    expect(book.bookId, 'xiangshao_3_1');
    expect(book.pages, isNotEmpty);
    final ids = <String>{};
    for (final page in book.pages) {
      expect(
        page.imagePath,
        startsWith('assets/textbooks/xiangshao_3_1/images/'),
      );
      for (final sentence in page.sentences) {
        expect(
          ids.add(sentence.id),
          isTrue,
          reason: 'Sentence IDs must be unique',
        );
        expect(sentence.text, isNotEmpty);
        expect(sentence.translation, isNotNull);
        expect(sentence.audioPath, endsWith('.mp3'));
        expect(sentence.rect.right, greaterThan(sentence.rect.left));
        expect(sentence.rect.bottom, greaterThan(sentence.rect.top));
      }
    }
    expect(ids, isNotEmpty);
  });
}
