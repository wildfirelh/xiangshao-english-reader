import 'dart:async';

import 'package:english_point_reading/services/app_update_service.dart';
import 'package:english_point_reading/widgets/app_update_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeUpdateService extends AppUpdateService {
  FakeUpdateService({this.availableOnStartup = false});

  final bool availableOnStartup;
  final forcedChecks = <bool>[];
  AppUpdateState value = AppUpdateState.idle;
  bool manualUpdateAvailable = true;
  bool failCheck = false;
  bool grantInstall = true;
  int installs = 0;
  int resumes = 0;
  int cancellations = 0;
  double progress = 0;
  Completer<void>? downloading;
  UpdateRelease? update;

  @override
  AppUpdateState get state => value;
  @override
  UpdateRelease? get release => update;
  @override
  InstalledAppInfo get installedApp => const InstalledAppInfo(
    versionName: '1.3.9',
    versionCode: 4004,
    buildNumber: 4,
    packageName: 'com.example.english_point_reading',
    abis: ['x86_64'],
  );
  @override
  int get downloadTotalBytes => 42 * 1024 * 1024;
  @override
  double get downloadProgress => progress;
  @override
  String? get errorMessage => failCheck ? '暂时无法检查更新，请检查网络后重试' : null;
  @override
  bool get isBusy =>
      value == AppUpdateState.checking || value == AppUpdateState.downloading;
  @override
  Future<void> initialize() async {}

  @override
  Future<UpdateRelease?> checkForUpdates({bool force = false}) async {
    forcedChecks.add(force);
    if (failCheck) {
      value = AppUpdateState.failed;
    } else if (force ? manualUpdateAvailable : availableOnStartup) {
      update = const UpdateRelease(
        versionName: '1.4.0',
        buildNumber: 5,
        releaseNotes: '通知降音、六档倍速、应用内更新。',
        architectures: {},
      );
      value = AppUpdateState.available;
    } else {
      update = null;
      value = AppUpdateState.upToDate;
    }
    notifyListeners();
    return update;
  }

  @override
  Future<void> startDownload() async {
    value = AppUpdateState.downloading;
    notifyListeners();
    await downloading?.future;
    if (value != AppUpdateState.downloading) {
      return;
    }
    progress = 1;
    value = AppUpdateState.ready;
    notifyListeners();
  }

  @override
  void cancelDownload() {
    cancellations++;
    value = AppUpdateState.available;
    if (downloading != null && !downloading!.isCompleted) {
      downloading!.complete();
    }
    notifyListeners();
  }

  @override
  Future<void> installUpdate() async {
    if (grantInstall) {
      installs++;
      value = AppUpdateState.installing;
    } else {
      value = AppUpdateState.installPermissionRequired;
    }
    notifyListeners();
  }

  @override
  Future<void> resumeInstallationAfterPermission() async {
    resumes++;
    if (grantInstall) await installUpdate();
  }
}

Future<void> mountEntry(
  WidgetTester tester,
  FakeUpdateService service, {
  double scale = 1,
}) async {
  addTearDown(service.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: AppUpdateEntry(service: service)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> manualCheck(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('check-app-update')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'startup checks quietly and manual check shows new version notes',
    (tester) async {
      final service = FakeUpdateService();
      await mountEntry(tester, service);
      expect(service.forcedChecks, [false]);
      expect(find.text('应用更新'), findsNothing);
      await manualCheck(tester);
      expect(service.forcedChecks, [false, true]);
      expect(find.text('当前版本 1.3.9'), findsOneWidget);
      expect(find.text('新版本 1.4.0'), findsOneWidget);
      expect(find.text('安装包 42.0 MB'), findsOneWidget);
      expect(find.text('通知降音、六档倍速、应用内更新。'), findsOneWidget);
      expect(service.installs, 0);
    },
  );

  testWidgets('startup offers available update without beginning a download', (
    tester,
  ) async {
    final service = FakeUpdateService(availableOnStartup: true);
    await mountEntry(tester, service);
    expect(find.text('新版本 1.4.0'), findsOneWidget);
    expect(service.state, AppUpdateState.available);
    expect(service.installs, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('应用更新'), findsNothing);
    expect(service.cancellations, 0);
  });

  testWidgets('no update and offline check do not disrupt startup', (
    tester,
  ) async {
    final service = FakeUpdateService()..manualUpdateAvailable = false;
    await mountEntry(tester, service);
    await manualCheck(tester);
    expect(find.text('已经是最新版本'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    service.failCheck = true;
    await manualCheck(tester);
    expect(find.text('暂时无法检查更新，请检查网络后重试'), findsOneWidget);
    expect(find.text('重新检查'), findsOneWidget);
    service.failCheck = false;
    await tester.tap(find.text('重新检查'));
    await tester.pumpAndSettle();
    expect(find.text('已经是最新版本'), findsOneWidget);
  });

  testWidgets('download shows progress and cancel prevents installation', (
    tester,
  ) async {
    final service = FakeUpdateService()..downloading = Completer<void>();
    await mountEntry(tester, service);
    await manualCheck(tester);
    await tester.tap(find.byKey(const Key('download-update')));
    await tester.pump();
    service.progress = .45;
    service.notifyListeners();
    await tester.pump();
    expect(find.text('正在下载 45%'), findsOneWidget);
    await tester.tap(find.text('取消下载'));
    await tester.pumpAndSettle();
    expect(service.cancellations, 1);
    expect(service.installs, 0);
    expect(find.text('下载并安装'), findsOneWidget);
  });

  testWidgets('closing a downloading sheet cancels the download', (
    tester,
  ) async {
    final service = FakeUpdateService()..downloading = Completer<void>();
    await mountEntry(tester, service);
    await manualCheck(tester);
    await tester.tap(find.byKey(const Key('download-update')));
    await tester.pump();
    await tester.tap(find.text('取消并关闭'));
    await tester.pumpAndSettle();
    expect(service.cancellations, 1);
    expect(service.installs, 0);
    expect(find.text('应用更新'), findsNothing);
  });

  testWidgets(
    'successful in-app download launches installation automatically',
    (tester) async {
      final service = FakeUpdateService();
      await mountEntry(tester, service);
      await manualCheck(tester);
      await tester.tap(find.byKey(const Key('download-update')));
      await tester.pumpAndSettle();
      expect(service.installs, 1);
      expect(find.text('已打开系统安装器，请按提示安装。'), findsOneWidget);
    },
  );

  testWidgets(
    'return from install permission resumes installation only after grant',
    (tester) async {
      final service = FakeUpdateService()..grantInstall = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await mountEntry(tester, service);
      await manualCheck(tester);
      await tester.tap(find.byKey(const Key('download-update')));
      await tester.pumpAndSettle();
      expect(service.installs, 0);
      expect(find.text('允许安装更新'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      service.grantInstall = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.resumes, 1);
      expect(service.installs, 1);
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(service.resumes, 1);
    },
  );

  testWidgets('update prompt scrolls at small size and large font', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = FakeUpdateService();
    await mountEntry(tester, service, scale: 2);
    await manualCheck(tester);
    await tester.ensureVisible(find.byKey(const Key('download-update')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('download-update')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('download-update'))).height,
      greaterThanOrEqualTo(48),
    );
  });
}
