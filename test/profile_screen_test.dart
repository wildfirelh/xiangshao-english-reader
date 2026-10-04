import 'package:english_point_reading/screens/profile_screen.dart';
import 'package:english_point_reading/services/app_update_service.dart';
import 'package:english_point_reading/services/learning_controller.dart';
import 'package:english_point_reading/services/learning_preferences_store.dart';
import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Updates extends AppUpdateService {
  int checks = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<UpdateRelease?> checkForUpdates({bool force = false}) async {
    checks++;
    return null;
  }

  @override
  InstalledAppInfo get installedApp => const InstalledAppInfo(
    versionName: '2.7.3',
    versionCode: 2073,
    buildNumber: 73,
    packageName: 'com.example.english_point_reading',
    abis: ['arm64-v8a'],
  );
}

class _FailingStore extends InMemoryLearningPreferencesStore {
  @override
  Future<void> save(LearningPreferences value) async {
    throw StateError('storage rejected');
  }
}

class _UnreadableStore extends InMemoryLearningPreferencesStore {
  @override
  Future<LearningPreferences?> load() async {
    throw StateError('storage unavailable');
  }
}

void main() {
  LearningController controller({LearningPreferencesStore? store}) =>
      LearningController(
        preferencesStore: store ?? InMemoryLearningPreferencesStore(),
        playbackPreferencesStore: InMemoryPlaybackPreferencesStore(),
        now: () => DateTime(2026, 10, 4),
      );

  Future<void> mount(
    WidgetTester tester,
    LearningController controller,
    _Updates updates, {
    double scale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF486A59),
          brightness: brightness,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: ProfileScreen(controller: controller, updateService: updates),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a new profile shows zero confirmed activity without a fake account',
    (tester) async {
      final value = controller();
      final updates = _Updates();
      addTearDown(value.dispose);
      addTearDown(updates.dispose);
      await mount(tester, value, updates);
      expect(find.text('我的'), findsOneWidget);
      expect(find.text('0 天'), findsOneWidget);
      expect(find.text('0 本'), findsOneWidget);
      expect(find.textContaining('登录'), findsNothing);
      expect(find.byKey(const Key('profile-eye-reminder')), findsOneWidget);
      expect(updates.checks, 1);
    },
  );

  testWidgets(
    'real point reads refresh profile counts without recreating the tab',
    (tester) async {
      final value = controller();
      final updates = _Updates();
      addTearDown(value.dispose);
      addTearDown(updates.dispose);
      await mount(tester, value, updates);
      await value.recordPointRead('first');
      await value.recordPointRead('first');
      await value.recordPointRead('second');
      await tester.pumpAndSettle();
      expect(find.text('1 天'), findsOneWidget);
      expect(find.text('2 本'), findsOneWidget);
      expect(updates.checks, 1);
    },
  );

  testWidgets('unreadable statistics show unknown instead of invented zeros', (
    tester,
  ) async {
    final value = controller(store: _UnreadableStore());
    final updates = _Updates();
    addTearDown(value.dispose);
    addTearDown(updates.dispose);
    await mount(tester, value, updates);
    expect(find.text('— 天'), findsOneWidget);
    expect(find.text('— 本'), findsOneWidget);
    expect(find.text('0 天'), findsNothing);
    expect(find.text('学习记录暂时无法读取，请稍后再试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('eye reminder switch saves the actual preference', (
    tester,
  ) async {
    final store = InMemoryLearningPreferencesStore();
    final value = controller(store: store);
    final updates = _Updates();
    addTearDown(value.dispose);
    addTearDown(updates.dispose);
    await mount(tester, value, updates);
    final eyeSwitch = find.descendant(
      of: find.byKey(const Key('profile-eye-reminder')),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(eyeSwitch).value, isTrue);
    await tester.tap(eyeSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(eyeSwitch).value, isFalse);
    expect((await store.load())!.eyeReminderEnabled, isFalse);
    expect(find.text('每 20 分钟提醒休息'), findsOneWidget);
  });

  testWidgets(
    'a failed eye save leaves the switch on and gives recovery feedback',
    (tester) async {
      final value = controller(store: _FailingStore());
      final updates = _Updates();
      addTearDown(value.dispose);
      addTearDown(updates.dispose);
      await mount(tester, value, updates);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('profile-eye-reminder')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(value.eyeReminderEnabled, isTrue);
      expect(find.text('未能保存，请重试'), findsOneWidget);
    },
  );

  testWidgets('six-speed picker saves a choice for the next reader', (
    tester,
  ) async {
    final value = controller();
    final updates = _Updates();
    addTearDown(value.dispose);
    addTearDown(updates.dispose);
    await mount(tester, value, updates);
    await tester.ensureVisible(find.byKey(const Key('profile-speed')));
    await tester.tap(find.byKey(const Key('profile-speed')));
    await tester.pumpAndSettle();
    for (final speed in [0.5, 0.8, 1.0, 1.2, 1.5, 2.0]) {
      expect(
        find.byKey(ValueKey('profile-speed-option-$speed')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('profile-speed-option-1.5')));
    await tester.pumpAndSettle();
    expect(value.currentSpeed, 1.5);
    expect(find.text('1.5x · 用于下次打开的课本'), findsOneWidget);
  });

  testWidgets(
    'about uses actual installed version and truthful resource licensing',
    (tester) async {
      final value = controller();
      final updates = _Updates();
      addTearDown(value.dispose);
      addTearDown(updates.dispose);
      await mount(tester, value, updates);
      await tester.ensureVisible(find.byKey(const Key('profile-about')));
      await tester.tap(find.byKey(const Key('profile-about')));
      await tester.pumpAndSettle();
      expect(find.text('版本 2.7.3（构建 73）'), findsOneWidget);
      expect(find.textContaining('不属于 MIT 授权范围'), findsOneWidget);
      expect(find.text('开源许可'), findsOneWidget);
    },
  );

  testWidgets(
    'small dark screen with double font keeps settings and dialogs usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final value = controller();
      final updates = _Updates();
      addTearDown(value.dispose);
      addTearDown(updates.dispose);
      await mount(
        tester,
        value,
        updates,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('profile-speed')));
      await tester.tap(find.byKey(const Key('profile-speed')));
      await tester.pumpAndSettle();
      final option = find.byKey(const ValueKey('profile-speed-option-2.0'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(value.currentSpeed, 2.0);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('profile-about')));
      await tester.tap(find.byKey(const Key('profile-about')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('知道了'), findsOneWidget);
      expect(find.text('开源许可'), findsOneWidget);
    },
  );
}
