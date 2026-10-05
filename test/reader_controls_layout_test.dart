import 'dart:ui' show Tristate;

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _modeLabels = {
  PlayMode.single: '单句点读',
  PlayMode.fullPage: '整页连读',
  PlayMode.sequential: '顺序连读',
};

const _modeDescriptions = {
  PlayMode.single: '点击任意句子独立朗读，适合精读练习',
  PlayMode.fullPage: '从当前页第一句开始，完整朗读至末尾',
  PlayMode.sequential: '点击任意句子作为起点，顺次连续向后朗读',
};

final _speedDescriptions = {
  0.5: '慢速跟读',
  0.8: '清晰磨耳朵',
  1.0: '标准语速',
  1.2: '稍快复习',
  1.5: '快速听力',
  2.0: '极速浏览',
};

void _useViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openBar(
  WidgetTester tester, {
  double initialSpeed = 1.0,
  ValueChanged<double>? onSpeedChange,
  PlayMode initialMode = PlayMode.single,
  ValueChanged<PlayMode>? onModeChange,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  EdgeInsets safePadding = EdgeInsets.zero,
  DialogueBubble? activeBubble,
  bool isPlaying = false,
  bool canResume = false,
  bool isLoading = false,
  VoidCallback? onPlaybackToggle,
}) async {
  var speed = initialSpeed;
  var mode = initialMode;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF356A58),
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
          padding: safePadding,
        ),
        child: child!,
      ),
      home: Scaffold(
        bottomNavigationBar: StatefulBuilder(
          builder: (context, setState) => TextbookBottomBar(
            currentMode: mode,
            onModeChanged: (value) {
              onModeChange?.call(value);
              setState(() => mode = value);
            },
            isTranslationEnabled: true,
            onTranslationChanged: (_) {},
            activeSentence: null,
            activeBubble: activeBubble,
            currentSpeed: speed,
            onSpeedChanged: (value) {
              onSpeedChange?.call(value);
              setState(() => speed = value);
            },
            isPlaying: isPlaying,
            canResume: canResume,
            isLoading: isLoading,
            onPlaybackToggle: onPlaybackToggle,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('speed tap opens six choices and applies one selection', (
    tester,
  ) async {
    final changes = <double>[];
    final semantics = tester.ensureSemantics();
    try {
      await _openBar(tester, initialSpeed: 1.5, onSpeedChange: changes.add);
      await tester.tap(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('选择播放语速'), findsOneWidget);
      for (final entry in _speedDescriptions.entries) {
        final option = find.byKey(
          ValueKey('speed-option-${entry.key.toStringAsFixed(1)}x'),
        );
        expect(option, findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
        expect(tester.widget<ListTile>(option).selected, entry.key == 1.5);
      }
      expect(find.byIcon(Icons.check), findsOneWidget);
      final selected = tester.getSemantics(
        find.bySemanticsLabel(RegExp('播放语速 1.5x，当前选中')),
      );
      expect(selected.flagsCollection.isButton, isTrue);
      expect(selected.flagsCollection.isSelected, Tristate.isTrue);
      final slow = find.byKey(const ValueKey('speed-option-0.8x'));
      await tester.tap(slow);
      // An extra event during dismissal must not pop the reader or apply twice.
      await tester.tap(slow, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(changes, [0.8]);
      expect(find.text('0.8x'), findsOneWidget);
      expect(find.text('选择播放语速'), findsNothing);
      expect(find.byType(TextbookBottomBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('current speed and all dismissal paths leave speed unchanged', (
    tester,
  ) async {
    final changes = <double>[];
    await _openBar(
      tester,
      initialSpeed: 0.8,
      onSpeedChange: changes.add,
      reduceMotion: true,
    );
    // Long press remains a shortcut to the same selection sheet.
    await tester.longPress(find.byKey(const Key('playback-speed')));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('选择播放语速')))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    await tester.tap(find.byKey(const ValueKey('speed-option-0.8x')));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const Key('playback-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭语速选择'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const Key('playback-speed')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择播放语速'), findsNothing);
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const Key('playback-speed')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('选择播放语速'), findsNothing);
    expect(changes, isEmpty);
    expect(find.text('0.8x'), findsOneWidget);
  });

  testWidgets(
    'mode tap shows three explained choices and checks only current',
    (tester) async {
      final changes = <PlayMode>[];
      final semantics = tester.ensureSemantics();
      try {
        await _openBar(tester, onModeChange: changes.add);
        for (final next in [
          PlayMode.fullPage,
          PlayMode.sequential,
          PlayMode.single,
        ]) {
          final current = tester
              .widget<TextbookBottomBar>(find.byType(TextbookBottomBar))
              .currentMode;
          await tester.tap(find.byKey(const Key('playback-mode')));
          await tester.pumpAndSettle();
          expect(find.text('选择点读模式'), findsOneWidget);
          for (final mode in PlayMode.values) {
            final option = find.byKey(ValueKey('mode-option-${mode.name}'));
            expect(find.text(_modeDescriptions[mode]!), findsOneWidget);
            expect(tester.widget<ListTile>(option).selected, mode == current);
            expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
          }
          expect(find.byIcon(Icons.check), findsOneWidget);
          final selected = tester.getSemantics(
            find.bySemanticsLabel(RegExp('点读模式 ${_modeLabels[current]}，当前选中')),
          );
          expect(selected.flagsCollection.isSelected, Tristate.isTrue);
          final option = find.byKey(ValueKey('mode-option-${next.name}'));
          await tester.tap(option);
          await tester.tap(option, warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(find.text('选择点读模式'), findsNothing);
          expect(find.text(_modeLabels[next]!), findsOneWidget);
        }
        expect(changes, [
          PlayMode.fullPage,
          PlayMode.sequential,
          PlayMode.single,
        ]);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('current mode and closing mode sheet do not change mode', (
    tester,
  ) async {
    final changes = <PlayMode>[];
    await _openBar(
      tester,
      initialMode: PlayMode.sequential,
      onModeChange: changes.add,
      reduceMotion: true,
    );
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('选择点读模式')))!;
    expect(route.transitionDuration, Duration.zero);
    await tester.tap(find.byKey(const ValueKey('mode-option-sequential')));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭模式选择'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择点读模式'), findsNothing);
    expect(find.text('顺序连读'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets(
    'continuous playback exposes enabled play pause and loading stop',
    (tester) async {
      var toggles = 0;
      final semantics = tester.ensureSemantics();
      try {
        final button = find.byKey(const Key('playback-toggle'));
        await _openBar(tester, onPlaybackToggle: () => toggles++);
        expect(button, findsNothing);
        await _openBar(
          tester,
          initialMode: PlayMode.sequential,
          onPlaybackToggle: () => toggles++,
        );
        expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(find.bySemanticsLabel(RegExp('播放连读')), findsOneWidget);
        expect(tester.getSemantics(button).hint, contains('点击任意句子开始顺序连读'));
        await tester.tap(button);
        expect(toggles, 0);
        for (final mode in [PlayMode.fullPage, PlayMode.sequential]) {
          await _openBar(
            tester,
            initialMode: mode,
            canResume: true,
            onPlaybackToggle: () => toggles++,
          );
          expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          await tester.tap(button);
          await _openBar(
            tester,
            initialMode: mode,
            isPlaying: true,
            onPlaybackToggle: () => toggles++,
          );
          expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
          expect(find.byTooltip('暂停连读'), findsOneWidget);
          await tester.tap(button);
          await _openBar(
            tester,
            initialMode: mode,
            isLoading: true,
            onPlaybackToggle: () => toggles++,
          );
          expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
          expect(tester.widget<IconButton>(button).onPressed, isNotNull);
          await tester.tap(button);
        }
        expect(toggles, 6);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('large text translation and capped sheet stay scrollable', (
    tester,
  ) async {
    _useViewport(tester, const Size(320, 480));
    final changes = <double>[];
    await _openBar(
      tester,
      initialMode: PlayMode.sequential,
      onSpeedChange: changes.add,
      textScale: 2.5,
      safePadding: const EdgeInsets.only(top: 24, bottom: 24),
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
    await tester.tap(find.byKey(const Key('playback-speed')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byType(BottomSheet),
                  matching: find.byType(Material),
                )
                .first,
          )
          .height,
      lessThanOrEqualTo(480 * 0.85),
    );
    final fastest = find.byKey(const ValueKey('speed-option-2.0x'));
    await tester.scrollUntilVisible(fastest, 200);
    await tester.tap(fastest);
    await tester.pumpAndSettle();
    expect(changes, [2.0]);
    expect(find.text('2.0x'), findsOneWidget);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mode-option-sequential')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('mode-option-sequential')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(320, 480),
  ]) {
    for (final brightness in Brightness.values) {
      for (final textScale in [1.0, 2.5]) {
        testWidgets(
          'all controls and choices fit $size $brightness $textScale',
          (tester) async {
            _useViewport(tester, size);
            for (final mode in PlayMode.values) {
              await _openBar(
                tester,
                initialMode: mode,
                brightness: brightness,
                textScale: textScale,
                canResume: true,
                onPlaybackToggle: () {},
              );
              expect(tester.takeException(), isNull);
              for (final key in ['playback-mode', 'playback-speed']) {
                final control = find.byKey(Key(key));
                expect(
                  tester.getSize(control).height,
                  greaterThanOrEqualTo(48),
                );
                expect(tester.getRect(control).left, greaterThanOrEqualTo(0));
                expect(
                  tester.getRect(control).right,
                  lessThanOrEqualTo(size.width),
                );
              }
              await tester.tap(find.byKey(const Key('playback-speed')));
              await tester.pumpAndSettle();
              final fastest = find.byKey(const ValueKey('speed-option-2.0x'));
              await tester.scrollUntilVisible(fastest, 200);
              await tester.tap(fastest);
              await tester.pumpAndSettle();
              expect(find.text('2.0x'), findsOneWidget);
              expect(tester.takeException(), isNull);
              await tester.tap(find.byKey(const Key('playback-mode')));
              await tester.pumpAndSettle();
              final last = find.byKey(const ValueKey('mode-option-sequential'));
              await tester.scrollUntilVisible(last, 200);
              expect(tester.getSize(last).height, greaterThanOrEqualTo(48));
              await tester.tap(last);
              await tester.pumpAndSettle();
              expect(find.text('顺序连读'), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
          },
        );
      }
    }
  }
}
