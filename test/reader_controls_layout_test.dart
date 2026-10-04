import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openBar(
    WidgetTester tester, {
    double initialSpeed = 1.0,
    required ValueChanged<double> onChange,
    double textScale = 1.0,
    bool reduceMotion = false,
    DialogueBubble? activeBubble,
  }) async {
    var speed = initialSpeed;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: Scaffold(
          bottomNavigationBar: StatefulBuilder(
            builder: (context, setState) => TextbookBottomBar(
              currentMode: PlayMode.single,
              onModeChanged: (_) {},
              isTranslationEnabled: true,
              onTranslationChanged: (_) {},
              activeSentence: null,
              activeBubble: activeBubble,
              currentSpeed: speed,
              onSpeedChanged: (value) {
                onChange(value);
                setState(() => speed = value);
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'speed tap cycles through six supported values and returns to standard',
    (tester) async {
      final changes = <double>[];
      await openBar(tester, onChange: changes.add);
      expect(find.text('1.0x'), findsOneWidget);
      for (final speed in [1.2, 1.5, 2.0, 0.5, 0.8, 1.0]) {
        await tester.tap(find.byKey(const Key('playback-speed')));
        await tester.pumpAndSettle();
        expect(find.text('${speed.toStringAsFixed(1)}x'), findsOneWidget);
      }
      expect(changes, [1.2, 1.5, 2.0, 0.5, 0.8, 1.0]);
    },
  );

  testWidgets(
    'long press selects speed once and shows the current selected option',
    (tester) async {
      final changes = <double>[];
      final semantics = tester.ensureSemantics();
      try {
        await openBar(tester, initialSpeed: 1.5, onChange: changes.add);
        await tester.longPress(find.byKey(const Key('playback-speed')));
        await tester.pumpAndSettle();
        expect(find.text('选择播放语速'), findsOneWidget);
        for (final speed in [0.5, 0.8, 1.0, 1.2, 1.5, 2.0]) {
          final option = find.byKey(
            ValueKey('speed-option-${speed.toStringAsFixed(1)}x'),
          );
          expect(option, findsOneWidget);
          expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
          expect(tester.widget<ListTile>(option).selected, speed == 1.5);
        }
        expect(find.bySemanticsLabel(RegExp('播放语速 1.5x，当前选中')), findsOneWidget);
        final slow = find.byKey(const ValueKey('speed-option-0.8x'));
        await tester.tap(slow);
        // A second event before the dismiss animation finishes must not pop twice.
        await tester.tap(slow, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(changes, [0.8]);
        expect(find.text('0.8x'), findsOneWidget);
        expect(find.text('选择播放语速'), findsNothing);
        expect(find.byType(TextbookBottomBar), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'choosing current speed or closing picker does not change playback',
    (tester) async {
      final changes = <double>[];
      await openBar(
        tester,
        initialSpeed: 0.8,
        onChange: changes.add,
        reduceMotion: true,
      );
      await tester.longPress(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.text('选择播放语速')))!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(find.byKey(const ValueKey('speed-option-0.8x')));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      await tester.longPress(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭语速选择'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('0.8x'), findsOneWidget);
      await tester.longPress(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('选择播放语速'), findsNothing);
      expect(changes, isEmpty);
    },
  );

  testWidgets(
    'small screen large text and long translation keep speed picker scrollable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <double>[];
      await openBar(
        tester,
        onChange: changes.add,
        textScale: 2.5,
        activeBubble: const DialogueBubble(
          id: 'long',
          text: 'Hello, my name is Lingling. Nice to meet you. Welcome to our English lesson and let us read together.',
          translation: '你好，我叫玲玲。很高兴认识你。欢迎来到英语课堂，让我们一起读完整段话并练习清楚地发音。',
          audioPath: '',
          sentenceIds: [],
          rect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 1),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.longPress(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final fastest = find.byKey(const ValueKey('speed-option-2.0x'));
      await tester.scrollUntilVisible(fastest, 200);
      expect(tester.getSize(fastest).height, greaterThanOrEqualTo(48));
      await tester.tap(fastest);
      await tester.pumpAndSettle();
      expect(changes, [2.0]);
      expect(find.text('2.0x'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(320, 700),
  ]) {
    for (final brightness in Brightness.values) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets('controls fit $size $brightness text scale $textScale', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var speed = 1.0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: Scaffold(
                  bottomNavigationBar: StatefulBuilder(
                    builder: (context, setState) => TextbookBottomBar(
                      currentMode: PlayMode.single,
                      onModeChanged: (_) {},
                      currentSpeed: speed,
                      onSpeedChanged: (value) => setState(() => speed = value),
                      isTranslationEnabled: true,
                      onTranslationChanged: (_) {},
                      activeSentence: null,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          final button = find.byKey(const Key('playback-speed'));
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.text('1.2x'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.text('1.5x'), findsOneWidget);
          expect(speed, 1.5);
        });
      }
    }
  }
}
