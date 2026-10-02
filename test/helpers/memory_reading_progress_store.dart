import 'package:english_point_reading/services/reading_progress_store.dart';

class MemoryReadingProgressStore implements ReadingProgressStore {
  final pages = <String, int>{};

  @override
  Future<int?> load(String bookId) async => pages[bookId];

  @override
  Future<void> save(String bookId, int pageIndex) async {
    pages[bookId] = pageIndex;
  }
}
