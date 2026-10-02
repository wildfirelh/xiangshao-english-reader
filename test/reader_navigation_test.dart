import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/models/textbook_unit.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/services/reading_progress_store.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'helpers/memory_reading_progress_store.dart';

class _Audio extends Fake implements AudioPlaybackBackend {
  int stops = 0;
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

class _DelayedProgress extends MemoryReadingProgressStore {
  final completer = Completer<int?>();
  @override
  Future<int?> load(String bookId) => completer.future;
}

Textbook _book({List<int>? pageNumbers}) => Textbook(
  bookId: 'xiangshao_3_1',
  title: 'Test book',
  pages: (pageNumbers ?? List.generate(65, (i) => i + 8))
      .map(
        (i) => TextbookPage(pageIndex: i, imagePath: '', sentences: const []),
      )
      .toList(),
);

Future<void> _open(
  WidgetTester tester,
  ReadingProgressStore progress, {
  Textbook? book,
  _Audio? backend,
}) async {
  final audio = AudioPlayerService(backend: backend ?? _Audio());
  addTearDown(audio.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: TextbookReaderScreen(
        book: book ?? _book(),
        progressStore: progress,
        audioPlayerService: audio,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('last unit is reachable by scrolling the directory', (
    tester,
  ) async {
    final progress = MemoryReadingProgressStore();
    await _open(tester, progress);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('unit-10'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('第 56 / 65 页'), findsOneWidget);
    expect(progress.pages['xiangshao_3_1'], 63);
  });

  test(
    'directory uses verified PDF pages including gaps for review sections',
    () {
      expect(TextbookUnit.xiangshaoGradeThree.map((u) => u.startPage), [
        8,
        13,
        18,
        28,
        33,
        38,
        48,
        53,
        58,
        63,
      ]);
    },
  );

  testWidgets(
    'directory jumps across review pages, stops audio and saves progress',
    (tester) async {
      final progress = MemoryReadingProgressStore();
      final backend = _Audio();
      await _open(tester, progress, backend: backend);
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.text('单元目录'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('unit-4')));
      await tester.pumpAndSettle();
      expect(find.text('第 21 / 65 页'), findsOneWidget);
      expect(progress.pages['xiangshao_3_1'], 28);
      expect(backend.stops, greaterThan(0));
      final visible = tester.widget<InteractiveTextbookPage>(
        find.byType(InteractiveTextbookPage).first,
      );
      expect(visible.page.pageIndex, 28);
    },
  );

  testWidgets(
    'swiping persists and reopening restores the same physical page',
    (tester) async {
      final progress = MemoryReadingProgressStore()
        ..pages['xiangshao_3_1'] = 13;
      await _open(tester, progress);
      expect(find.text('第 6 / 65 页'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(progress.pages['xiangshao_3_1'], 14);
      await tester.pumpWidget(const SizedBox());
      await _open(tester, progress);
      expect(find.text('第 7 / 65 页'), findsOneWidget);
    },
  );

  testWidgets(
    'unavailable saved page falls back and missing units are disabled',
    (tester) async {
      final progress = MemoryReadingProgressStore()
        ..pages['xiangshao_3_1'] = 999;
      await _open(tester, progress, book: _book(pageNumbers: [8, 9]));
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('unit-2'))).enabled,
        isFalse,
      );
    },
  );

  testWidgets('late restore after disposal is ignored', (tester) async {
    final progress = _DelayedProgress();
    final audio = AudioPlayerService(backend: _Audio());
    addTearDown(audio.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: TextbookReaderScreen(
          book: _book(),
          progressStore: progress,
          audioPlayerService: audio,
        ),
      ),
    );
    expect(find.byType(PageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
    progress.completer.complete(13);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
