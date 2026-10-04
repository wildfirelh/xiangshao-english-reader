import 'package:english_point_reading/widgets/floating_capsule_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> mountCapsule(
  WidgetTester tester, {
  ValueChanged<int>? onSelected,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  EdgeInsets safePadding = const EdgeInsets.only(top: 24, bottom: 34),
  bool reducedMotion = false,
}) async {
  var selected = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF276B59),
          brightness: brightness,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize / tester.view.devicePixelRatio,
          padding: safePadding,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                const Positioned.fill(child: SizedBox()),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: StatefulBuilder(
                    builder: (context, setState) => FloatingCapsuleNavBar(
                      selectedIndex: selected,
                      onDestinationSelected: (index) {
                        onSelected?.call(index);
                        setState(() => selected = index);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void useViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'announces the selected tab and switches by tapping either item',
    (tester) async {
      final selections = <int>[];
      await mountCapsule(tester, onSelected: selections.add);
      expect(
        tester.getSemantics(find.bySemanticsLabel('书本')),
        matchesSemantics(
          label: '书本',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('我的')),
        matchesSemantics(
          label: '我的',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(selections, [1]);
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byIcon(Icons.auto_stories_outlined), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('我的')),
        matchesSemantics(
          label: '我的',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      expect(selections, [1, 0]);
      expect(find.byIcon(Icons.auto_stories), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keeps the 64 dp capsule above the safe area and 48 dp targets', (
    tester,
  ) async {
    useViewport(tester, const Size(320, 568));
    await mountCapsule(tester);
    final glass = tester.getRect(find.byType(BackdropFilter));
    expect(glass.height, 64);
    expect(glass.left, 24);
    expect(glass.right, 296);
    expect(glass.bottom, 568 - 34 - 18);
    for (final index in [0, 1]) {
      final target = tester.getSize(find.byKey(ValueKey('nav-$index')));
      expect(target.height, greaterThanOrEqualTo(48));
      expect(target.width, greaterThanOrEqualTo(48));
    }
    final profileTarget = tester.getRect(find.byKey(const ValueKey('nav-1')));
    await tester.tapAt(Offset(profileTarget.center.dx, profileTarget.top + 2));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'centers the floating bar on wide screens without stretching it',
    (tester) async {
      useViewport(tester, const Size(1000, 800));
      await mountCapsule(tester);
      final glass = tester.getRect(find.byType(BackdropFilter));
      expect(glass.width, 480);
      expect(glass.center.dx, 500);
      expect(glass.height, 64);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dark mode and doubled fonts keep both tabs reachable on small screens',
    (tester) async {
      useViewport(tester, const Size(320, 568));
      await mountCapsule(
        tester,
        brightness: Brightness.dark,
        textScale: 2,
        reducedMotion: true,
      );
      final bounds = tester.getRect(find.byType(BackdropFilter));
      expect(bounds.height, 64);
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pump();
      expect(find.byIcon(Icons.person), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pump();
      expect(find.byIcon(Icons.auto_stories), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
