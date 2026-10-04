import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/models/textbook_catalog.dart';
import 'package:english_point_reading/models/textbook_unit.dart';
import 'package:english_point_reading/screens/bookshelf_screen.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend;
import 'helpers/memory_reading_progress_store.dart';

const readyBook = TextbookCatalogEntry(
  id: 'xiangshao_3_1',
  title: '湘少版 三年级上册',
  grade: 3,
  term: 1,
  cover: 'assets/missing-cover.webp',
  ready: true,
  totalUnits: 10,
  firstPageIndex: 8,
  pageCount: 65,
  units: [TextbookUnit(1, 'Hello!', 8), TextbookUnit(2, 'Names', 13)],
);

const pendingBook = TextbookCatalogEntry(
  id: 'xiangshao_3_2',
  title: '湘少版 三年级下册',
  grade: 3,
  term: 2,
  cover: '',
  ready: false,
  totalUnits: 10,
);

const gradeFourBook = TextbookCatalogEntry(
  id: 'sample_4_1',
  title: '示例版 四年级上册',
  grade: 4,
  term: 1,
  cover: '',
  ready: true,
  totalUnits: 3,
  firstPageIndex: 1,
  pageCount: 10,
);

Textbook textbook(TextbookCatalogEntry entry, {List<int>? pages}) => Textbook(
  bookId: entry.id,
  title: entry.title,
  pages: [
    for (final page
        in pages ??
            List.generate(
              entry.pageCount ?? 10,
              (index) => index + (entry.firstPageIndex ?? 1),
            ))
      TextbookPage(pageIndex: page, imagePath: '', sentences: const []),
  ],
);

