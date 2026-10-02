import 'package:english_point_reading/main.dart';
import 'package:english_point_reading/repositories/textbook_repository.dart';
import 'package:english_point_reading/screens/home_shelf_screen.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_reading_progress_store.dart';

void main() {
  testWidgets('initial route shows the shelf and bundled book', (tester) async {
    // The full manifest exceeds Flutter's 50 KB background-decoding threshold.
    // Allow its real isolate/asset IO to finish instead of advancing fake time.
    final book = await tester.runAsync(
      () => TextbookRepository().loadBookFromAsset(
        'assets/textbooks/xiangshao_3_1/book.json',
      ),
    );
    await tester.pumpWidget(
      PointReadingApp(
        bookFuture: Future.value(book!),
        progressStore: MemoryReadingProgressStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeShelfScreen), findsOneWidget);
    expect(find.byType(TextbookReaderScreen), findsNothing);
    expect(find.text('英语 三年级上册 (湘少版)'), findsOneWidget);
    expect(find.text('继续学习'), findsOneWidget);
  });
}
