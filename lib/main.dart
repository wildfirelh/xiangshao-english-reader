import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/textbook.dart';
import 'models/textbook_catalog.dart';
import 'models/textbook_unit.dart';
import 'repositories/textbook_catalog_repository.dart';
import 'screens/main_screen.dart';
import 'services/audio_player_service.dart';
import 'services/learning_controller.dart';
import 'services/reading_progress_store.dart';
import 'services/app_update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const PointReadingApp());
}

class PointReadingApp extends StatefulWidget {
  const PointReadingApp({
    super.key,
    this.catalogFuture,
    this.catalogRepository,
    this.bookFuture,
    this.progressStore,
    this.learningController,
    this.audioPlayerFactory,
    this.updateService,
  });

  final Future<List<TextbookCatalogEntry>>? catalogFuture;
  final TextbookCatalogRepository? catalogRepository;

  /// Optional single-book fixture; production reads the catalog and lazily
  /// loads a manifest only when the corresponding book is opened.
  final Future<Textbook>? bookFuture;
  final ReadingProgressStore? progressStore;
  final LearningController? learningController;
  final AudioPlayerService Function()? audioPlayerFactory;
  final AppUpdateService? updateService;

  @override
  State<PointReadingApp> createState() => _PointReadingAppState();
}

class _PointReadingAppState extends State<PointReadingApp> {
  late final _repository =
      widget.catalogRepository ?? TextbookCatalogRepository();
  late final Future<List<TextbookCatalogEntry>> _catalog =
      widget.catalogFuture ?? _loadCatalog();

  Future<List<TextbookCatalogEntry>> _loadCatalog() async {
    if (widget.bookFuture case final bookFuture?) {
      final book = await bookFuture;
      return [
        TextbookCatalogEntry(
          id: book.bookId,
          title: book.title,
          grade: 3,
          term: 1,
          cover: '',
          ready: true,
          totalUnits: TextbookUnit.forBook(book.bookId).length,
          units: TextbookUnit.forBook(book.bookId),
          firstPageIndex: book.pages.isEmpty
              ? null
              : book.pages.first.pageIndex,
          pageCount: book.pages.isEmpty ? null : book.pages.length,
        ),
      ];
    }
    return _repository.loadCatalog();
  }

  Future<Textbook> _loadBook(TextbookCatalogEntry entry) async {
    if (widget.bookFuture case final bookFuture?) {
      final book = await bookFuture;
      if (book.bookId == entry.id) return book;
    }
    return _repository.loadBook(entry);
  }

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF356A58),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFF6F8F5)
          : const Color(0xFF151B18),
      appBarTheme: const AppBarTheme(centerTitle: false),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '小学英语点读',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    initialRoute: MainScreen.routeName,
    routes: {
      MainScreen.routeName: (_) => MainScreen(
        catalogFuture: _catalog,
        catalogLoader: _loadCatalog,
        bookLoader: _loadBook,
        progressStore: widget.progressStore,
        learningController: widget.learningController,
        audioPlayerFactory: widget.audioPlayerFactory,
        updateService: widget.updateService,
      ),
    },
  );
}
