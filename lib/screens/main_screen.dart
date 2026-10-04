import 'dart:async';

import 'package:flutter/material.dart';

import '../models/textbook.dart';
import '../models/textbook_catalog.dart';
import '../services/app_update_service.dart';
import '../services/audio_player_service.dart';
import '../services/learning_controller.dart';
import '../services/reading_progress_store.dart';
import '../widgets/floating_capsule_nav_bar.dart';
import 'bookshelf_screen.dart';
import 'profile_screen.dart';

/// Keeps library/settings state alive while readers use separate routes.
class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.catalogLoader,
    required this.bookLoader,
    this.catalogFuture,
    this.progressStore,
    this.learningController,
    this.audioPlayerFactory,
    this.updateService,
  });

  static const routeName = '/';
  final Future<List<TextbookCatalogEntry>> Function() catalogLoader;
  final Future<List<TextbookCatalogEntry>>? catalogFuture;
  final Future<Textbook> Function(TextbookCatalogEntry entry) bookLoader;
  final ReadingProgressStore? progressStore;
  final LearningController? learningController;
  final AudioPlayerService Function()? audioPlayerFactory;
  final AppUpdateService? updateService;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late Future<List<TextbookCatalogEntry>> _catalog;
  late final LearningController _learning;
  late final ReadingProgressStore _progress;
  var _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _catalog = widget.catalogFuture ?? widget.catalogLoader();
    _learning = widget.learningController ?? LearningController();
    _progress =
        widget.progressStore ?? SharedPreferencesReadingProgressStore.instance;
    unawaited(_learning.initialize());
  }

  @override
  void dispose() {
    if (widget.learningController == null) _learning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _tab(
                    index: 0,
                    reducedMotion: reducedMotion,
                    child: FutureBuilder<List<TextbookCatalogEntry>>(
                      future: _catalog,
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          return BookshelfScreen(
                            catalog: snapshot.data!,
                            bookLoader: widget.bookLoader,
                            progressStore: _progress,
                            learningController: _learning,
                            audioPlayerFactory: widget.audioPlayerFactory,
                            onPointRead: _learning.recordPointRead,
                            bottomContentPadding:
                                FloatingCapsuleNavBar.contentClearance,
                          );
                        }
                        return _catalogStatus(error: snapshot.hasError);
                      },
                    ),
                  ),
                  _tab(
                    index: 1,
                    reducedMotion: reducedMotion,
                    child: ProfileScreen(
                      controller: _learning,
                      updateService: widget.updateService,
                      bottomContentPadding:
                          FloatingCapsuleNavBar.contentClearance,
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: FloatingCapsuleNavBar(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (index) {
                  if (index != _selectedIndex) {
                    setState(() => _selectedIndex = index);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab({
    required int index,
    required bool reducedMotion,
    required Widget child,
  }) => TickerMode(
    enabled: _selectedIndex == index,
    child: AnimatedOpacity(
      opacity: _selectedIndex == index ? 1 : 0,
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: child,
    ),
  );

  Widget _catalogStatus({required bool error}) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      24,
      40,
      24,
      FloatingCapsuleNavBar.contentClearance,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('我的书架', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 12),
        Text(
          error ? '教材目录暂时无法读取，请重试。' : '正在整理你的书架…',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        if (error)
          FilledButton.icon(
            onPressed: () => setState(() {
              _catalog = widget.catalogLoader();
            }),
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
          )
        else
          const CircularProgressIndicator(),
      ],
    ),
  );
}
