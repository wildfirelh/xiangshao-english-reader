import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/home_shelf_screen.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend;
import 'helpers/memory_reading_progress_store.dart';

Textbook book({bool partial = false}) => Textbook(
  bookId: 'xiangshao_3_1',
  title: '湘少版英语三年级上册',
  pages: List.generate(
    partial ? 2 : 65,
    (i) => TextbookPage(pageIndex: i + 8, imagePath: '', sentences: const []),
  ),
);

Future<void> openShelf(
  WidgetTester tester,
  MemoryReadingProgressStore progress, {
  bool partial = false,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize / tester.view.devicePixelRatio,
          textScaler: textScaler,
        ),
        child: HomeShelfScreen(
          book: book(partial: partial),
          progressStore: progress,
          coverPath: 'assets/missing-cover.webp',
          audioPlayerFactory: () =>
              AudioPlayerService(backend: FakeAudioBackend()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('continue opens saved page and back refreshes shelf progress', (
    tester,
  ) async {
    final progress = MemoryReadingProgressStore()..pages['xiangshao_3_1'] = 13;
    await openShelf(tester, progress);
    expect(find.text('上次读到第 6 / 65 页'), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-learning')));
    await tester.pumpAndSettle();
    expect(find.byType(TextbookReaderScreen), findsOneWidget);
    expect(find.text('第 6 / 65 页'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TextbookReaderScreen), findsNothing);
    expect(find.text('上次读到第 7 / 65 页'), findsOneWidget);
    expect(progress.pages['xiangshao_3_1'], 14);
  });

  testWidgets(
    'unit selection overrides saved progress and saves its start page',
    (tester) async {
      final progress = MemoryReadingProgressStore()
        ..pages['xiangshao_3_1'] = 63;
      await openShelf(tester, progress);
      final unit = find.byKey(const ValueKey('shelf-unit-4'));
      await tester.ensureVisible(unit);
      await tester.pumpAndSettle();
      await tester.tap(unit);
      await tester.pumpAndSettle();
      expect(find.text('第 21 / 65 页'), findsOneWidget);
      expect(progress.pages['xiangshao_3_1'], 28);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('上次读到第 21 / 65 页'), findsOneWidget);
    },
  );

  testWidgets('missing progress and cover safely fall back to first page', (
    tester,
  ) async {
    final progress = MemoryReadingProgressStore()..pages['xiangshao_3_1'] = 999;
    await openShelf(tester, progress);
    expect(find.text('准备好了，就从第一页开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('continue-learning')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 65 页'), findsOneWidget);
  });

  testWidgets('unavailable units are disabled', (tester) async {
    await openShelf(tester, MemoryReadingProgressStore(), partial: true);
    final unit = tester.widget<InkWell>(
      find.byKey(const ValueKey('shelf-unit-2')),
    );
    expect(unit.onTap, isNull);
  });

  for (final size in [
    const Size(320, 700),
    const Size(375, 812),
    const Size(1024, 768),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'shelf scrolls without overflow at $size and text scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await openShelf(
            tester,
            MemoryReadingProgressStore(),
            textScaler: TextScaler.linear(scale),
          );
          expect(tester.takeException(), isNull);
          final lastUnit = find.byKey(const ValueKey('shelf-unit-10'));
          await tester.ensureVisible(lastUnit);
          await tester.pumpAndSettle();
          expect(lastUnit.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(lastUnit);
          await tester.pumpAndSettle();
          expect(find.text('第 56 / 65 页'), findsOneWidget);
        },
      );
    }
  }
}
