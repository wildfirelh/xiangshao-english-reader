import 'package:english_point_reading/main.dart';
import 'package:english_point_reading/repositories/textbook_catalog_repository.dart';
import 'package:english_point_reading/screens/bookshelf_screen.dart';
import 'package:english_point_reading/screens/main_screen.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/learning_controller.dart';
import 'package:english_point_reading/services/learning_preferences_store.dart';
import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:english_point_reading/widgets/floating_capsule_nav_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_reading_progress_store.dart';

void main() {
  testWidgets('initial route shows the shelf and bundled book', (tester) async {
    final catalog = await tester.runAsync(
      () => TextbookCatalogRepository().loadCatalog(),
    );
    final learning = LearningController(
      preferencesStore: InMemoryLearningPreferencesStore(),
      playbackPreferencesStore: InMemoryPlaybackPreferencesStore(),
    );
    addTearDown(learning.dispose);
    await tester.pumpWidget(
      PointReadingApp(
        catalogFuture: Future.value(catalog!),
        progressStore: MemoryReadingProgressStore(),
        learningController: learning,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(find.byType(FloatingCapsuleNavBar), findsOneWidget);
    expect(find.byType(TextbookReaderScreen), findsNothing);
    expect(find.text('湘少版 三年级上册'), findsOneWidget);
    expect(find.text('湘少版 三年级下册'), findsOneWidget);
    expect(find.text('继续点读'), findsOneWidget);
  });
}
