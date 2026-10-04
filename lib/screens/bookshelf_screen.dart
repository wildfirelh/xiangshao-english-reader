import 'dart:async';

import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../models/textbook_catalog.dart';
import '../services/audio_player_service.dart';
import '../services/learning_controller.dart';
import '../services/reading_progress_store.dart';
import 'textbook_reader_screen.dart';

/// A catalog view that loads full textbook resources only when a book is opened.
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({
    super.key,
    required this.catalog,
    required this.bookLoader,
    this.progressStore,
    this.audioPlayerFactory,
    this.onPointRead,
    this.learningController,
    this.bottomContentPadding = 100,
  });

  final List<TextbookCatalogEntry> catalog;
  final Future<Textbook> Function(TextbookCatalogEntry) bookLoader;
  final ReadingProgressStore? progressStore;
  final AudioPlayerService Function()? audioPlayerFactory;
  final Future<void> Function(String bookId)? onPointRead;
  final LearningController? learningController;
  final double bottomContentPadding;

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  late final ReadingProgressStore _progress =
      widget.progressStore ?? SharedPreferencesReadingProgressStore.instance;
  final _lastPages = <String, int?>{};
  final _loadedBooks = <String, Textbook>{};
  int? _grade;
  String? _openingBookId;
  bool _loadingProgress = true;
  int _progressGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshProgress());
  }

  @override
  void didUpdateWidget(covariant BookshelfScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.catalog, widget.catalog)) {
      if (_grade != null &&
          !widget.catalog.any((entry) => entry.grade == _grade)) {
        _grade = null;
      }
      unawaited(_refreshProgress());
    }
  }

  Future<void> _refreshProgress() async {
    final generation = ++_progressGeneration;
    final values = <String, int?>{};
    await Future.wait([
      for (final entry in widget.catalog.where((entry) => entry.ready))
        () async {
          try {
            values[entry.id] = await _progress.load(entry.id);
          } catch (error) {
            debugPrint('Unable to read progress for ${entry.id}: $error');
            values[entry.id] = null;
          }
        }(),
    ]);
    if (!mounted || generation != _progressGeneration) return;
    setState(() {
      _lastPages
        ..clear()
        ..addAll(values);
      _loadingProgress = false;
    });
  }

  Future<void> _openBook(TextbookCatalogEntry entry) async {
    if (!entry.ready) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该教材正在整理中，敬请期待')));
      return;
    }
    if (_openingBookId != null || _loadingProgress) return;
    setState(() => _openingBookId = entry.id);
    AudioPlayerService? audio;
    try {
      final book = await widget.bookLoader(entry);
      if (!mounted) return;
      if (book.bookId != entry.id) {
        throw const FormatException(
          'Textbook ID does not match catalog entry.',
        );
      }
      _loadedBooks[entry.id] = book;
      audio = widget.audioPlayerFactory?.call();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: RouteSettings(name: '/reader/${entry.id}'),
          builder: (_) => TextbookReaderScreen(
            book: book,
            units: entry.units,
            firstPageIndex: entry.firstPageIndex,
            progressStore: _progress,
            audioPlayerService: audio,
            onPointRead: widget.onPointRead == null
                ? null
                : () => widget.onPointRead!(entry.id),
            learningController: widget.learningController,
          ),
        ),
      );
      if (mounted) {
        await _refreshProgress();
        try {
          await widget.learningController?.refreshSpeed();
        } catch (error) {
          debugPrint('Unable to refresh playback preference: $error');
        }
      }
    } catch (error) {
      debugPrint('Unable to open textbook ${entry.id}: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('教材暂时无法打开，请重试'),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => unawaited(_openBook(entry)),
          ),
        ),
      );
    } finally {
      audio?.dispose();
      if (mounted) setState(() => _openingBookId = null);
    }
  }

  ({double ratio, int? offset, int? total}) _position(
    TextbookCatalogEntry entry,
  ) {
    final saved = _lastPages[entry.id];
    final book = _loadedBooks[entry.id];
    if (book != null) {
      final offset = book.pages.indexWhere((page) => page.pageIndex == saved);
      return (
        ratio: offset < 0 || book.pages.isEmpty
            ? 0
            : (offset + 1) / book.pages.length,
        offset: offset < 0 ? null : offset + 1,
        total: book.pages.isEmpty ? null : book.pages.length,
      );
    }
    final start = entry.firstPageIndex;
    final total = entry.pageCount;
    if (saved == null || start == null || total == null || total <= 0) {
      return (ratio: 0, offset: null, total: total);
    }
    final offset = saved - start;
    if (offset < 0 || offset >= total) {
      return (ratio: 0, offset: null, total: total);
    }
    return (ratio: (offset + 1) / total, offset: offset + 1, total: total);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final grades = widget.catalog.map((entry) => entry.grade).toSet().toList()
      ..sort();
    final books = widget.catalog
        .where((entry) => _grade == null || entry.grade == _grade)
        .toList();
    return SingleChildScrollView(
      key: const Key('books-scroll'),
      padding: EdgeInsets.fromLTRB(
        20,
        28,
        20,
        widget.bottomContentPadding + 24,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '小学英语点读',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '我的书架',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '选一本教材，让英语开口说。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _gradeChip(context, null, '全部'),
                  for (final grade in grades)
                    _gradeChip(context, grade, '$grade 年级'),
                ],
              ),
              const SizedBox(height: 24),
              if (books.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Text(
                    '书架还没有教材',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final largeText =
                        MediaQuery.textScalerOf(context).scale(14) > 18;
                    final columns = largeText || constraints.maxWidth < 332
                        ? 1
                        : constraints.maxWidth >= 730
                        ? 3
                        : 2;
                    final width =
                        (constraints.maxWidth - (columns - 1) * 16) / columns;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 20,
                      children: [
                        for (final entry in books)
                          SizedBox(
                            width: width,
                            child: _bookCard(context, entry),
                          ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.offline_pin_outlined,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已上线教材可离线点读，更多教材正在整理中。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gradeChip(BuildContext context, int? grade, String label) =>
      ChoiceChip(
        key: ValueKey(grade == null ? 'grade-all' : 'grade-$grade'),
        label: Text(label),
        selected: _grade == grade,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) => setState(() => _grade = grade),
      );

  Widget _bookCard(BuildContext context, TextbookCatalogEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final position = _position(entry);
    final percent = (position.ratio * 100).round();
    final opening = _openingBookId == entry.id;
    return Material(
      key: ValueKey('book-${entry.id}'),
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openingBookId != null || (_loadingProgress && entry.ready)
            ? null
            : () => unawaited(_openBook(entry)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                key: ValueKey('book-cover-${entry.id}'),
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: AspectRatio(
                    aspectRatio: 0.72,
                    child: entry.cover.isNotEmpty && entry.ready
                        ? Image.asset(
                            entry.cover,
                            fit: BoxFit.contain,
                            semanticLabel: '${entry.title}封面',
                            cacheWidth: 660,
                            errorBuilder: (_, _, _) =>
                                _coverPlaceholder(context, entry),
                          )
                        : _coverPlaceholder(context, entry),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                entry.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${entry.totalUnits} 个单元 · ${entry.ready ? '离线点读' : '准备中'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (entry.ready) ...[
                Text(
                  _loadingProgress ? '正在读取进度…' : '阅读进度 $percent%',
                  key: ValueKey('book-progress-${entry.id}'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: position.ratio,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: colors.surfaceContainerHighest,
                  semanticsLabel: '${entry.title}阅读进度 $percent%',
                ),
                const SizedBox(height: 8),
                Text(
                  position.offset == null
                      ? '从第一页开始'
                      : '第 ${position.offset} / ${position.total} 页',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: ValueKey('book-continue-${entry.id}'),
                  onPressed: _loadingProgress || _openingBookId != null
                      ? null
                      : () => unawaited(_openBook(entry)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: opening
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onPrimary,
                          ),
                        )
                      : const Text('继续点读'),
                ),
              ] else
                OutlinedButton.icon(
                  key: ValueKey('book-continue-${entry.id}'),
                  onPressed: () => unawaited(_openBook(entry)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.lock_outline_rounded, size: 18),
                  label: const Text('准备中'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(BuildContext context, TextbookCatalogEntry entry) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.secondaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                entry.ready
                    ? Icons.auto_stories_outlined
                    : Icons.lock_outline_rounded,
                size: 44,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(height: 14),
              Text(
                '${entry.grade} 年级${entry.term == 1 ? '上' : '下'}册',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
