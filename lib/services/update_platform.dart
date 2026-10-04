import 'dart:io';

import 'package:flutter/services.dart';

import '../models/app_update.dart';

abstract interface class UpdatePlatform {
  bool get isSupported;
  Future<InstalledAppInfo> getInstalledApp();
  Future<String> getDownloadDirectory();
  Future<bool> canInstallPackages();
  Future<void> openInstallPermissionSettings();
  Future<void> validateApk(String path, UpdateArtifact artifact);
  Future<void> installApk(String path, UpdateArtifact artifact);
}

class AndroidUpdatePlatform implements UpdatePlatform {
  const AndroidUpdatePlatform();

  static const channel = MethodChannel('xiangshao_reader/app_updates');

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<InstalledAppInfo> getInstalledApp() async {
    final data = await channel.invokeMapMethod<String, dynamic>(
      'getInstalledApp',
    );
    if (data == null) throw const FormatException('Missing installed version');
    return InstalledAppInfo.fromJson(data);
  }

  @override
  Future<String> getDownloadDirectory() async {
    final path = await channel.invokeMethod<String>('getDownloadDirectory');
    if (path == null || path.isEmpty) {
      throw const FormatException('Missing private download directory');
    }
    return path;
  }

  @override
  Future<bool> canInstallPackages() async =>
      await channel.invokeMethod<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openInstallPermissionSettings() =>
      channel.invokeMethod<void>('openInstallPermissionSettings');

  Map<String, Object> _apkArguments(String path, UpdateArtifact artifact) => {
    'path': path,
    'versionCode': artifact.versionCode,
    'size': artifact.size,
    'sha256': artifact.sha256,
  };

  @override
  Future<void> validateApk(String path, UpdateArtifact artifact) =>
      channel.invokeMethod<void>('validateApk', _apkArguments(path, artifact));

  @override
  Future<void> installApk(String path, UpdateArtifact artifact) =>
      channel.invokeMethod<void>('installApk', _apkArguments(path, artifact));
}
