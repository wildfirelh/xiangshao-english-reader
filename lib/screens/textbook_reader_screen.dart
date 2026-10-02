import 'dart:async';

import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../models/textbook_unit.dart';
import '../services/audio_player_service.dart';
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
  });

  final Textbook book;
  final AudioPlayerService? audioPlayerService;
  final ReadingProgressStore? progressStore;

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
  PagePlaybackCompletion? _autoCompletion;
  int? _autoTarget;

  int _pageIndex = 0;
  bool _isTranslationEnabled = true;
  PointSentence? _previewSentence;
  String? _dismissedTranslationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null) {
      _audio.setForeground(lifecycle == AppLifecycleState.resumed);
    }
    _audio.addListener(_onAudioChanged);
    _completionSubscription = _audio.pageCompletions.listen(
      (completion) => unawaited(_advanceAfterPage(completion)),
    );
    unawaited(_restoreProgress());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _audio.setForeground(state == AppLifecycleState.resumed);
    if (state != AppLifecycleState.resumed) {
      _cancelAutoAdvance(settlePage: true);
    }
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
    if (mounted) setState(() {});
  }

  PointSentence? get _activeSentence {
    final id = _audio.currentSentenceId ?? _previewSentence?.id;
    if (id == null) return null;
    for (final sentence in _pages[_pageIndex].sentences) {
      if (sentence.id == id) return sentence;
    }
    return null;
  }

  void _onPageChanged(int index) {
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

  Future<void> _onSentenceTap(PointSentence sentence) async {
    _cancelAutoAdvance(settlePage: true);
    final tappedPageIndex = _pageIndex;
    setState(() {
      _previewSentence = null;
      _dismissedTranslationId = null;
    });
    if (sentence.audioPath.isEmpty) {
      unawaited(_audio.stop());
      setState(() => _previewSentence = sentence);
      _showAudioNotice();
      return;
    }
    try {
      await _audio.playSentence(
        pageSentences: _pages[tappedPageIndex].sentences,
        targetSentence: sentence,
      );
    } catch (_) {
      if (!mounted || _pageIndex != tappedPageIndex) return;
      setState(() => _previewSentence = sentence);
      _showAudioNotice();
    }
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

  void _cancelAutoAdvance({bool settlePage = false}) {
    final wasAdvancing = _autoCompletion != null;
    _autoCompletion = null;
    _autoTarget = null;
    if (settlePage && wasAdvancing && _pageController?.hasClients == true) {
      _pageController!.jumpToPage(_pageIndex);
    }
  }

  void _setPlayMode(PlayMode mode) {
    _cancelAutoAdvance(settlePage: true);
    _audio.setPlayMode(mode);
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
        _pages[_pageIndex].sentences.lastOrNull?.id != completion.sentenceId) {
      return;
    }
    var next = _pageIndex + 1;
    // Image-only pages have no first sentence; continue at the next readable page.
    while (next < _pages.length && _pages[next].sentences.isEmpty) {
      next++;
    }
    if (next >= _pages.length || _pageController?.hasClients != true) return;
    _autoCompletion = completion;
    _autoTarget = next;
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
      await _onSentenceTap(_pages[next].sentences.first);
    } finally {
      if (_autoCompletion == completion) _cancelAutoAdvance();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoAdvance();
    unawaited(_completionSubscription?.cancel());
    _audio.removeListener(_onAudioChanged);
    if (_ownsAudio) _audio.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeSentence;
    final colors = Theme.of(context).colorScheme;
    final units = TextbookUnit.forBook(widget.book.bookId);
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
                                          : '教材第 ${unit.printedPage} 页',
                                    ),
                                    selected:
                                        currentPage >= unit.startPage &&
                                        currentPage < unit.startPage + 5,
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
                              _autoCompletion != null) {
                            _cancelAutoAdvance();
                            unawaited(_audio.stop());
                          }
                          return false;
                        },
                        child: PageView.builder(
                          controller: _pageController,
                          itemCount: _pages.length,
                          onPageChanged: _onPageChanged,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.all(12),
                            child: InteractiveTextbookPage(
                              key: ValueKey(index),
                              page: _pages[index],
                              activeSentenceId: index == _pageIndex
                                  ? active?.id
                                  : null,
                              onSentenceTap: _onSentenceTap,
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
          isTranslationEnabled: _isTranslationEnabled,
          onTranslationChanged: (value) {
            setState(() => _isTranslationEnabled = value);
          },
          activeSentence: active?.id == _dismissedTranslationId ? null : active,
          onReplay: active == null ? null : () => _onSentenceTap(active),
          onDismissTranslation: () {
            setState(() => _dismissedTranslationId = active?.id);
          },
        ),
      ),
    );
  }
}
