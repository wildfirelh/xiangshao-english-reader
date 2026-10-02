import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../models/textbook_unit.dart';
import '../services/audio_player_service.dart';
import '../services/reading_progress_store.dart';
import 'textbook_reader_screen.dart';

class HomeShelfScreen extends StatefulWidget {
  const HomeShelfScreen({
    super.key,
    required this.book,
    this.progressStore,
    this.audioPlayerFactory,
    this.coverPath = 'assets/textbooks/xiangshao_3_1/images/cover.webp',
  });

  static const routeName = '/';
  final Textbook book;
  final ReadingProgressStore? progressStore;
  final AudioPlayerService Function()? audioPlayerFactory;
  final String coverPath;

  @override
  State<HomeShelfScreen> createState() => _HomeShelfScreenState();
}

class _HomeShelfScreenState extends State<HomeShelfScreen> {
  late final _progress =
      widget.progressStore ?? SharedPreferencesReadingProgressStore.instance;
  int? _lastPage;
  bool _loadingProgress = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _refreshProgress();
  }

  Future<void> _refreshProgress() async {
    int? saved;
    try {
      saved = await _progress.load(widget.book.bookId);
    } catch (error) {
      debugPrint('Unable to read shelf progress: $error');
    }
    if (!mounted) return;
    setState(() {
      _lastPage = widget.book.pages.any((page) => page.pageIndex == saved)
          ? saved
          : null;
      _loadingProgress = false;
    });
  }

  Future<void> _openReader({int? pageIndex}) async {
    if (_opening || _loadingProgress) return;
    setState(() => _opening = true);
    final audio = widget.audioPlayerFactory?.call();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/reader'),
          builder: (_) => TextbookReaderScreen(
            book: widget.book,
            initialPageIndex: pageIndex,
            progressStore: _progress,
            audioPlayerService: audio,
          ),
        ),
      );
    } finally {
      audio?.dispose();
      if (mounted) {
        await _refreshProgress();
        if (mounted) setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final savedOffset = widget.book.pages.indexWhere(
      (page) => page.pageIndex == _lastPage,
    );
    final position = _loadingProgress
        ? '正在读取阅读进度…'
        : savedOffset < 0
        ? '准备好了，就从第一页开始'
        : '上次读到第 ${savedOffset + 1} / ${widget.book.pages.length} 页';
    final units = TextbookUnit.forBook(widget.book.bookId);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('shelf-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.auto_stories_outlined,
                          color: colors.onPrimaryContainer,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '英语点读',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '你好，今天也读一点英语吧。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Text(
                    '我的教材',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final cover = SizedBox(
                                width: 104,
                                height: 148,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.asset(
                                    widget.coverPath,
                                    key: const Key('textbook-cover'),
                                    fit: BoxFit.contain,
                                    cacheWidth: 380,
                                    semanticLabel: '英语三年级上册教材封面',
                                    errorBuilder: (_, error, stack) =>
                                        ColoredBox(
                                          color: colors.primaryContainer,
                                          child: Icon(
                                            Icons.menu_book,
                                            size: 48,
                                            color: colors.onPrimaryContainer,
                                          ),
                                        ),
                                  ),
                                ),
                              );
                              final details = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '本学期教材',
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: colors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    widget.book.bookId == 'xiangshao_3_1'
                                        ? '英语 三年级上册 (湘少版)'
                                        : widget.book.title,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '${units.length} 个单元 · 离线点读',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              );
                              if (constraints.maxWidth < 280 ||
                                  MediaQuery.textScalerOf(context).scale(14) >
                                      19) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    cover,
                                    const SizedBox(height: 20),
                                    details,
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  cover,
                                  const SizedBox(width: 20),
                                  Expanded(child: details),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 24),
                          Text(
                            position,
                            key: const Key('shelf-progress'),
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (savedOffset >= 0) ...[
                            const SizedBox(height: 10),
                            LinearProgressIndicator(
                              value:
                                  (savedOffset + 1) / widget.book.pages.length,
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(4),
                              semanticsLabel: '阅读位置，$position',
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            key: const Key('continue-learning'),
                            onPressed: _loadingProgress || _opening
                                ? null
                                : () => _openReader(),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 52),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(
                              widget.book.pages.isEmpty ? '体验点读' : '继续学习',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (units.isNotEmpty) ...[
                    const SizedBox(height: 32),
                    Text(
                      '按单元学习',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '选一个单元，开始今天的练习。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final largeText =
                            MediaQuery.textScalerOf(context).scale(14) > 17;
                        final columns = largeText || constraints.maxWidth < 300
                            ? 1
                            : constraints.maxWidth >= 660
                            ? 3
                            : 2;
                        final width =
                            (constraints.maxWidth - (columns - 1) * 12) /
                            columns;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final unit in units)
                              SizedBox(
                                width: width,
                                height: columns == 1 ? null : 156,
                                child: _unitCard(
                                  context,
                                  unit,
                                  available: widget.book.pages.any(
                                    (p) => p.pageIndex == unit.startPage,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _unitCard(
    BuildContext context,
    TextbookUnit unit, {
    required bool available,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected =
        _lastPage != null &&
        _lastPage! >= unit.startPage &&
        _lastPage! < unit.startPage + 5;
    return Material(
      color: selected ? colors.secondaryContainer : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('shelf-unit-${unit.number}'),
        onTap: !available || _opening || _loadingProgress
            ? null
            : () => _openReader(pageIndex: unit.startPage),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Unit ${unit.number}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                unit.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      available ? '第 ${unit.printedPage} 页' : '暂未导入',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