Future<void> openBookshelf(
  WidgetTester tester, {
  List<TextbookCatalogEntry> catalog = const [readyBook, pendingBook],
  MemoryReadingProgressStore? progress,
  Future<Textbook> Function(TextbookCatalogEntry)? loader,
  AudioPlayerService Function()? audioFactory,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize / tester.view.devicePixelRatio,
          textScaler: textScaler,
        ),
        child: Scaffold(
          body: SafeArea(
            child: BookshelfScreen(
              catalog: catalog,
              bookLoader: loader ?? (entry) async => textbook(entry),
              progressStore: progress ?? MemoryReadingProgressStore(),
              audioPlayerFactory:
                  audioFactory ??
                  () => AudioPlayerService(backend: FakeAudioBackend()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapContinue(WidgetTester tester, String id) async {
  final button = find.byKey(ValueKey('book-continue-$id'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'launch shows catalog without eagerly loading or opening a book',
    (tester) async {
      var loadCount = 0;
      await openBookshelf(
        tester,
        loader: (entry) async {
          loadCount++;
          return textbook(entry);
        },
      );
      expect(find.text('我的书架'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-xiangshao_3_1')), findsOneWidget);
      expect(find.byKey(const ValueKey('book-xiangshao_3_2')), findsOneWidget);
      expect(find.byType(TextbookReaderScreen), findsNothing);
      expect(loadCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending textbook explains availability and never invokes loader',
    (tester) async {
      var loadCount = 0;
      await openBookshelf(
        tester,
        loader: (entry) async {
          loadCount++;
          return textbook(entry);
        },
      );
      await tapContinue(tester, pendingBook.id);
      expect(find.text('该教材正在整理中，敬请期待'), findsOneWidget);
      expect(find.byType(TextbookReaderScreen), findsNothing);
      expect(loadCount, 0);
    },
  );

  testWidgets(
    'grade filter uses actual catalog grades and retains per-book data',
    (tester) async {
      final progress = MemoryReadingProgressStore()
        ..pages[readyBook.id] = 13
        ..pages[gradeFourBook.id] = 5;
      await openBookshelf(
        tester,
        catalog: const [readyBook, pendingBook, gradeFourBook],
        progress: progress,
      );
      expect(find.byKey(const ValueKey('grade-2')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('grade-4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-xiangshao_3_1')), findsNothing);
      expect(find.byKey(const ValueKey('book-sample_4_1')), findsOneWidget);
      expect(find.text('阅读进度 50%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('grade-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-sample_4_1')), findsNothing);
      expect(find.text('阅读进度 9%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('grade-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-sample_4_1')), findsOneWidget);
    },
  );

  testWidgets(
    'continue restores the correct book and return refreshes progress',
    (tester) async {
      final progress = MemoryReadingProgressStore()
        ..pages[readyBook.id] = 13
        ..pages[gradeFourBook.id] = 2;
      await openBookshelf(tester, progress: progress);
      expect(find.text('阅读进度 9%'), findsOneWidget);
      expect(find.text('第 6 / 65 页'), findsOneWidget);
      await tapContinue(tester, readyBook.id);
      final reader = tester.widget<TextbookReaderScreen>(
        find.byType(TextbookReaderScreen),
      );
      expect(reader.book.bookId, readyBook.id);
      expect(reader.units, readyBook.units);
      expect(find.text('第 6 / 65 页'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('阅读进度 11%'), findsOneWidget);
      expect(find.text('第 7 / 65 页'), findsOneWidget);
      expect(progress.pages[readyBook.id], 14);
      expect(progress.pages[gradeFourBook.id], 2);
    },
  );

  testWidgets('invalid saved page starts safely from the first page', (
    tester,
  ) async {
    final progress = MemoryReadingProgressStore()..pages[readyBook.id] = 999;
    await openBookshelf(tester, progress: progress);
    expect(find.text('阅读进度 0%'), findsOneWidget);
    await tapContinue(tester, readyBook.id);
    expect(find.text('第 1 / 65 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'after loading, progress follows actual noncontiguous page indices',
    (tester) async {
      final progress = MemoryReadingProgressStore()..pages[readyBook.id] = 20;
      await openBookshelf(
        tester,
        progress: progress,
        loader: (entry) async => textbook(entry, pages: [8, 20, 30]),
      );
      await tapContinue(tester, readyBook.id);
      expect(find.text('第 2 / 3 页'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('阅读进度 67%'), findsOneWidget);
      expect(find.text('第 2 / 3 页'), findsOneWidget);
    },
  );

  testWidgets('rapid repeated taps produce only one lazy load and reader', (
    tester,
  ) async {
    final loaded = Completer<Textbook>();
    var loadCount = 0;
    await openBookshelf(
      tester,
      loader: (_) {
        loadCount++;
        return loaded.future;
      },
    );
    final button = find.byKey(const ValueKey('book-continue-xiangshao_3_1'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(loadCount, 1);
    loaded.complete(textbook(readyBook));
    await tester.pumpAndSettle();
    expect(find.byType(TextbookReaderScreen), findsOneWidget);
    expect(loadCount, 1);
  });

  testWidgets(
    'failed textbook load supports retry without opening a broken route',
    (tester) async {
      var loadCount = 0;
      await openBookshelf(
        tester,
        loader: (entry) async {
          loadCount++;
          if (loadCount == 1) throw const FormatException('broken textbook');
          return textbook(entry);
        },
      );
      await tapContinue(tester, readyBook.id);
      expect(find.text('教材暂时无法打开，请重试'), findsOneWidget);
      expect(find.byType(TextbookReaderScreen), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(loadCount, 2);
      expect(find.byType(TextbookReaderScreen), findsOneWidget);
    },
  );

  testWidgets(
    'unmount during a delayed load never opens reader or creates audio',
    (tester) async {
      final loaded = Completer<Textbook>();
      var audioCount = 0;
      await openBookshelf(
        tester,
        loader: (_) => loaded.future,
        audioFactory: () {
          audioCount++;
          return AudioPlayerService(backend: FakeAudioBackend());
        },
      );
      final button = find.byKey(const ValueKey('book-continue-xiangshao_3_1'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpWidget(const SizedBox());
      loaded.complete(textbook(readyBook));
      await tester.pumpAndSettle();
      expect(audioCount, 0);
      expect(find.byType(TextbookReaderScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 600),
    const Size(390, 844),
    const Size(1024, 768),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cards remain scrollable at $size with text scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await openBookshelf(tester, textScaler: TextScaler.linear(scale));
        expect(tester.takeException(), isNull);
        await tapContinue(tester, pendingBook.id);
        expect(find.text('该教材正在整理中，敬请期待'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
