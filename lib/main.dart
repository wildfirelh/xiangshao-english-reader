import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/textbook.dart';
import 'repositories/textbook_repository.dart';
import 'screens/home_shelf_screen.dart';
import 'services/reading_progress_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const PointReadingApp());
}

class PointReadingApp extends StatefulWidget {
  const PointReadingApp({super.key, this.bookFuture, this.progressStore});

  final Future<Textbook>? bookFuture;
  final ReadingProgressStore? progressStore;

  @override
  State<PointReadingApp> createState() => _PointReadingAppState();
}

class _PointReadingAppState extends State<PointReadingApp> {
  late final Future<Textbook> _book =
      widget.bookFuture ??
      TextbookRepository().loadBookFromAsset(
        'assets/textbooks/xiangshao_3_1/book.json',
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '湘少英语三上点读',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF486A59)),
    initialRoute: HomeShelfScreen.routeName,
    routes: {
      HomeShelfScreen.routeName: (_) => FutureBuilder<Textbook>(
        future: _book,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return HomeShelfScreen(
              key: ValueKey(snapshot.data!.bookId),
              book: snapshot.data!,
              progressStore: widget.progressStore,
            );
          }
          if (snapshot.hasError) {
            return HomeShelfScreen(
              progressStore: widget.progressStore,
              book: const Textbook(bookId: 'mock', title: '英语点读', pages: []),
            );
          }
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        },
      ),
    },
  );
}
