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
  final VoidCallback? onReplay;
  final VoidCallback? onDismissTranslation;

  static String _speedLabel(double speed) => '${speed.toStringAsFixed(1)}x';

  void _cycleSpeed() {
    final speeds = AudioPlayerService.supportedSpeeds;
    final index = speeds.indexOf(currentSpeed);
    onSpeedChanged?.call(speeds[(index + 1) % speeds.length]);
  }

  Future<void> _chooseSpeed(BuildContext context) async {
    var selected = false;
    final speed = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
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
                      '选择播放语速',
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
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ListTile(
                    key: ValueKey('speed-option-${_speedLabel(value)}'),
                    title: Text(
                      _speedLabel(value),
                      semanticsLabel:
                          '播放语速 ${_speedLabel(value)}${value == currentSpeed ? '，当前选中' : ''}',
                    ),
                    selected: value == currentSpeed,
                    selectedTileColor: Theme.of(sheetContext)
                        .colorScheme
                        .secondaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    trailing: value == currentSpeed
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () {
                      if (selected) return;
                      selected = true;
                      Navigator.pop(sheetContext, value);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
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
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () => onModeChanged(
                      currentMode == PlayMode.single
                          ? PlayMode.continuous
                          : PlayMode.single,
                    ),
                    icon: Icon(
                      currentMode == PlayMode.single
                          ? Icons.play_arrow
                          : Icons.playlist_play,
                    ),
                    label: Text(
                      currentMode == PlayMode.single ? '单句点读' : '整页连读',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                  final speedButton = Tooltip(
                    message: '语速 ${_speedLabel(currentSpeed)}，点击切换下一档；长按选择语速',
                    child: TextButton(
                      key: const Key('playback-speed'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onSpeedChanged == null ? null : _cycleSpeed,
                      onLongPress: onSpeedChanged == null
                          ? null
                          : () => _chooseSpeed(context),
                      child: Text(
                        _speedLabel(currentSpeed),
                        semanticsLabel:
                            '播放语速 ${_speedLabel(currentSpeed)}，点击切换下一档，长按选择语速',
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
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(14) > 18;
                  if (constraints.maxWidth < 340 || largeText) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        modeButton,
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
