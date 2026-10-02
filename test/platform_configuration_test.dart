import 'package:english_point_reading/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('startup requests portraitUp before displaying the app', (
    tester,
  ) async {
    final orientations = <dynamic>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await app.main();
    expect(orientations, [
      ['DeviceOrientation.portraitUp'],
    ]);
    await tester.pumpWidget(const SizedBox());
  });
}
