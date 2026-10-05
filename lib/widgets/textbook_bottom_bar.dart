import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../services/audio_player_service.dart';

class TextbookBottomBar extends StatelessWidget {
  const TextbookBottomBar({
    super.key,
    required this.currentMode,
    required this.onModeChanged,
    required this.isTranslationEnabled,
    required this.onTranslationChanged,
    required this.activeSentence,
    this.activeBubble,
    this.currentSpeed = 1.0,
    this.onSpeedChanged,
    this.isPlaying = false,
    this.canResume = false,
    this.isLoading = false,
    this.onPlaybackToggle,
    this.onReplay,
    this.onDismissTranslation,
  });

  final PlayMode currentMode;
  final ValueChanged<PlayMode> onModeChanged;
  final bool isTranslationEnabled;
  final ValueChanged<bool> onTranslationChanged;
  final PointSentence? activeSentence;
  final DialogueBubble? activeBubble;
  final double currentSpeed;
  final ValueChanged<double>? onSpeedChanged;
  final bool isPlaying;
  final bool canResume;
  final bool isLoading;
  final VoidCallback? onPlaybackToggle;
  final VoidCallback? onReplay;
  final VoidCallback? onDismissTranslation;

  static String _speedLabel(double speed) => '${speed.toStringAsFixed(1)}x';

  static String _modeLabel(PlayMode mode) => switch (mode) {
    PlayMode.single => '单句点读',
    PlayMode.fullPage => '整页连读',
    PlayMode.sequential => '顺序连读',
  };

  static String _modeDescription(PlayMode mode) => switch (mode) {
    PlayMode.single => '点击任意句子独立朗读，适合精读练习',
    PlayMode.fullPage => '从当前页第一句开始，完整朗读至末尾',
    PlayMode.sequential => '点击任意句子作为起点，顺次连续向后朗读',
  };

  static IconData _modeIcon(PlayMode mode) => switch (mode) {
    PlayMode.single => Icons.touch_app_outlined,
    PlayMode.fullPage => Icons.playlist_play,
    PlayMode.sequential => Icons.format_list_numbered,
  };

  static String _speedDescription(double speed) => switch (speed) {
    0.5 => '慢速跟读',
    0.8 => '清晰磨耳朵',
    1.0 => '标准语速',
    1.2 => '稍快复习',
    1.5 => '快速听力',
    2.0 => '极速浏览',
    _ => '',
  };

