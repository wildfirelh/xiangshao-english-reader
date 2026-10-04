import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/app_update.dart';
import 'update_platform.dart';
import 'update_preferences_store.dart';
import 'update_transport.dart';

export '../models/app_update.dart';
export 'update_platform.dart';
export 'update_preferences_store.dart';
export 'update_transport.dart';

enum AppUpdateState {
  idle,
  checking,
  available,
  upToDate,
  downloading,
  ready,
  installPermissionRequired,
  installing,
  failed,
  unsupported,
}

class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    UpdatePlatform? platform,
    UpdateTransport? transport,
    UpdatePreferencesStore? preferences,
    Uri? releaseApi,
    DateTime Function()? clock,
  }) : _platform = platform ?? const AndroidUpdatePlatform(),
       _transport = transport ?? HttpUpdateTransport(),
       _preferences = preferences ?? SharedPreferencesUpdateStore(),
       _releaseApi = releaseApi ?? Uri.parse(defaultReleaseApi),
       _clock = clock ?? DateTime.now;

  static const defaultReleaseApi = String.fromEnvironment(
    'UPDATE_RELEASE_API',
    defaultValue: 'https://gitee.com/api/v5/repos/wildfire666/xiangshao-english-reader/releases/latest',
  );
  static const automaticCheckInterval = Duration(hours: 24);
  final UpdatePlatform _platform;
  final UpdateTransport _transport;
  final UpdatePreferencesStore _preferences;
  final Uri _releaseApi;
  final DateTime Function() _clock;
  AppUpdateState _state = AppUpdateState.idle;
  InstalledAppInfo? _installedApp;
  UpdateRelease? _release;
  UpdateArtifact? _artifact;
  String? _errorMessage;
  double _downloadProgress = 0;
  File? _downloadedApk;
  DownloadCancellation? _cancellation;
  DateTime? _lastCheck;
  Future<void>? _initialization;
  Future<UpdateRelease?>? _check;
  bool _disposed = false;
  bool _waitingForPermission = false;
  bool _installOperationPending = false;
  bool _resuming = false;

  AppUpdateState get state => _state;
  UpdateRelease? get release => _release;
  UpdateArtifact? get selectedArtifact => _artifact;
  int? get downloadTotalBytes => _artifact?.size;
  InstalledAppInfo? get installedApp => _installedApp;
  double get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;
  bool get isSupported => _platform.isSupported;
  bool get isBusy =>
      _installOperationPending ||
      const [
        AppUpdateState.checking,
        AppUpdateState.downloading,
        AppUpdateState.installing,
      ].contains(_state);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!_platform.isSupported) {
      _state = AppUpdateState.unsupported;
      _notify();
      return;
    }
    try {
      _installedApp = await _platform.getInstalledApp();
      try {
        _lastCheck = await _preferences.loadLastCheck();
      } catch (_) {
        // A preferences failure must not prevent a manual update.
      }
      _notify();
    } catch (_) {
      _state = AppUpdateState.failed;
      _errorMessage = '无法读取应用版本，请重新打开应用后再试';
      _notify();
    }
  }

  Future<UpdateRelease?> checkForUpdates({bool force = false}) {
    if (_check != null) return _check!;
    final pending = _checkForUpdates(force: force);
    _check = pending;
    return pending.whenComplete(() => _check = null);
  }

  Future<UpdateRelease?> _checkForUpdates({required bool force}) async {
    await initialize();
    if (_disposed || _installedApp == null || isBusy) return _release;
    if (!force &&
        _lastCheck != null &&
        _clock().difference(_lastCheck!) >= Duration.zero &&
        _clock().difference(_lastCheck!) < automaticCheckInterval) {
      return _release;
    }
    _state = AppUpdateState.checking;
    _errorMessage = null;
    _notify();
    try {
      final bytes = await _transport.getBytes(
        _releaseApi,
        maxBytes: 256 * 1024,
      );
      final latest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (latest['draft'] == true || latest['prerelease'] == true) {
        throw const FormatException('Release is not stable');
      }
      final assets = latest['assets'];
      if (assets is! List) {
        throw const FormatException('Release has no assets');
      }
      final manifests = assets.whereType<Map>().where(
        (asset) => asset['name'] == 'update.json',
      );
      if (manifests.length != 1) {
        throw const FormatException('Release update manifest is missing');
      }
      final url = Uri.parse(manifests.single['browser_download_url'] as String);
      if (!isSecureUpdateUri(url)) {
        throw const FormatException('Manifest must use HTTPS');
      }
      final manifest = await _transport.getBytes(url, maxBytes: 256 * 1024);
      final release = UpdateRelease.fromJson(
        jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>,
      );
      if (_disposed) return null;
      _lastCheck = _clock().toUtc();
      try {
        await _preferences.saveLastCheck(_lastCheck!);
      } catch (_) {
        // Successful checks remain useful without persistence.
      }
      if (_disposed) return null;
      if (release.isNewerThan(_installedApp!)) {
        _release = release;
        _artifact = release.artifactFor(_installedApp!);
        _state = AppUpdateState.available;
      } else {
        _release = null;
        _artifact = null;
        _state = AppUpdateState.upToDate;
      }
      _notify();
      return _release;
    } catch (_) {
      if (_disposed) return null;
      _state = AppUpdateState.failed;
      _errorMessage = '暂时无法检查更新，请检查网络后重试';
      _notify();
      return null;
    }
  }

  Future<void> _verifyDownload(
    File file,
    UpdateArtifact artifact, {
    bool verifyPackage = true,
  }) async {
    if (await file.length() != artifact.size) {
      throw const FormatException('APK size does not match');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != artifact.sha256) {
      throw const FormatException('APK checksum does not match');
    }
    if (verifyPackage) await _platform.validateApk(file.path, artifact);
  }

  Future<void> startDownload() async {
    final artifact = _artifact;
    final release = _release;
    if (_disposed || isBusy || artifact == null || release == null) return;
    _state = AppUpdateState.downloading;
    _errorMessage = null;
    _downloadProgress = 0;
    _downloadedApk = null;
    _waitingForPermission = false;
    final cancellation = DownloadCancellation();
    _cancellation = cancellation;
    _notify();
    File? partial;
    try {
      final directory = Directory(await _platform.getDownloadDirectory());
      await directory.create(recursive: true);
      cancellation.throwIfCancelled();
      final target = File(
        '${directory.path}${Platform.pathSeparator}'
        'xiangshao-${release.buildNumber}-${artifact.abi}.apk',
      );
      if (await target.exists()) {
        try {
          await _verifyDownload(target, artifact);
          cancellation.throwIfCancelled();
          _downloadedApk = target;
          _downloadProgress = 1;
          _state = AppUpdateState.ready;
          _notify();
          return;
        } on DownloadCancelled {
          rethrow;
        } catch (_) {
          await target.delete();
        }
      }
      partial = File('${target.path}.part');
      if (await partial.exists()) await partial.delete();
      await _transport.download(
        artifact.url,
        partial,
        expectedSize: artifact.size,
        cancellation: cancellation,
        onProgress: (received, total) {
          if (_disposed || cancellation.isCancelled) return;
          final progress = (received / total).clamp(0.0, 1.0);
          if (progress == 1 || progress - _downloadProgress >= 0.01) {
            _downloadProgress = progress;
            _notify();
          }
        },
      );
      cancellation.throwIfCancelled();
      await _verifyDownload(partial, artifact, verifyPackage: false);
      cancellation.throwIfCancelled();
      final candidate = await partial.rename(target.path);
      try {
        await _platform.validateApk(candidate.path, artifact);
        cancellation.throwIfCancelled();
      } catch (_) {
        await candidate.delete();
        rethrow;
      }
      _downloadedApk = candidate;
      _downloadProgress = 1;
      if (_disposed) return;
      _state = AppUpdateState.ready;
      _notify();
    } on DownloadCancelled {
      if (!_disposed) {
        _state = AppUpdateState.available;
        _downloadProgress = 0;
        _notify();
      }
    } catch (_) {
      if (!_disposed) {
        _state = AppUpdateState.failed;
        _errorMessage = cancellation.isCancelled ? null : '下载或安装包校验失败，请重试';
        if (cancellation.isCancelled) _state = AppUpdateState.available;
        _notify();
      }
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        // A cache cleanup failure must not create an unhandled UI future.
      }
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  void cancelDownload() => _cancellation?.cancel();

  Future<void> installUpdate() async {
    final file = _downloadedApk;
    final artifact = _artifact;
    if (_disposed || isBusy || file == null || artifact == null) return;
    _installOperationPending = true;
    _notify();
    try {
      await _verifyDownload(file, artifact);
      if (_disposed) return;
      if (!await _platform.canInstallPackages()) {
        _waitingForPermission = true;
        _state = AppUpdateState.installPermissionRequired;
        _notify();
        await _platform.openInstallPermissionSettings();
        return;
      }
      _waitingForPermission = false;
      await _launchInstaller(file, artifact);
    } catch (_) {
      if (_disposed) return;
      _state = AppUpdateState.failed;
      _errorMessage = '无法打开安装程序，请重试';
      _notify();
    } finally {
      _installOperationPending = false;
      _notify();
    }
  }

  Future<void> _launchInstaller(File file, UpdateArtifact artifact) async {
    _state = AppUpdateState.installing;
    _notify();
    try {
      await _platform.installApk(file.path, artifact);
    } catch (_) {
      if (!_disposed) {
        _state = AppUpdateState.ready;
        _notify();
      }
      rethrow;
    }
  }

  Future<void> resumeInstallationAfterPermission() async {
    if (_disposed || _resuming) return;
    _resuming = true;
    try {
      await _resumeInstallation();
    } finally {
      _resuming = false;
    }
  }

  Future<void> _resumeInstallation() async {
    if (_state == AppUpdateState.installing) {
      try {
        final installed = await _platform.getInstalledApp();
        if (_disposed) return;
        _installedApp = installed;
        if (_release != null &&
            installed.buildNumber >= _release!.buildNumber) {
          _release = null;
          _artifact = null;
          _state = AppUpdateState.upToDate;
        } else {
          // Cancelling the system installer leaves the verified APK ready.
          _state = AppUpdateState.ready;
        }
      } catch (_) {
        if (_disposed) return;
        _state = AppUpdateState.ready;
      }
      _notify();
      return;
    }
    if (!_waitingForPermission) return;
    try {
      if (await _platform.canInstallPackages()) {
        _waitingForPermission = false;
        await installUpdate();
      }
    } catch (_) {
      if (_disposed) return;
      _errorMessage = '无法读取安装权限，请重试';
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    _transport.close();
    super.dispose();
  }
}
