import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../services/audio_player_service.dart';
import '../services/learning_controller.dart';
import '../widgets/app_update_entry.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.controller,
    this.updateService,
    this.bottomContentPadding = 100,
  });

  final LearningController controller;
  final AppUpdateService? updateService;
  final double bottomContentPadding;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final AppUpdateService _updates =
      widget.updateService ?? AppUpdateService();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(widget.controller.initialize());
    }
  }

  Future<void> _save(Future<void> Function() operation) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能保存，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseSpeed() async {
    final current = widget.controller.currentSpeed;
    var selected = false;
    final speed = await showModalBottomSheet<double>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '点读发音语速',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭语速选择',
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final value in AudioPlayerService.supportedSpeeds)
                ListTile(
                  key: ValueKey('profile-speed-option-$value'),
                  minVerticalPadding: 12,
                  title: Text('${value.toStringAsFixed(1)}x'),
                  subtitle: value == 1.0 ? const Text('标准语速') : null,
                  selected: value == current,
                  selectedTileColor: Theme.of(sheetContext)
                      .colorScheme
                      .secondaryContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  trailing: value == current ? const Icon(Icons.check) : null,
                  onTap: () {
                    if (selected) return;
                    selected = true;
                    Navigator.pop(sheetContext, value);
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (mounted && speed != null) {
      await _save(() => widget.controller.setSpeed(speed));
    }
  }

  Future<void> _showAbout() async {
    await _updates.initialize();
    if (!mounted) return;
    final installed = _updates.installedApp;
    final version = installed == null
        ? '当前环境无法读取已安装版本'
        : '版本 ${installed.versionName}（构建 ${installed.buildNumber}）';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('关于小学英语点读'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(version, key: const Key('profile-version')),
            const SizedBox(height: 16),
            const Text('看课本、听发音，按自己的节奏学习英语。'),
            const SizedBox(height: 16),
            const Text(
              '原创应用代码采用 MIT 许可证。教材图文、离线音频等资源的内容相关权利归相应权利人所有，不属于 MIT 授权范围。',
            ),
            const SizedBox(height: 12),
            const Text('第三方依赖适用各自许可证。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(
              context: dialogContext,
              applicationName: '小学英语点读',
              applicationVersion: installed?.versionName,
            ),
            child: const Text('开源许可'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final controller = widget.controller;
      final enabled = controller.initialized && !_saving;
      return SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const Key('profile-scroll'),
          padding: EdgeInsets.fromLTRB(
            24,
            28,
            24,
            widget.bottomContentPadding + MediaQuery.paddingOf(context).bottom,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '我的',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '每次点读，都是一点进步。',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text('学习记录', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 36,
                    runSpacing: 20,
                    children: [
                      _LearningCount(
                        count: controller.statisticsAvailable
                            ? '${controller.readingDays}'
                            : '—',
                        label: '累计点读天数',
                        unit: '天',
                        valueKey: const Key('profile-reading-days'),
                      ),
                      _LearningCount(
                        count: controller.statisticsAvailable
                            ? '${controller.readingBooks}'
                            : '—',
                        label: '点读书籍数',
                        unit: '本',
                        valueKey: const Key('profile-reading-books'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '播放课本发音后记录，学习记录仅保存在这台设备上。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (controller.errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      controller.errorMessage!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.error,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _save(controller.refresh),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  Text('学习设置', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Material(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          key: const Key('profile-eye-reminder'),
                          minVerticalPadding: 16,
                          leading: Icon(
                            Icons.visibility_outlined,
                            color: colors.primary,
                          ),
                          title: const Text('护眼提醒'),
                          subtitle: const Text('每 20 分钟提醒休息'),
                          trailing: Switch(
                            value: controller.eyeReminderEnabled,
                            onChanged: enabled
                                ? (value) => _save(
                                    () =>
                                        controller.setEyeReminderEnabled(value),
                                  )
                                : null,
                          ),
                          onTap: enabled
                              ? () => _save(
                                  () => controller.setEyeReminderEnabled(
                                    !controller.eyeReminderEnabled,
                                  ),
                                )
                              : null,
                        ),
                        Divider(
                          height: 1,
                          indent: 20,
                          endIndent: 20,
                          color: colors.outlineVariant,
                        ),
                        ListTile(
                          key: const Key('profile-speed'),
                          minVerticalPadding: 16,
                          leading: Icon(Icons.speed, color: colors.primary),
                          title: const Text('点读发音语速'),
                          subtitle: Text(
                            '${controller.currentSpeed.toStringAsFixed(1)}x · '
                            '用于下次打开的课本',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: enabled ? _chooseSpeed : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  Material(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(
                      key: const Key('profile-about'),
                      minVerticalPadding: 16,
                      leading: Icon(Icons.info_outline, color: colors.primary),
                      title: const Text('关于小学英语点读'),
                      subtitle: const Text('版本信息与版权声明'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _showAbout,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppUpdateEntry(service: _updates),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    if (widget.updateService == null) _updates.dispose();
    super.dispose();
  }
}

class _LearningCount extends StatelessWidget {
  const _LearningCount({
    required this.count,
    required this.label,
    required this.unit,
    required this.valueKey,
  });

  final String count;
  final String label;
  final String unit;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$count $unit',
          key: valueKey,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
