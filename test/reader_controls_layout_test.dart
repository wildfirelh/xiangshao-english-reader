import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          expect(find.text('0.8x 慢速'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.text('1.0x'), findsOneWidget);
          expect(speed, 1.0);
        });
      }
    }
  }
}
