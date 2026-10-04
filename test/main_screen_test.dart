import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/models/textbook_catalog.dart';
import 'package:english_point_reading/screens/bookshelf_screen.dart';
import 'package:english_point_reading/screens/main_screen.dart';
import 'package:english_point_reading/screens/profile_screen.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/services/learning_controller.dart';
import 'package:english_point_reading/services/learning_preferences_store.dart';
import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:english_point_reading/widgets/floating_capsule_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_update_entry_test.dart' show FakeUpdateService;
import 'audio_player_service_test.dart' show FakeAudioBackend;
import 'bookshelf_screen_test.dart'
    show readyBook, pendingBook, gradeFourBook, textbook;
import 'helpers/memory_reading_progress_store.dart';

Future<LearningController> mountMain(
  WidgetTester tester, {
  Future<List<TextbookCatalogEntry>> Function()? catalogLoader,
  Future<Textbook> Function(TextbookCatalogEntry)? bookLoader,
  LearningController? learning,
  AudioPlayerService Function()? audioFactory,
  FakeUpdateService? updates,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final controller =
      learning ??
      LearningController(
        preferencesStore: InMemoryLearningPreferencesStore(),
        playbackPreferencesStore: InMemoryPlaybackPreferencesStore(),
      );
  if (learning == null) addTearDown(controller.dispose);
  final updateService = updates ?? FakeUpdateService();
  if (updates == null) addTearDown(updateService.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF276B59),
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: MainScreen(
        catalogLoader: catalogLoader ?? () async => [readyBook, pendingBook],
        bookLoader: bookLoader ?? (entry) async => textbook(entry),
        progressStore: MemoryReadingProgressStore(),
        learningController: controller,
        audioPlayerFactory:
            audioFactory ??
            () => AudioPlayerService(backend: FakeAudioBackend()),
        updateService: updateService,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return controller;
}

Future<void> selectTab(WidgetTester tester, int index) async {
  await tester.tap(find.byKey(ValueKey('nav-$index')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'launches the navigation shell without eagerly loading a textbook',
    (tester) async {
      var catalogLoads = 0;
      var bookLoads = 0;
      await mountMain(
        tester,
        catalogLoader: () async {
          catalogLoads++;
          return [readyBook, pendingBook];
        },
        bookLoader: (entry) async {
          bookLoads++;
          return textbook(entry);
        },
      );
      await tester.pumpAndSettle();
      expect(find.byType(BookshelfScreen), findsOneWidget);
      expect(find.text('我的书架'), findsOneWidget);
      expect(find.byType(FloatingCapsuleNavBar), findsOneWidget);
      expect(find.byType(TextbookReaderScreen), findsNothing);
      expect(catalogLoads, 1);
      expect(bookLoads, 0);
      await selectTab(tester, 1);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('累计点读天数'), findsOneWidget);
      expect(find.text('点读书籍数'), findsOneWidget);
      await selectTab(tester, 0);
      expect(catalogLoads, 1);
      expect(bookLoads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retains the selected grade and shelf scroll offset across tabs',
    (tester) async {
      final catalog = [
        readyBook,
        pendingBook,
        for (var index = 0; index < 12; index++)
          TextbookCatalogEntry(
            id: 'four_$index',
            title: '四年级教材 $index',
            grade: 4,
            term: 1,
            cover: '',
            ready: false,
            totalUnits: 5,
          ),
      ];
      await mountMain(tester, catalogLoader: () async => catalog);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('grade-4')));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const Key('books-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.drag(
        find.byKey(const Key('books-scroll')),
        const Offset(0, -280),
      );
      await tester.pumpAndSettle();
      final shelfPosition = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(shelfPosition, greaterThan(100));
      await selectTab(tester, 1);
      expect(find.text('累计点读天数'), findsOneWidget);
      await selectTab(tester, 0);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('grade-4')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const ValueKey('book-xiangshao_3_1')), findsNothing);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        shelfPosition,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retains profile state and performs only one automatic update check',
    (tester) async {
      final updates = FakeUpdateService();
      addTearDown(updates.dispose);
      await mountMain(tester, updates: updates);
      await tester.pumpAndSettle();
      expect(updates.forcedChecks, [false]);
      await selectTab(tester, 1);
      await tester.drag(
        find.byKey(const Key('profile-scroll')),
        const Offset(0, -280),
      );
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const Key('profile-scroll')),
        matching: find.byType(Scrollable),
      );
      final profilePosition = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(profilePosition, greaterThan(0));
      await selectTab(tester, 0);
      await selectTab(tester, 1);
      expect(updates.forcedChecks, [false]);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        profilePosition,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'allows profile navigation while catalog metadata is still loading',
    (tester) async {
      final loading = Completer<List<TextbookCatalogEntry>>();
      await mountMain(tester, catalogLoader: () => loading.future);
      expect(find.text('正在整理你的书架…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pump();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('累计点读天数'), findsOneWidget);
      loading.complete([readyBook]);
      await tester.pumpAndSettle();
      await selectTab(tester, 0);
      expect(find.text('湘少版 三年级上册'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovers from catalog failure through retry without loading a book',
    (tester) async {
      var attempts = 0;
      var bookLoads = 0;
      await mountMain(
        tester,
        catalogLoader: () async {
          if (attempts++ == 0) throw StateError('Metadata unavailable');
          return [gradeFourBook];
        },
        bookLoader: (entry) async {
          bookLoads++;
          return textbook(entry);
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('教材目录暂时无法读取，请重试。'), findsOneWidget);
      await selectTab(tester, 1);
      expect(find.text('累计点读天数'), findsOneWidget);
      await selectTab(tester, 0);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.text(gradeFourBook.title), findsOneWidget);
      expect(find.text('教材目录暂时无法读取，请重试。'), findsNothing);
      expect(attempts, 2);
      expect(bookLoads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an empty catalog remains a usable shell with settings access', (
    tester,
  ) async {
    await mountMain(tester, catalogLoader: () async => []);
    await tester.pumpAndSettle();
    expect(find.text('书架还没有教材'), findsOneWidget);
    await selectTab(tester, 1);
    expect(find.byKey(const Key('profile-eye-reminder')), findsOneWidget);
    expect(find.byKey(const Key('profile-speed')), findsOneWidget);
    await selectTab(tester, 0);
    expect(find.text('书架还没有教材'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'profile speed is applied to the next reader and reader changes return to profile',
    (tester) async {
      final preferences = InMemoryPlaybackPreferencesStore();
      final learning = LearningController(
        preferencesStore: InMemoryLearningPreferencesStore(),
        playbackPreferencesStore: preferences,
      );
      addTearDown(learning.dispose);
      final backend = FakeAudioBackend();
      AudioPlayerService? audio;
      await mountMain(
        tester,
        learning: learning,
        audioFactory: () => audio = AudioPlayerService(
          backend: backend,
          preferencesStore: preferences,
        ),
      );
      await tester.pumpAndSettle();
      await selectTab(tester, 1);
      final speedEntry = find.byKey(const Key('profile-speed'));
      await tester.ensureVisible(speedEntry);
      await tester.pumpAndSettle();
      await tester.tap(speedEntry);
      await tester.pumpAndSettle();
      final selectedSpeed = find.byKey(
        const ValueKey('profile-speed-option-1.5'),
      );
      await tester.ensureVisible(selectedSpeed);
      await tester.pumpAndSettle();
      await tester.tap(selectedSpeed);
      await tester.pumpAndSettle();
      expect(learning.currentSpeed, 1.5);
      expect(await preferences.loadSpeed(), 1.5);
      await selectTab(tester, 0);
      final continueButton = find.byKey(
        ValueKey('book-continue-${readyBook.id}'),
      );
      await tester.ensureVisible(continueButton);
      await tester.pumpAndSettle();
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(find.byType(TextbookReaderScreen), findsOneWidget);
      expect(audio!.currentSpeed, 1.5);
      expect(backend.speed, 1.5);
      await audio!.setSpeed(0.8);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await selectTab(tester, 1);
      expect(learning.currentSpeed, 0.8);
      expect(find.text('0.8x · 用于下次打开的课本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small screens with dark theme and large fonts retain both primary destinations',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mountMain(tester, brightness: Brightness.dark, textScale: 2);
      await tester.pumpAndSettle();
      expect(find.text('我的书架'), findsOneWidget);
      expect(tester.getSize(find.byType(BackdropFilter)).height, 64);
      await selectTab(tester, 1);
      expect(find.text('累计点读天数'), findsOneWidget);
      final speed = find.byKey(const Key('profile-speed'));
      await tester.ensureVisible(speed);
      await tester.pumpAndSettle();
      await tester.tap(speed);
      await tester.pumpAndSettle();
      expect(find.text('点读发音语速'), findsNWidgets(2));
      final option = find.byKey(const ValueKey('profile-speed-option-2.0'));
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      await tester.tap(option);
      await tester.pumpAndSettle();
      await selectTab(tester, 0);
      expect(find.text('我的书架'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
