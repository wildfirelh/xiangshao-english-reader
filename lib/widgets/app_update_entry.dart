import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';

/// Keeps update checks and downloads available from the bookshelf.
class AppUpdateEntry extends StatefulWidget {
  const AppUpdateEntry({super.key, this.service});

  final AppUpdateService? service;

  @override
  State<AppUpdateEntry> createState() => _AppUpdateEntryState();
}

class _AppUpdateEntryState extends State<AppUpdateEntry>
    with WidgetsBindingObserver {
  late final AppUpdateService _service;
  late final Future<void> _initializing;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AppUpdateService();
    WidgetsBinding.instance.addObserver(this);
    _initializing = _service.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkAutomatically());
    });
  }

  Future<void> _checkAutomatically() async {
    await _initializing;
    if (!mounted) return;
    await _service.checkForUpdates();
    if (mounted &&
        !_sheetOpen &&
        ModalRoute.of(context)?.isCurrent == true &&
        _service.state == AppUpdateState.available) {
      unawaited(_showUpdateSheet());
    }
  }

  Future<void> _checkManually() async {
    await _initializing;
    if (mounted) await _service.checkForUpdates(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_service.state == AppUpdateState.installPermissionRequired ||
            _service.state == AppUpdateState.installing)) {
      unawaited(_service.resumeInstallationAfterPermission());
    }
  }

  Future<void> _downloadAndInstall() async {
    await _service.startDownload();
    if (mounted && _sheetOpen && _service.state == AppUpdateState.ready) {
      await _service.installUpdate();
    }
  }

  Future<void> _showUpdateSheet({bool check = false}) async {
    if (_sheetOpen || !mounted) return;
    _sheetOpen = true;
    if (check) unawaited(_checkManually());
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (sheetContext) => AnimatedBuilder(
          animation: _service,
          builder: (_, _) => SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: _sheetContent(sheetContext),
              ),
            ),
          ),
        ),
      );
    } finally {
      _sheetOpen = false;
      if (_service.state == AppUpdateState.downloading) {
        _service.cancelDownload();
      }
    }
  }

  Widget _sheetContent(BuildContext sheetContext) {
    final theme = Theme.of(sheetContext);
    final release = _service.release;
    final state = _service.state;
    final downloading = state == AppUpdateState.downloading;
    final checking = state == AppUpdateState.checking;
    final failed = state == AppUpdateState.failed;
    final canDownload =
        release != null && (state == AppUpdateState.available || failed);
    final percentage = (_service.downloadProgress.clamp(0, 1) * 100).round();
    final bytes = _service.downloadTotalBytes ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text('应用更新', style: theme.textTheme.titleLarge)),
            IconButton(
              tooltip: '关闭更新窗口',
              onPressed: () => Navigator.pop(sheetContext),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '当前版本 ${_service.installedApp?.versionName ?? '正在读取…'}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (checking) ...[
          const LinearProgressIndicator(semanticsLabel: '正在检查更新'),
          const SizedBox(height: 12),
          const Text('正在检查新版本…'),
        ] else if (state == AppUpdateState.upToDate) ...[
          Icon(
            Icons.check_circle_outline,
            color: theme.colorScheme.primary,
            size: 40,
          ),
          const SizedBox(height: 12),
          const Text('已经是最新版本'),
        ] else if (state == AppUpdateState.unsupported) ...[
          const Text('当前平台暂不支持安装更新'),
        ],
        if (release != null && state != AppUpdateState.upToDate) ...[
          Text(
            '新版本 ${release.versionName}',
            style: theme.textTheme.titleMedium,
          ),
          if (bytes > 0) ...[
            const SizedBox(height: 6),
            Text('安装包 ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'),
          ],
          const SizedBox(height: 12),
          Text(release.releaseNotes, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
        ],
        if (failed) ...[
          Text(
            _service.errorMessage ?? '暂时无法更新，请稍后重试',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (downloading) ...[
          LinearProgressIndicator(
            key: const Key('update-download-progress'),
            value: _service.downloadProgress.clamp(0, 1),
            semanticsLabel: '更新下载进度',
            semanticsValue: '$percentage%',
          ),
          const SizedBox(height: 12),
          Text('正在下载 $percentage%'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _service.cancelDownload,
            child: const Text('取消下载'),
          ),
        ],
        if (canDownload) ...[
          const Text('首次安装更新时，需要允许本应用安装更新。下载完成后会打开系统安装器。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('download-update'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _service.isBusy ? null : _downloadAndInstall,
            icon: const Icon(Icons.download_rounded),
            label: Text(failed ? '重试下载' : '下载并安装'),
          ),
        ] else if (state == AppUpdateState.ready ||
            state == AppUpdateState.installPermissionRequired) ...[
          Text(
            state == AppUpdateState.installPermissionRequired
                ? '请在系统设置中允许本应用安装更新，返回后继续安装。'
                : '下载已完成，可以安装新版本。',
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _service.installUpdate,
            child: Text(
              state == AppUpdateState.installPermissionRequired
                  ? '允许安装更新'
                  : '安装新版本',
            ),
          ),
        ] else if (state == AppUpdateState.installing) ...[
          const Text('已打开系统安装器，请按提示安装。'),
        ],
        const SizedBox(height: 8),
        if (failed && release == null)
          OutlinedButton(onPressed: _checkManually, child: const Text('重新检查')),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(downloading ? '取消并关闭' : '关闭'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _service,
    builder: (_, _) => Badge(
      isLabelVisible:
          _service.state == AppUpdateState.available ||
          _service.state == AppUpdateState.ready,
      label: const Text('新'),
      child: TextButton.icon(
        key: const Key('check-app-update'),
        style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: () => _showUpdateSheet(
          check: const [
            AppUpdateState.idle,
            AppUpdateState.upToDate,
            AppUpdateState.failed,
            AppUpdateState.unsupported,
          ].contains(_service.state),
        ),
        icon: const Icon(Icons.system_update_alt),
        label: const Text('检查更新'),
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.service == null) _service.dispose();
    super.dispose();
  }
}
