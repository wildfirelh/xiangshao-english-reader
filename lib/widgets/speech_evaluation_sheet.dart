import 'dart:async';

import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../services/speech_evaluator.dart';

enum _RecordingStage { preparing, ready, starting, recording, evaluating }

/// A single follow-along attempt. The parent owns and disposes [evaluator].
class SpeechEvaluationSheet extends StatefulWidget {
  const SpeechEvaluationSheet({
    super.key,
    required this.sentence,
    required this.evaluator,
    required this.onPlayReference,
    required this.onPlayRecording,
    this.onStopPlayback,
  });

  final PointSentence sentence;
  final SpeechEvaluator evaluator;
  final Future<void> Function() onPlayReference;
  final Future<void> Function(String path) onPlayRecording;
  final Future<void> Function()? onStopPlayback;

  @override
  State<SpeechEvaluationSheet> createState() => _SpeechEvaluationSheetState();
}

class _SpeechEvaluationSheetState extends State<SpeechEvaluationSheet>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  _RecordingStage _stage = _RecordingStage.preparing;
  EvaluationResult? _result;
  String? _error;
  bool _permanentlyDenied = false;
  bool _prepared = false;
  bool _auditionBusy = false;
  bool _closed = false;
  int _generation = 0;
  int _elapsedSeconds = 0;
  RecordingStopReason? _pendingAutoStop;
  Timer? _elapsedTimer;
  StreamSubscription<double>? _amplitudeSubscription;
  StreamSubscription<RecordingStopReason>? _autoStopSubscription;
  final _scrollController = ScrollController();
  final List<double> _wave = List.filled(23, 0.04, growable: true);
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  bool get _recording => _stage == _RecordingStage.recording;
  bool get _busy =>
      _stage == _RecordingStage.preparing ||
      _stage == _RecordingStage.starting ||
      _stage == _RecordingStage.evaluating;
  bool _isCurrent(int generation) =>
      mounted && !_closed && generation == _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _amplitudeSubscription = widget.evaluator.amplitudes.listen(
      (value) {
        if (!_recording || !mounted || _closed) return;
        setState(() {
          _wave.removeAt(0);
          _wave.add(value.isFinite ? value.clamp(0.04, 1.0) : 0.04);
        });
      },
      onError: (Object error) {
        if (_recording) _abortWithError('无法读取麦克风，请重新开始录音');
      },
    );
    _autoStopSubscription = widget.evaluator.recordingStops.listen(
      (reason) {
        if (_stage == _RecordingStage.starting) {
          _pendingAutoStop = reason;
        } else if (_recording) {
          unawaited(_evaluate());
        }
      },
      onError: (Object error) {
        if (_recording || _stage == _RecordingStage.starting) {
          _abortWithError(
            error is SpeechEvaluationException ? error.message : '录音中断，请再读一次',
          );
        }
      },
    );
    unawaited(_prepare());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updatePulse();
  }

  void _updatePulse() {
    if (_recording && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _stage = _RecordingStage.preparing;
        _error = null;
        _permanentlyDenied = false;
      });
    }
    try {
      await widget.evaluator.prepare();
      if (!_isCurrent(generation)) return;
      setState(() {
        _prepared = true;
        _stage = _RecordingStage.ready;
      });
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _showError(error);
    }
  }

  void _showError(Object error) {
    setState(() {
      _stage = _RecordingStage.ready;
      _error = error is SpeechEvaluationException
          ? error.message
          : '暂时无法完成跟读，请再试一次';
      _permanentlyDenied =
          error is SpeechEvaluationException && error.permanentlyDenied;
    });
    _updatePulse();
  }

  Future<void> _stopPlayback() async => widget.onStopPlayback?.call();

  Future<void> _startRecording() async {
    if (_busy || _recording || _auditionBusy || _closed) return;
    if (!_prepared) {
      await _prepare();
      if (!_prepared || _closed || !mounted) return;
    }
    final generation = ++_generation;
    setState(() {
      _stage = _RecordingStage.starting;
      _result = null;
      _error = null;
      _permanentlyDenied = false;
      _elapsedSeconds = 0;
      _pendingAutoStop = null;
      _wave.fillRange(0, _wave.length, 0.04);
    });
    try {
      await _stopPlayback();
      if (!_isCurrent(generation)) return;
      await widget.evaluator.startRecording(widget.sentence.id);
      if (!_isCurrent(generation)) return;
      setState(() => _stage = _RecordingStage.recording);
      _updatePulse();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_recording || !_isCurrent(generation)) return;
        setState(() => _elapsedSeconds++);
        if (_elapsedSeconds >= 15) unawaited(_evaluate());
      });
      if (_pendingAutoStop != null) {
        _pendingAutoStop = null;
        unawaited(_evaluate());
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      widget.evaluator.cancel();
      _showError(error);
    }
  }

  Future<void> _evaluate() async {
    if (!_recording || _closed) return;
    final generation = _generation;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    setState(() => _stage = _RecordingStage.evaluating);
    _updatePulse();
    try {
      final result = await widget.evaluator.stopAndEvaluate(
        widget.sentence.id,
        widget.sentence.text,
      );
      if (!_isCurrent(generation)) return;
      setState(() {
        _result = result;
        _stage = _RecordingStage.ready;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrent(generation) || !_scrollController.hasClients) return;
        if (MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(0);
        } else {
          unawaited(
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      });
    } catch (error) {
      if (!_isCurrent(generation)) return;
      widget.evaluator.cancel();
      _showError(error);
    }
  }

  void _abortWithError(String message) {
    if (!mounted || _closed) return;
    _generation++;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _pendingAutoStop = null;
    widget.evaluator.cancel();
    setState(() {
      _stage = _RecordingStage.ready;
      _error = message;
    });
    _updatePulse();
  }

  Future<void> _play({String? recordingPath}) async {
    if (_recording || _busy || _auditionBusy || _closed) return;
    final generation = _generation;
    setState(() {
      _auditionBusy = true;
      _error = null;
    });
    try {
      await _stopPlayback();
      if (!_isCurrent(generation)) return;
      if (recordingPath == null) {
        await widget.onPlayReference();
      } else {
        await widget.onPlayRecording(recordingPath);
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        setState(() => _error = '音频暂时无法播放，请重新试听');
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _auditionBusy = false);
    }
  }

  Future<void> _openSettings() async {
    try {
      await widget.evaluator.openPermissionSettings();
    } catch (_) {
      if (mounted && !_closed) {
        setState(() => _error = '请在手机设置中开启本应用的麦克风权限');
      }
    }
  }

  void _cancelForDismissal() {
    if (_closed) return;
    _closed = true;
    _generation++;
    widget.evaluator.cancel();
    _elapsedTimer?.cancel();
    _pulse.stop();
    unawaited(_stopPlayback().catchError((Object _) {}));
  }

  void _close() {
    if (_closed) return;
    _cancelForDismissal();
    Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android's microphone permission dialog can temporarily remove focus
    // without putting the activity in the background.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      return;
    }
    if (_recording ||
        _stage == _RecordingStage.starting ||
        _stage == _RecordingStage.evaluating) {
      _abortWithError('录音已暂停，请再读一次');
    }
    if (_auditionBusy && mounted && !_closed) {
      _generation++;
      setState(() => _auditionBusy = false);
    }
    unawaited(_stopPlayback().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    widget.evaluator.cancel();
    _elapsedTimer?.cancel();
    unawaited(_amplitudeSubscription?.cancel());
    unawaited(_autoStopSubscription?.cancel());
    // A playback service can notify the ancestor reader. Defer that callback
    // until Flutter has finished unmounting the sheet and its widget tree.
    unawaited(Future<void>.microtask(_stopPlayback).catchError((Object _) {}));
    _pulse.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Color _wordColor(ScoreStatus status) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (status) {
      ScoreStatus.correct =>
        dark ? const Color(0xFF8FDB9B) : const Color(0xFF267D3F),
      ScoreStatus.warning =>
        dark ? const Color(0xFFFFC764) : const Color(0xFF986100),
      ScoreStatus.error =>
        dark ? const Color(0xFFFF9995) : const Color(0xFFB83232),
    };
  }

  String _wordLabel(ScoreStatus status) => switch (status) {
    ScoreStatus.correct => '已匹配',
    ScoreStatus.warning => '再清晰一点',
    ScoreStatus.error => '需要练习',
  };

  Widget _sentenceCard() {
    final colors = Theme.of(context).colorScheme;
    final words = _result?.words ?? const <WordEvaluation>[];
    return Container(
      key: const Key('speech-reference-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            words.isEmpty ? '跟着原句读一遍' : '点红色单词，重听原句',
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          if (words.isEmpty)
            Text(
              widget.sentence.text,
              key: const Key('speech-reference-text'),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.45),
            )
          else
            Wrap(
              spacing: 5,
              runSpacing: 6,
              children: [
                for (var index = 0; index < words.length; index++)
                  _wordTile(words[index], index),
              ],
            ),
          if (widget.sentence.translation?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Text(
              widget.sentence.translation!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _wordTile(WordEvaluation word, int index) {
    final color = _wordColor(word.status);
    final canReplay =
        word.status == ScoreStatus.error && !_busy && !_auditionBusy;
    return Semantics(
      label: '${word.word}，${_wordLabel(word.status)}',
      hint: word.status == ScoreStatus.error ? '点击重听原句' : null,
      button: word.status == ScoreStatus.error,
      excludeSemantics: true,
      child: Material(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('speech-word-$index-${word.status.name}'),
          borderRadius: BorderRadius.circular(8),
          onTap: canReplay ? () => unawaited(_play()) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: Text(
                word.word,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _scoreResult(EvaluationResult result) {
    final colors = Theme.of(context).colorScheme;
    final label = result.score >= 90
        ? 'Awesome!'
        : result.score >= 60
        ? 'Good Job!'
        : 'Keep Trying!';
    final status = result.score >= 85
        ? ScoreStatus.correct
        : result.score >= 50
        ? ScoreStatus.warning
        : ScoreStatus.error;
    return Semantics(
      liveRegion: true,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Container(
            key: const Key('speech-score'),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: _wordColor(status).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                Text(
                  '${result.score} 分',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: _wordColor(status),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('跟读匹配分', style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final status in ScoreStatus.values)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: _wordColor(status)),
                    const SizedBox(width: 5),
                    Text(
                      _wordLabel(status),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
            ],
          ),
          if (!result.hasNativeConfidence) ...[
            const SizedBox(height: 10),
            Text(
              '根据识别文本与完整度反馈',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (result.recognizedText.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '识别到：${result.recognizedText}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recorder() {
    final colors = Theme.of(context).colorScheme;
    final status = switch (_stage) {
      _RecordingStage.preparing => '正在准备离线跟读…',
      _RecordingStage.starting => '正在开启麦克风…',
      _RecordingStage.recording => '正在录音 · $_elapsedSeconds / 15 秒',
      _RecordingStage.evaluating => '正在听你的发音…',
      _RecordingStage.ready => _result == null ? '点击麦克风，开始跟读' : '再练一次，会更熟练',
    };
    return Column(
      children: [
        const SizedBox(height: 16),
        if (_recording)
          SizedBox(
            height: 54,
            child: Semantics(
              label: '实时录音声浪',
              child: Row(
                key: const Key('speech-waveform'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < _wave.length; index++)
                    Flexible(
                      child: Container(
                        key: ValueKey('speech-wave-$index'),
                        height: 4 + _wave[index] * 46,
                        width: 5,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) => Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _recording
                  ? colors.primary.withValues(alpha: 0.05 + _pulse.value * 0.09)
                  : Colors.transparent,
            ),
            child: child,
          ),
          child: Semantics(
            label: _recording ? '停止录音并评分' : '开始跟读录音',
            button: true,
            enabled: !_busy && !_auditionBusy,
            excludeSemantics: true,
            child: FilledButton(
              key: const Key('speech-record-button'),
              onPressed: _busy || _auditionBusy
                  ? null
                  : () =>
                        unawaited(_recording ? _evaluate() : _startRecording()),
              style: FilledButton.styleFrom(
                fixedSize: const Size(88, 88),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: _busy
                  ? SizedBox.square(
                      dimension: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  : Icon(_recording ? Icons.stop_rounded : Icons.mic, size: 36),
            ),
          ),
        ),
        Semantics(
          liveRegion: true,
          child: Text(
            status,
            key: const Key('speech-recording-status'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (_recording) ...[
          const SizedBox(height: 5),
          Text(
            '停顿 1.5 秒会自动结束，也可点击停止',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _auditionButtons() {
    final recordingPath =
        _result?.recordingPath ?? widget.evaluator.recordingPath;
    final enabled = !_busy && !_recording && !_auditionBusy;
    final reference = OutlinedButton.icon(
      key: const Key('speech-reference-button'),
      onPressed: enabled ? () => unawaited(_play()) : null,
      icon: const Icon(Icons.volume_up_outlined),
      label: const Text('A · 听标准音'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
    );
    final own = OutlinedButton.icon(
      key: const Key('speech-recording-button'),
      onPressed: enabled && recordingPath?.isNotEmpty == true
          ? () => unawaited(_play(recordingPath: recordingPath))
          : null,
      icon: const Icon(Icons.headphones_outlined),
      label: const Text('B · 听我的录音'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 340 ||
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [reference, const SizedBox(height: 8), own],
          );
        }
        return Row(
          children: [
            Expanded(child: reference),
            const SizedBox(width: 10),
            Expanded(child: own),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelForDismissal();
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.90,
        ),
        child: Material(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              key: const Key('speech-sheet-scroll'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '跟读练习',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: const Key('speech-close'),
                        tooltip: '关闭跟读练习',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: _close,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sentenceCard(),
                  if (_result case final result?) _scoreResult(result),
                  _recorder(),
                  if (_error case final error?) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        key: const Key('speech-error'),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              error,
                              style: TextStyle(color: colors.onErrorContainer),
                            ),
                            if (_permanentlyDenied)
                              TextButton.icon(
                                key: const Key('speech-open-settings'),
                                onPressed: () => unawaited(_openSettings()),
                                icon: const Icon(Icons.settings_outlined),
                                label: const Text('去设置开启麦克风'),
                              ),
                            if (!_prepared)
                              TextButton(
                                key: const Key('speech-retry-prepare'),
                                onPressed: () => unawaited(_prepare()),
                                child: const Text('重新准备'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _auditionButtons(),
                  if (_result != null) ...[
                    const SizedBox(height: 18),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          key: const Key('speech-retry'),
                          onPressed: _busy || _auditionBusy
                              ? null
                              : () => unawaited(_startRecording()),
                          icon: const Icon(Icons.refresh),
                          label: const Text('再读一次'),
                        ),
                        FilledButton(
                          key: const Key('speech-finish-button'),
                          onPressed: _close,
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