  Future<T?> _showSelectionSheet<T>(
    BuildContext context, {
    required String title,
    required String closeLabel,
    required T currentValue,
    required List<_SelectionOption<T>> options,
  }) {
    var dismissed = false;
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: closeLabel,
                    onPressed: () {
                      if (dismissed ||
                          ModalRoute.of(sheetContext)?.isCurrent != true) {
                        return;
                      }
                      dismissed = true;
                      Navigator.pop(sheetContext);
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final option in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    key: option.key,
                    minTileHeight: 48,
                    minVerticalPadding: 12,
                    title: Text(
                      option.label,
                      semanticsLabel:
                          '${option.semanticLabel}'
                          '${option.value == currentValue ? '，当前选中' : ''}',
                    ),
                    subtitle: Text(option.description),
                    selected: option.value == currentValue,
                    selectedColor: Theme.of(sheetContext).colorScheme.primary,
                    selectedTileColor: Theme.of(sheetContext)
                        .colorScheme
                        .secondaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    trailing: option.value == currentValue
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () {
                      if (dismissed ||
                          ModalRoute.of(sheetContext)?.isCurrent != true) {
                        return;
                      }
                      dismissed = true;
                      Navigator.pop(sheetContext, option.value);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseMode(BuildContext context) async {
    final mode = await _showSelectionSheet<PlayMode>(
      context,
      title: '选择点读模式',
      closeLabel: '关闭模式选择',
      currentValue: currentMode,
      options: [
        for (final mode in PlayMode.values)
          _SelectionOption(
            value: mode,
            key: ValueKey('mode-option-${mode.name}'),
            label: _modeLabel(mode),
            semanticLabel: '点读模式 ${_modeLabel(mode)}',
            description: _modeDescription(mode),
          ),
      ],
    );
    if (context.mounted && mode != null && mode != currentMode) {
      onModeChanged(mode);
    }
  }

  Future<void> _chooseSpeed(BuildContext context) async {
    final speed = await _showSelectionSheet<double>(
      context,
      title: '选择播放语速',
      closeLabel: '关闭语速选择',
      currentValue: currentSpeed,
      options: [
        for (final speed in AudioPlayerService.supportedSpeeds)
          _SelectionOption(
            value: speed,
            key: ValueKey('speed-option-${_speedLabel(speed)}'),
            label: _speedLabel(speed),
            semanticLabel: '播放语速 ${_speedLabel(speed)}',
            description: _speedDescription(speed),
          ),
      ],
    );
    if (context.mounted && speed != null && speed != currentSpeed) {
      onSpeedChanged?.call(speed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeText = activeBubble?.text ?? activeSentence?.text;
    final translation =
        activeBubble?.translation ?? activeSentence?.translation;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isTranslationEnabled && activeText != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Material(
                color: colors.secondaryContainer,
                borderRadius: BorderRadius.circular(14),
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              activeText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              translation?.trim().isNotEmpty == true
                                  ? translation!.trim()
                                  : '暂无释义',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '重听',
                        onPressed: onReplay,
                        icon: const Icon(Icons.replay),
                      ),
                      IconButton(
                        tooltip: '关闭释义',
                        onPressed: onDismissTranslation,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Material(
            color: colors.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final modeButton = OutlinedButton.icon(
                    key: const Key('playback-mode'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () => _chooseMode(context),
                    icon: Icon(_modeIcon(currentMode)),
                    label: Text(
                      _modeLabel(currentMode),
                      semanticsLabel: '播放模式 ${_modeLabel(currentMode)}，点击选择模式',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                  final speedButton = Tooltip(
                    message: '语速 ${_speedLabel(currentSpeed)}，点击选择语速',
                    child: TextButton(
                      key: const Key('playback-speed'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onSpeedChanged == null
                          ? null
                          : () => _chooseSpeed(context),
                      onLongPress: onSpeedChanged == null
                          ? null
                          : () => _chooseSpeed(context),
                      child: Text(
                        _speedLabel(currentSpeed),
                        semanticsLabel:
                            '播放语速 ${_speedLabel(currentSpeed)}，点击选择语速',
                      ),
                    ),
                  );
                  final translationButton = IconButton.filledTonal(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: isTranslationEnabled ? '关闭释义' : '开启释义',
                    onPressed: () =>
                        onTranslationChanged(!isTranslationEnabled),
                    icon: Icon(
                      isTranslationEnabled
                          ? Icons.translate
                          : Icons.translate_outlined,
                    ),
                  );
                  final microphoneButton = IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: '跟读评测',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('功能正在开发中，敬请期待')),
                      );
                    },
                    icon: const Icon(Icons.mic),
                  );
                  final showPlayback = currentMode != PlayMode.single;
                  final showPause = isPlaying || isLoading;
                  final playbackEnabled =
                      onPlaybackToggle != null && (showPause || canResume);
                  final playbackButton = Semantics(
                    label: showPause ? '暂停连读' : '播放连读',
                    button: true,
                    enabled: playbackEnabled,
                    excludeSemantics: true,
                    onTap: playbackEnabled ? onPlaybackToggle : null,
                    hint: !playbackEnabled && currentMode == PlayMode.sequential
                        ? '点击任意句子开始顺序连读'
                        : null,
                    child: SizedBox.square(
                      dimension: 56,
                      child: IconButton(
                        key: const Key('playback-toggle'),
                        tooltip: showPause ? '暂停连读' : '播放连读',
                        iconSize: 48,
                        padding: EdgeInsets.zero,
                        color: colors.primary,
                        onPressed: playbackEnabled ? onPlaybackToggle : null,
                        icon: Icon(
                          showPause
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                        ),
                      ),
                    ),
                  );
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(14) > 18;
                  if (constraints.maxWidth < (showPlayback ? 440 : 340) ||
                      largeText) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(child: modeButton),
                            if (showPlayback) ...[
                              const SizedBox(width: 8),
                              playbackButton,
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: speedButton),
                            const SizedBox(width: 8),
                            translationButton,
                            const SizedBox(width: 8),
                            microphoneButton,
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: modeButton),
                      if (showPlayback) ...[
                        const SizedBox(width: 8),
                        playbackButton,
                      ],
                      const SizedBox(width: 8),
                      speedButton,
                      const SizedBox(width: 8),
                      translationButton,
                      const SizedBox(width: 8),
                      microphoneButton,
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionOption<T> {
  const _SelectionOption({
    required this.value,
    required this.key,
    required this.label,
    required this.semanticLabel,
    required this.description,
  });

  final T value;
  final Key key;
  final String label;
  final String semanticLabel;
  final String description;
}
