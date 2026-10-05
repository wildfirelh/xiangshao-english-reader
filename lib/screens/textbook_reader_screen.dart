import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../models/textbook_unit.dart';
import '../services/audio_player_service.dart';
import '../services/learning_controller.dart';
import '../services/reading_progress_store.dart';
import '../widgets/interactive_textbook_page.dart';
import '../widgets/textbook_bottom_bar.dart';

class TextbookReaderScreen extends StatefulWidget {
  const TextbookReaderScreen({
    super.key,
    required this.book,
    this.audioPlayerService,
    this.progressStore,
    this.initialPageIndex,
    this.units,
    this.firstPageIndex,
    this.onPointRead,
    this.learningController,
    this.eyeReminderInterval = const Duration(minutes: 20),
  });

  final Textbook book;
  final AudioPlayerService? audioPlayerService;
  final ReadingProgressStore? progressStore;
  final List<TextbookUnit>? units;
  final int? firstPageIndex;
  final Future<void> Function()? onPointRead;
  final LearningController? learningController;
  final Duration eyeReminderInterval;

  /// Physical PDF page; an explicit unit selection takes priority over progress.
  final int? initialPageIndex;

  @override
  State<TextbookReaderScreen> createState() => _TextbookReaderScreenState();
}

class _TextbookReaderScreenState extends State<TextbookReaderScreen>
    with WidgetsBindingObserver {
  static const _mockPage = TextbookPage(
    pageIndex: 1,
    imagePath: '',
    sentences: [
      PointSentence(
        id: 'mock_hello',
        text: 'Hello! My name is Lingling.',
        translation: '你好！我叫玲玲。',
        audioPath: '',
        rect: NormalizedRect(left: 0.11, top: 0.26, right: 0.89, bottom: 0.35),
      ),
      PointSentence(
        id: 'mock_greeting',
        text: 'Nice to meet you.',
        translation: '很高兴认识你。',
        audioPath: '',
        rect: NormalizedRect(left: 0.11, top: 0.42, right: 0.89, bottom: 0.51),
      ),
    ],
  );

  late final List<TextbookPage> _pages = widget.book.pages.isEmpty
      ? const [_mockPage]
      : widget.book.pages;
  late final AudioPlayerService _audio =
      widget.audioPlayerService ?? AudioPlayerService();
  late final bool _ownsAudio = widget.audioPlayerService == null;
  PageController? _pageController;
  late final ReadingProgressStore _progress =
      widget.progressStore ?? SharedPreferencesReadingProgressStore.instance;
  bool _restoring = true;
  bool _saveErrorShown = false;
  StreamSubscription<PagePlaybackCompletion>? _completionSubscription;
  StreamSubscription<void>? _readingSubscription;
  Timer? _eyeReminderTimer;
  bool _isForeground = true;
  bool? _reminderWanted;
  PagePlaybackCompletion? _autoCompletion;
  int? _autoTarget;
  int? _pausedAutoTarget;
  final _pageKeys = <int, GlobalKey<InteractiveTextbookPageState>>{};
  bool _handledScrollingTap = false;
  PointSentence? _scrollTapSentence;
  int? _scrollTapPage;
  int? _scrollTapPointer;
  Offset? _scrollTapPosition;
  int? _pagePointer;
  Offset? _pagePointerDownPosition;
  bool _manualDragStopped = false;

  int _pageIndex = 0;
  bool _isTranslationEnabled = true;
  PointSentence? _previewSentence;
  String? _dismissedTranslationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (lifecycle != null) {
      _audio.setForeground(lifecycle == AppLifecycleState.resumed);
    }
    _audio.addListener(_onAudioChanged);
    _completionSubscription = _audio.pageCompletions.listen(
      (completion) => unawaited(_advanceAfterPage(completion)),
    );
    _readingSubscription = _audio.playbackStarts.listen(
      (_) => unawaited(_recordPointRead()),
    );
    widget.learningController?.addListener(_configureEyeReminder);
    _configureEyeReminder();
    unawaited(_restoreProgress());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    _configureEyeReminder();
    if (state != AppLifecycleState.resumed) {
      _pausedAutoTarget = _autoTarget ?? _pausedAutoTarget;
      _cancelAutoAdvance(settlePage: true, clearPaused: false);
    }
    _audio.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> _recordPointRead() async {
    try {
      if (widget.onPointRead case final record?) {
        await record();
      } else {
        await widget.learningController?.recordPointRead(widget.book.bookId);
      }
    } catch (error) {
      // A statistics write failure must not interrupt textbook audio.
      debugPrint('Unable to save learning statistics: $error');
    }
  }

  void _configureEyeReminder() {
    final preferences = widget.learningController;
    final wanted =
        _isForeground &&
        preferences != null &&
        preferences.initialized &&
        preferences.eyeReminderEnabled;
    if (wanted == _reminderWanted) return;
    _reminderWanted = wanted;
    _eyeReminderTimer?.cancel();
    _eyeReminderTimer = null;
    if (!wanted || widget.eyeReminderInterval <= Duration.zero) return;
    _eyeReminderTimer = Timer.periodic(widget.eyeReminderInterval, (_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已经学习一会儿了，休息一下，看看远处吧。')));
    });
  }

  Future<void> _restoreProgress() async {
    int? saved = widget.initialPageIndex;
    try {
      saved ??= await _progress.load(widget.book.bookId);
    } catch (error) {
      debugPrint('Unable to restore reading progress: $error');
    }
    if (!mounted) return;
    final index = _pages.indexWhere((page) => page.pageIndex == saved);
    setState(() {
      _pageIndex = index < 0 ? 0 : index;
      _pageController = PageController(initialPage: _pageIndex);
      _restoring = false;
    });
    if (widget.initialPageIndex != null && index >= 0) {
      unawaited(_saveProgress(index));
    }
  }

  Future<void> _saveProgress(int index) async {
    if (widget.book.pages.isEmpty) return;
    try {
      await _progress.save(widget.book.bookId, _pages[index].pageIndex);
    } catch (error) {
      debugPrint('Unable to save reading progress: $error');
      if (!mounted || _saveErrorShown) return;
      _saveErrorShown = true;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('阅读进度暂时无法保存')));
    }
  }

  void _onAudioChanged() {
    if (_audio.isPaused && _autoTarget != null) {
      _pausedAutoTarget = _autoTarget;
      _cancelAutoAdvance(settlePage: true, clearPaused: false);
    }
    if (mounted) setState(() {});
  }

  int _printedPageFor(TextbookUnit unit) {
    if (widget.firstPageIndex case final first?) {
      return unit.startPage - first + 1;
    }
    return widget.units == null ? unit.printedPage : unit.startPage;
  }

  PointSentence? get _activeSentence {
    if (_audio.currentBubbleId != null) return null;
    final id = _audio.currentSentenceId ?? _previewSentence?.id;
    if (id == null) return null;
    for (final sentence in _pages[_pageIndex].sentences) {
      if (sentence.id == id) return sentence;
    }
    return null;
  }

  DialogueBubble? get _activeBubble {
    final id = _audio.currentBubbleId;
    if (id == null) return null;
    for (final bubble in _pages[_pageIndex].playbackBubbles) {
      if (bubble.id == id) return bubble;
    }
    return null;
  }

  void _onPageChanged(int index) {
    if (index == _pageIndex) return;
    final automatic =
        _autoTarget != null &&
        index >= _pageIndex &&
        index <= _autoTarget! &&
        _autoCompletion != null &&
        _audio.canContinue(_autoCompletion!);
    if (!automatic) {
      _cancelAutoAdvance();
      unawaited(_audio.stop());
    }
    setState(() {
      _pageIndex = index;
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    unawaited(_saveProgress(index));
  }

  Future<void> _onSentenceTap(PointSentence sentence, {int? pageIndex}) async {
    // A deliberate page tap chooses a new start immediately, including while
    // a previous clip is loading or the page is turning automatically.
    final tappedPageIndex = pageIndex ?? _pageIndex;
    final pageChanged = _pageIndex != tappedPageIndex;
    final sequential = _audio.currentMode == PlayMode.sequential;
    if (sequential) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (!sequential) _audio.setPlayMode(PlayMode.single);
    _cancelAutoAdvance();
    setState(() {
      _pageIndex = tappedPageIndex;
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    if (_pageController?.hasClients == true) {
      // Settle even an ordinary previous/next-page animation to the page whose
      // hit region was tapped. Updating the index first prevents a redundant
      // navigation stop from clearing an active system audio duck.
      _pageController!.jumpToPage(tappedPageIndex);
    }
    if (pageChanged) unawaited(_saveProgress(tappedPageIndex));
    if (sentence.audioPath.isEmpty) {
      unawaited(_audio.stop());
      setState(() => _previewSentence = sentence);
      _showAudioNotice();
      return;
    }
    try {
      if (sequential) {
        await _audio.playSequential(
          page: _pages[tappedPageIndex],
          targetSentence: sentence,
        );
      } else {
        await _audio.playSentence(
          pageSentences: _pages[tappedPageIndex].sentences,
          targetSentence: sentence,
        );
      }
    } catch (_) {
      if (!mounted || _pageIndex != tappedPageIndex) return;
      setState(() => _previewSentence = sentence);
      _showAudioNotice();
    }
  }

  void _onPagePointerDown(PointerDownEvent event) {
    _pagePointer = event.pointer;
    _pagePointerDownPosition = event.position;
    _manualDragStopped = false;
    _handledScrollingTap = false;
    _scrollTapSentence = null;
    if (_pageController?.hasClients != true) return;
    final position = _pageController!.position;
    final page = _pageController!.page ?? _pageIndex.toDouble();
    // Scrollable's own down handler may already have stopped the animation.
    // A fractional page offset still identifies its ignored descendant tap.
    if (!position.isScrollingNotifier.value &&
        (page - page.round()).abs() < 0.0001) {
      return;
    }
    // A driven PageView scroll ignores descendant taps. Intercept its visible
    // sentence using the canvas's actual image geometry before settling the page.
    for (final entry in _pageKeys.entries) {
      final sentence = entry.value.currentState?.sentenceAtGlobalPosition(
        event.position,
      );
      if (sentence != null) {
        _handledScrollingTap = true;
        _scrollTapSentence = sentence;
        _scrollTapPage = entry.key;
        _scrollTapPointer = event.pointer;
        _scrollTapPosition = event.position;
        return;
      }
    }
  }

  void _onPagePointerUp(PointerUpEvent event) {
    _pagePointer = null;
    _pagePointerDownPosition = null;
    final sentence = _scrollTapSentence;
    if (sentence != null &&
        event.pointer == _scrollTapPointer &&
        (event.position - _scrollTapPosition!).distance <= kTouchSlop) {
      unawaited(_onSentenceTap(sentence, pageIndex: _scrollTapPage));
    }
    _scrollTapSentence = null;
    scheduleMicrotask(() => _handledScrollingTap = false);
  }

  void _onPagePointerMove(PointerMoveEvent event) {
    if (event.pointer == _pagePointer &&
        (event.position.dx - _pagePointerDownPosition!.dx).abs() > kTouchSlop) {
      _stopForManualPageDrag();
    }
    if (_scrollTapSentence != null &&
        event.pointer == _scrollTapPointer &&
        (event.position - _scrollTapPosition!).distance > kTouchSlop) {
      _scrollTapSentence = null;
    }
  }

  void _stopForManualPageDrag() {
    if (_manualDragStopped) return;
    _manualDragStopped = true;
    _cancelAutoAdvance();
    unawaited(_audio.stop());
    setState(() {
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
  }

  void _showAudioNotice() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('音频尚未导入，请添加教材音频')));
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    _cancelAutoAdvance();
    unawaited(_audio.stop());
    _pageController?.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _cancelAutoAdvance({bool settlePage = false, bool clearPaused = true}) {
    final wasAdvancing = _autoCompletion != null;
    _autoCompletion = null;
    _autoTarget = null;
    if (clearPaused) _pausedAutoTarget = null;
    if (settlePage && wasAdvancing && _pageController?.hasClients == true) {
      _pageController!.jumpToPage(_pageIndex);
    }
  }

  Future<void> _setPlayMode(PlayMode mode) async {
    final wasPlaying = _audio.isPlaying;
    final selected = _activeSentence ?? _firstSentenceOf(_activeBubble);
    _cancelAutoAdvance(settlePage: true);
    if (mode == PlayMode.single) {
      _audio.setPlayMode(mode);
      unawaited(_audio.stop());
      return;
    }
    if (mode == PlayMode.fullPage) {
      await _playFullPage();
      return;
    }
    // Mode selection cancels the previous queue while preserving an active duck
    // for the clip that follows immediately.
    _audio.setPlayMode(PlayMode.sequential);
    setState(() {
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    if (wasPlaying && selected != null) {
      await _playSequentialPage(targetSentence: selected);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请点击任意文本，从此处开始顺序连读')));
    }
  }

  PointSentence? _firstSentenceOf(DialogueBubble? bubble) {
    if (bubble == null) return null;
    for (final id in bubble.sentenceIds) {
      for (final sentence in _pages[_pageIndex].sentences) {
        if (sentence.id == id) return sentence;
      }
    }
    return null;
  }

  Future<void> _playFullPage({DialogueBubble? targetBubble}) async {
    final index = _pageIndex;
    final page = _pages[index];
    setState(() {
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    try {
      await _audio.playPage(page: page, targetBubble: targetBubble);
    } catch (_) {
      if (!mounted || _pageIndex != index) return;
      _showAudioNotice();
    }
  }

  Future<void> _playSequentialPage({PointSentence? targetSentence}) async {
    final index = _pageIndex;
    setState(() {
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    try {
      await _audio.playSequential(
        page: _pages[index],
        targetSentence: targetSentence,
      );
    } catch (_) {
      if (!mounted || _pageIndex != index) return;
      _showAudioNotice();
    }
  }

  Future<void> _togglePlayback() async {
    if (_audio.isPlaying || _audio.isLoading || _autoTarget != null) {
      _pausedAutoTarget = _autoTarget;
      _cancelAutoAdvance(settlePage: true, clearPaused: false);
      await _audio.pause();
      if (mounted) setState(() {});
      return;
    }
    if (_pausedAutoTarget case final target?) {
      _pausedAutoTarget = null;
      setState(() {
        _pageIndex = target;
        _previewSentence = null;
        _dismissedTranslationId = null;
      });
      _pageController?.jumpToPage(target);
      unawaited(_saveProgress(target));
      await _playSequentialPage();
      return;
    }
    try {
      if (_audio.canResume) {
        await _audio.resume();
      } else if (_audio.currentMode == PlayMode.fullPage) {
        await _playFullPage();
      }
    } catch (_) {
      if (mounted) _showAudioNotice();
    }
  }

  Future<void> _setSpeed(double speed) async {
    try {
      await _audio.setSpeed(speed);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法切换语速，请重试')));
    }
  }

  Future<void> _advanceAfterPage(PagePlaybackCompletion completion) async {
    if (!mounted ||
        _restoring ||
        !_audio.canContinue(completion) ||
        completion.pageIndex != _pages[_pageIndex].pageIndex) {
      return;
    }
    var next = _pageIndex + 1;
    // Image-only pages have no bubble; continue at the next readable page.
    while (next < _pages.length && _pages[next].playbackBubbles.isEmpty) {
      next++;
    }
    if (next >= _pages.length || _pageController?.hasClients != true) return;
    setState(() {
      _autoCompletion = completion;
      _autoTarget = next;
    });
    try {
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageController!.jumpToPage(next);
      } else {
        await _pageController!.animateToPage(
          next,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubic,
        );
      }
      if (!mounted ||
          _autoCompletion != completion ||
          !_audio.canContinue(completion) ||
          _pageIndex != next) {
        return;
      }
      _cancelAutoAdvance();
      await _playSequentialPage();
    } finally {
      if (_autoCompletion == completion) _cancelAutoAdvance();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoAdvance();
    unawaited(_completionSubscription?.cancel());
    unawaited(_readingSubscription?.cancel());
    widget.learningController?.removeListener(_configureEyeReminder);
    _eyeReminderTimer?.cancel();
    _audio.removeListener(_onAudioChanged);
    if (_ownsAudio) _audio.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeSentence;
    final activeBubble = _activeBubble;
    final activeId = activeBubble?.id ?? active?.id;
    final colors = Theme.of(context).colorScheme;
    final units = widget.units ?? TextbookUnit.forBook(widget.book.bookId);
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _cancelAutoAdvance();
          unawaited(_audio.stop());
        }
      },
      child: Scaffold(
        endDrawer: units.isEmpty
            ? null
            : Drawer(
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '单元目录',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final unit in units)
                              Builder(
                                builder: (context) {
                                  final target = _pages.indexWhere(
                                    (page) => page.pageIndex == unit.startPage,
                                  );
                                  final currentPage =
                                      _pages[_pageIndex].pageIndex;
                                  return ListTile(
                                    key: ValueKey('unit-${unit.number}'),
                                    title: Text(unit.label),
                                    subtitle: Text(
                                      target < 0
                                          ? '资源尚未导入'
                                          : '教材第 ${_printedPageFor(unit)} 页',
                                    ),
                                    selected:
                                        currentPage >= unit.startPage &&
                                        !units.any(
                                          (next) =>
                                              next.startPage > unit.startPage &&
                                              next.startPage <= currentPage,
                                        ),
                                    enabled: !_restoring && target >= 0,
                                    onTap: () {
                                      _cancelAutoAdvance();
                                      unawaited(_audio.stop());
                                      Navigator.pop(context);
                                      // Jump directly, without loading all intervening pages.
                                      _pageController?.jumpToPage(target);
                                    },
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        appBar: AppBar(
          actions: [
            if (units.isNotEmpty)
              Builder(
                builder: (context) => IconButton(
                  tooltip: '目录',
                  icon: const Icon(Icons.menu_book_outlined),
                  onPressed: _restoring
                      ? null
                      : () => Scaffold.of(context).openEndDrawer(),
                ),
              ),
          ],
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _restoring
                    ? '正在恢复阅读进度…'
                    : '第 ${_pageIndex + 1} / ${_pages.length} 页',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        body: _restoring
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: colors.surfaceContainerLow,
                      child: NotificationListener<ScrollStartNotification>(
                        onNotification: (notification) {
                          if (notification.dragDetails != null &&
                              notification.depth == 0 &&
                              notification.metrics.axis == Axis.horizontal) {
                            // A driven PageView may accept a stationary tap as
                            // a drag after pointer-up. Actual finger movement
                            // stops sound immediately, including on this page.
                            final down = _pagePointerDownPosition;
                            if (_pagePointer != null &&
                                down != null &&
                                (notification.dragDetails!.globalPosition.dx -
                                            down.dx)
                                        .abs() >
                                    kTouchSlop) {
                              _stopForManualPageDrag();
                            }
                          }
                          return false;
                        },
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: _onPagePointerDown,
                          onPointerMove: _onPagePointerMove,
                          onPointerUp: _onPagePointerUp,
                          onPointerCancel: (_) {
                            _pagePointer = null;
                            _pagePointerDownPosition = null;
                            _scrollTapSentence = null;
                            _handledScrollingTap = false;
                          },
                          child: PageView.builder(
                            controller: _pageController,
                            itemCount: _pages.length,
                            onPageChanged: _onPageChanged,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.all(12),
                              child: InteractiveTextbookPage(
                                key: _pageKeys.putIfAbsent(
                                  index,
                                  () =>
                                      GlobalKey<InteractiveTextbookPageState>(),
                                ),
                                page: _pages[index],
                                activeSentenceId: index == _pageIndex
                                    ? active?.id
                                    : null,
                                activeBubbleId: index == _pageIndex
                                    ? activeBubble?.id
                                    : null,
                                onSentenceTap: (sentence) {
                                  if (!_handledScrollingTap) {
                                    unawaited(
                                      _onSentenceTap(
                                        sentence,
                                        pageIndex: index,
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: _pageIndex > 0
                              ? () => _goToPage(_pageIndex - 1)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('上一页'),
                        ),
                        TextButton.icon(
                          onPressed: _pageIndex + 1 < _pages.length
                              ? () => _goToPage(_pageIndex + 1)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                          label: const Text('下一页'),
                          iconAlignment: IconAlignment.end,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: TextbookBottomBar(
          currentMode: _audio.currentMode,
          onModeChanged: _setPlayMode,
          currentSpeed: _audio.currentSpeed,
          onSpeedChanged: _setSpeed,
          isPlaying: _audio.isPlaying || _autoTarget != null,
          isLoading: _audio.isLoading,
          canResume:
              _audio.canResume ||
              _pausedAutoTarget != null ||
              (_audio.currentMode == PlayMode.fullPage &&
                  _pages[_pageIndex].playbackBubbles.isNotEmpty),
          onPlaybackToggle: _togglePlayback,
          isTranslationEnabled: _isTranslationEnabled,
          onTranslationChanged: (value) {
            setState(() => _isTranslationEnabled = value);
          },
          activeSentence: active?.id == _dismissedTranslationId ? null : active,
          activeBubble: activeBubble?.id == _dismissedTranslationId
              ? null
              : activeBubble,
          onReplay: activeBubble != null
              ? () => _playFullPage(targetBubble: activeBubble)
              : active == null
              ? null
              : () => _onSentenceTap(active),
          onDismissTranslation: () {
            setState(() => _dismissedTranslationId = activeId);
          },
        ),
      ),
    );
  }
}
