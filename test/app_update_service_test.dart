import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:english_point_reading/services/app_update_service.dart';

void main() {
  late Directory directory;
  late _Platform platform;
  late _Transport transport;
  late _Preferences preferences;
  late AppUpdateService service;
  final now = DateTime.utc(2026, 10, 4, 12);
  final apk = Uint8List.fromList([0x50, 0x4b, 3, 4, 7, 8, 9]);
  final api = Uri.https(
    'gitee.com',
    '/api/v5/repos/example/app/releases/latest',
  );
  final manifestUrl = Uri.https(
    'gitee.com',
    '/example/app/download/update.json',
  );
  final apkUrl = Uri.https('foruda.gitee.com', '/apk/app.apk');

  Map<String, dynamic> manifest({
    int buildNumber = 5,
    int versionCode = 2005,
    String? hash,
    String abi = 'arm64-v8a',
    String package = 'com.example.english_point_reading',
  }) => {
    'schemaVersion': 1,
    'versionName': '1.4.0',
    'buildNumber': buildNumber,
    'packageName': package,
    'certSha256': 'a' * 64,
    'minSdk': 24,
    'releaseNotes': '通知降音与六档倍速',
    'architectures': {
      abi: {
        'url': apkUrl.toString(),
        'size': apk.length,
        'sha256': hash ?? sha256.convert(apk).toString(),
        'versionCode': versionCode,
      },
    },
  };

  void publish(Map<String, dynamic> data) {
    transport.metadata[api] = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'tag_name': 'v1.4.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            {
              'name': 'update.json',
              'browser_download_url': manifestUrl.toString(),
            },
          ],
        }),
      ),
    );
    transport.metadata[manifestUrl] = Uint8List.fromList(
      utf8.encode(jsonEncode(data)),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reader-updates-');
    platform = _Platform(directory.path);
    transport = _Transport(apk);
    preferences = _Preferences();
    service = AppUpdateService(
      platform: platform,
      transport: transport,
      preferences: preferences,
      releaseApi: api,
      clock: () => now,
    );
    publish(manifest());
  });

  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  test('unsupported platforms never request metadata or permissions', () async {
    platform.supported = false;
    await service.checkForUpdates(force: true);
    expect(service.state, AppUpdateState.unsupported);
    expect(transport.metadataRequests, isEmpty);
    expect(platform.permissionChecks, 0);
  });

  test('initialization failure cannot start a network check', () async {
    platform.initializationFails = true;
    await service.checkForUpdates(force: true);
    expect(service.state, AppUpdateState.failed);
    expect(transport.metadataRequests, isEmpty);
    expect(service.errorMessage, contains('版本'));
  });

  test('uses canonical build numbers and chooses the device ABI', () async {
    final release = await service.checkForUpdates(force: true);
    expect(release?.versionName, '1.4.0');
    expect(service.installedApp?.buildNumber, 4);
    expect(service.installedApp?.versionCode, 2004);
    expect(service.selectedArtifact?.abi, 'arm64-v8a');
    expect(service.state, AppUpdateState.available);
    expect(preferences.lastCheck, now);
    expect(platform.permissionChecks, 0);
  });

  test(
    'same or older build never downloads or requests install grants',
    () async {
      publish(manifest(buildNumber: 4, versionCode: 2004));
      await service.checkForUpdates(force: true);
      await service.startDownload();
      expect(service.state, AppUpdateState.upToDate);
      expect(transport.downloads, 0);
      expect(platform.permissionChecks, 0);
    },
  );

  test('different package and incompatible ABI are not offered', () async {
    publish(manifest(package: 'another.app'));
    await service.checkForUpdates(force: true);
    expect(service.state, AppUpdateState.upToDate);
    publish(manifest(abi: 'x86_64', versionCode: 4005));
    await service.checkForUpdates(force: true);
    expect(service.state, AppUpdateState.upToDate);
  });

  test(
    'automatic checks are throttled; explicit checks bypass the timer',
    () async {
      preferences.lastCheck = now.subtract(const Duration(hours: 1));
      await service.checkForUpdates();
      expect(transport.metadataRequests, isEmpty);
      await service.checkForUpdates(force: true);
      expect(transport.metadataRequests.length, 2);
    },
  );

  test(
    'failed checks can immediately retry and do not save a timestamp',
    () async {
      transport.metadataFails = true;
      await service.checkForUpdates();
      expect(service.state, AppUpdateState.failed);
      expect(preferences.lastCheck, isNull);
      transport.metadataFails = false;
      await service.checkForUpdates();
      expect(service.state, AppUpdateState.available);
    },
  );

  test('concurrent requests share a single check', () async {
    transport.metadataGate = Completer<void>();
    final first = service.checkForUpdates(force: true);
    final second = service.checkForUpdates(force: true);
    await Future<void>.delayed(Duration.zero);
    transport.metadataGate!.complete();
    await Future.wait([first, second]);
    expect(transport.metadataRequests.length, 2);
  });

  test('HTTP manifest or APK locations are rejected', () async {
    final data = manifest();
    (data['architectures'] as Map)['arm64-v8a']['url'] =
        'http://example.com/a.apk';
    publish(data);
    await service.checkForUpdates(force: true);
    expect(service.state, AppUpdateState.failed);
    expect(service.release, isNull);
  });

  test(
    'download progress produces a verified private APK without permission',
    () async {
      await service.checkForUpdates(force: true);
      final seen = <double>[];
      service.addListener(() => seen.add(service.downloadProgress));
      await service.startDownload();
      expect(service.state, AppUpdateState.ready);
      expect(service.downloadProgress, 1);
      expect(seen, containsAllInOrder([0.0, 0.5, 1.0]));
      expect(platform.validations, 1);
      expect(platform.validationPaths.single, endsWith('.apk'));
      expect(platform.validationPaths.single, isNot(endsWith('.part')));
      expect(platform.permissionChecks, 0);
      expect(
        await File('${directory.path}/xiangshao-5-arm64-v8a.apk').readAsBytes(),
        apk,
      );
      expect(
        directory.listSync().where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test('cached verified download avoids a second HTTP request', () async {
    await service.checkForUpdates(force: true);
    await service.startDownload();
    await service.startDownload();
    expect(service.state, AppUpdateState.ready);
    expect(transport.downloads, 1);
    expect(platform.validations, 2);
  });

  test('corrupt cached APK is replaced and verified', () async {
    await File('${directory.path}/xiangshao-5-arm64-v8a.apk')
        .writeAsString('broken');
    await service.checkForUpdates(force: true);
    await service.startDownload();
    expect(service.state, AppUpdateState.ready);
    expect(transport.downloads, 1);
  });

  test(
    'checksum mismatch deletes partial data and never reaches installer',
    () async {
      publish(manifest(hash: '0' * 64));
      await service.checkForUpdates(force: true);
      await service.startDownload();
      await service.installUpdate();
      expect(service.state, AppUpdateState.failed);
      expect(platform.validations, 0);
      expect(platform.installs, 0);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'native signature validation failure removes the incomplete APK',
    () async {
      platform.validationFails = true;
      await service.checkForUpdates(force: true);
      await service.startDownload();
      expect(service.state, AppUpdateState.failed);
      expect(platform.installs, 0);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('cancel removes partial download and keeps update available', () async {
    await service.checkForUpdates(force: true);
    transport.downloadGate = Completer<void>();
    final pending = service.startDownload();
    await transport.downloadStarted.future;
    service.cancelDownload();
    transport.downloadGate!.complete();
    await pending;
    expect(service.state, AppUpdateState.available);
    expect(service.downloadProgress, 0);
    expect(platform.validations, 0);
    expect(directory.listSync(), isEmpty);
  });

  test('install grants are requested only after a verified download', () async {
    await service.checkForUpdates(force: true);
    await service.startDownload();
    await service.installUpdate();
    expect(service.state, AppUpdateState.installPermissionRequired);
    expect(platform.settingsOpened, 1);
    expect(platform.installs, 0);
    await service.resumeInstallationAfterPermission();
    expect(platform.installs, 0);
    platform.allowed = true;
    await service.resumeInstallationAfterPermission();
    expect(platform.installs, 1);
    expect(service.state, AppUpdateState.installing);
    await service.resumeInstallationAfterPermission();
    expect(platform.installs, 1);
    expect(service.state, AppUpdateState.ready);
  });

  test('allowed installation stays in app and rechecks the package', () async {
    platform.allowed = true;
    await service.checkForUpdates(force: true);
    await service.startDownload();
    await service.installUpdate();
    expect(platform.installs, 1);
    expect(platform.validations, 2);
    expect(platform.settingsOpened, 0);
    expect(service.state, AppUpdateState.installing);
    await service.resumeInstallationAfterPermission();
    expect(service.state, AppUpdateState.ready);
    await service.installUpdate();
    expect(platform.installs, 2);
  });

  test('rapid repeat install taps open the system installer once', () async {
    platform.allowed = true;
    await service.checkForUpdates(force: true);
    await service.startDownload();
    await Future.wait([service.installUpdate(), service.installUpdate()]);
    expect(platform.installs, 1);
    expect(service.state, AppUpdateState.installing);
  });

  test(
    'returning from successful install refreshes the displayed version',
    () async {
      platform.allowed = true;
      await service.checkForUpdates(force: true);
      await service.startDownload();
      await service.installUpdate();
      platform.installedBuild = 5;
      await service.resumeInstallationAfterPermission();
      expect(service.state, AppUpdateState.upToDate);
      expect(service.installedApp?.buildNumber, 5);
      expect(service.release, isNull);
    },
  );

  test(
    'a downloaded file modified before install cannot be installed',
    () async {
      platform.allowed = true;
      await service.checkForUpdates(force: true);
      await service.startDownload();
      await File('${directory.path}/xiangshao-5-arm64-v8a.apk')
          .writeAsBytes([1, 2]);
      await service.installUpdate();
      expect(service.state, AppUpdateState.failed);
      expect(platform.installs, 0);
    },
  );
}

class _Platform implements UpdatePlatform {
  _Platform(this.directory);
  final String directory;
  bool supported = true;
  bool allowed = false;
  bool initializationFails = false;
  bool validationFails = false;
  int permissionChecks = 0;
  int settingsOpened = 0;
  int validations = 0;
  final validationPaths = <String>[];
  int installs = 0;
  int installedBuild = 4;

  @override
  bool get isSupported => supported;

  @override
  Future<InstalledAppInfo> getInstalledApp() async {
    if (initializationFails) throw StateError('No native bridge');
    return InstalledAppInfo(
      versionName: installedBuild == 4 ? '1.3.0' : '1.4.0',
      versionCode: 2000 + installedBuild,
      buildNumber: installedBuild,
      packageName: 'com.example.english_point_reading',
      abis: ['arm64-v8a', 'armeabi-v7a'],
    );
  }

  @override
  Future<String> getDownloadDirectory() async => directory;

  @override
  Future<bool> canInstallPackages() async {
    permissionChecks++;
    return allowed;
  }

  @override
  Future<void> openInstallPermissionSettings() async => settingsOpened++;

  @override
  Future<void> validateApk(String path, UpdateArtifact artifact) async {
    validations++;
    validationPaths.add(path);
    if (validationFails) throw StateError('Untrusted signing certificate');
  }

  @override
  Future<void> installApk(String path, UpdateArtifact artifact) async =>
      installs++;
}

class _Preferences implements UpdatePreferencesStore {
  DateTime? lastCheck;
  @override
  Future<DateTime?> loadLastCheck() async => lastCheck;
  @override
  Future<void> saveLastCheck(DateTime value) async => lastCheck = value;
}

class _Transport implements UpdateTransport {
  _Transport(this.apk);
  final Uint8List apk;
  final metadata = <Uri, Uint8List>{};
  final metadataRequests = <Uri>[];
  bool metadataFails = false;
  Completer<void>? metadataGate;
  Completer<void>? downloadGate;
  final downloadStarted = Completer<void>();
  int downloads = 0;

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    metadataRequests.add(url);
    if (metadataGate != null) await metadataGate!.future;
    if (metadataFails) throw const SocketException('Offline');
    return metadata[url]!;
  }

  @override
  Future<void> download(
    Uri url,
    File destination, {
    required int expectedSize,
    required DownloadCancellation cancellation,
    required void Function(int received, int total) onProgress,
  }) async {
    downloads++;
    await destination.writeAsBytes(apk.sublist(0, 2));
    onProgress(expectedSize ~/ 2, expectedSize - 1);
    downloadStarted.complete();
    if (downloadGate != null) await downloadGate!.future;
    cancellation.throwIfCancelled();
    await destination.writeAsBytes(apk);
    onProgress(expectedSize, expectedSize);
  }

  @override
  void close() {}
}
