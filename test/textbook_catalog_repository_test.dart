import 'dart:async';
import 'dart:convert';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/models/textbook_catalog.dart';
import 'package:english_point_reading/repositories/textbook_catalog_repository.dart';
import 'package:english_point_reading/repositories/textbook_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryCatalogBundle extends CachingAssetBundle {
  MemoryCatalogBundle(this.files);

  final Map<String, String> files;
  final Map<String, int> requests = {};

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    requests.update(key, (count) => count + 1, ifAbsent: () => 1);
    final value = files[key];
    if (value == null) throw StateError('Missing test asset $key');
    return value;
  }

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
    Uint8List.fromList(utf8.encode(await loadString(key))),
  );
}

class ControlledBookRepository extends TextbookRepository {
  final requests = <String>[];
  Future<Textbook> Function(String path)? handler;

  @override
  Future<Textbook> loadBookFromAsset(String jsonPath) {
    requests.add(jsonPath);
    return handler!(jsonPath);
  }
}

const futureEntry = TextbookCatalogEntry(
  id: 'another_publisher_5_2',
  title: '五年级下册',
  grade: 5,
  term: 2,
  cover: '',
  ready: true,
  totalUnits: 3,
);

const futureBook = Textbook(
  bookId: 'another_publisher_5_2',
  title: 'Future book',
  pages: [],
);

Map<String, dynamic> metadataJson({String id = 'future_book'}) => {
  'id': id,
  'title': '未来教材',
  'grade': 1,
  'term': 1,
  'cover': '',
  'ready': true,
  'totalUnits': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loads only metadata, preserves ordering, returns an immutable catalog',
    () async {
      final path = 'assets/textbooks/test_catalog.json';
      final bundle = MemoryCatalogBundle({
        path: jsonEncode([
          metadataJson(id: 'future_one'),
          {...metadataJson(id: 'future_two'), 'ready': false},
        ]),
      });
      final repository = TextbookCatalogRepository(bundle: bundle);
      final catalog = await repository.loadCatalog(jsonPath: path);
      expect(catalog.map((entry) => entry.id), ['future_one', 'future_two']);
      expect(bundle.requests, {path: 1});
      expect(() => catalog.clear(), throwsUnsupportedError);
    },
  );

  test(
    'rejects a non-array catalog, invalid entries, and duplicate IDs',
    () async {
      for (final raw in [
        {'books': []},
        ['book'],
        [metadataJson(), metadataJson()],
        [
          metadataJson(),
          {...metadataJson(id: 'other'), 'grade': 7},
        ],
      ]) {
        final repository = TextbookCatalogRepository(
          bundle: MemoryCatalogBundle({
            'assets/textbooks/catalog.json': jsonEncode(raw),
          }),
        );
        await expectLater(repository.loadCatalog(), throwsFormatException);
      }
    },
  );

  test(
    'rejects not-ready books without trying to load missing resources',
    () async {
      final books = ControlledBookRepository();
      final repository = TextbookCatalogRepository(bookRepository: books);
      const entry = TextbookCatalogEntry(
        id: 'still_preparing',
        title: '准备中的教材',
        grade: 3,
        term: 2,
        cover: '',
        ready: false,
        totalUnits: 10,
      );
      await expectLater(repository.loadBook(entry), throwsStateError);
      expect(books.requests, isEmpty);
    },
  );

  test('shares an in-flight request and caches successful books', () async {
    final completer = Completer<Textbook>();
    final books = ControlledBookRepository()..handler = (_) => completer.future;
    final repository = TextbookCatalogRepository(bookRepository: books);
    final first = repository.loadBook(futureEntry);
    final second = repository.loadBook(futureEntry);
    expect(second, same(first));
    expect(books.requests, [futureEntry.manifestPath]);
    completer.complete(futureBook);
    expect(await first, same(futureBook));
    expect(await second, same(futureBook));
    expect(await repository.loadBook(futureEntry), same(futureBook));
    expect(books.requests, hasLength(1));
  });

  test('does not merge cache entries with different manifest paths', () async {
    final books = ControlledBookRepository()..handler = (_) async => futureBook;
    final repository = TextbookCatalogRepository(bookRepository: books);
    const alternate = TextbookCatalogEntry(
      id: 'another_publisher_5_2',
      title: '修订版',
      grade: 5,
      term: 2,
      cover: '',
      ready: true,
      totalUnits: 3,
      manifestPath: 'assets/textbooks/another_publisher_5_2/revised.json',
    );
    await repository.loadBook(futureEntry);
    await repository.loadBook(alternate);
    expect(books.requests, [futureEntry.manifestPath, alternate.manifestPath]);
  });

  test(
    'retries after async asset errors without poisoning the cache',
    () async {
      var attempt = 0;
      final books = ControlledBookRepository()
        ..handler = (_) async {
          if (attempt++ == 0) throw StateError('Temporary asset error');
          return futureBook;
        };
      final repository = TextbookCatalogRepository(bookRepository: books);
      await expectLater(repository.loadBook(futureEntry), throwsStateError);
      expect(await repository.loadBook(futureEntry), same(futureBook));
      expect(books.requests, hasLength(2));
    },
  );

  test('also retries after a synchronous backend exception', () async {
    var attempt = 0;
    final books = ControlledBookRepository()
      ..handler = (_) {
        if (attempt++ == 0) throw StateError('Synchronous asset error');
        return Future.value(futureBook);
      };
    final repository = TextbookCatalogRepository(bookRepository: books);
    await expectLater(repository.loadBook(futureEntry), throwsStateError);
    expect(await repository.loadBook(futureEntry), same(futureBook));
    expect(books.requests, hasLength(2));
  });

  test(
    'rejects a mismatched book ID and allows a corrected manifest retry',
    () async {
      var attempt = 0;
      final books = ControlledBookRepository()
        ..handler = (_) async => attempt++ == 0
            ? const Textbook(bookId: 'wrong_book', title: 'Wrong', pages: [])
            : futureBook;
      final repository = TextbookCatalogRepository(bookRepository: books);
      await expectLater(
        repository.loadBook(futureEntry),
        throwsFormatException,
      );
      expect(await repository.loadBook(futureEntry), same(futureBook));
      expect(books.requests, hasLength(2));
    },
  );

  test('opens any catalog book through its declared asset, without hardcoded routes', () async {
    final bundle = MemoryCatalogBundle({
      futureEntry.manifestPath: jsonEncode({
        'bookId': futureEntry.id,
        'title': futureEntry.title,
        'pages': [],
      }),
    });
    final repository = TextbookCatalogRepository(bundle: bundle);
    final book = await repository.loadBook(futureEntry);
    expect(book.bookId, futureEntry.id);
    expect(bundle.requests, {futureEntry.manifestPath: 1});
  });

  test(
    'bundled catalog describes existing resources and metadata-driven units',
    () async {
      final repository = TextbookCatalogRepository();
      final catalog = await repository.loadCatalog();
      expect(catalog, hasLength(2));
      final ready = catalog.first;
      expect(ready.cover, 'assets/textbooks/xiangshao_3_1/images/cover.webp');
      expect(ready.firstPageIndex, 8);
      expect(ready.pageCount, 65);
      expect(ready.units, hasLength(10));
      expect(catalog.last.ready, isFalse);
      expect(catalog.last.cover, isEmpty);
      final book = await repository.loadBook(ready);
      expect(book.bookId, ready.id);
      expect(book.pages, hasLength(ready.pageCount!));
      final pageIndexes = book.pages.map((page) => page.pageIndex).toSet();
      expect(
        pageIndexes,
        containsAll(ready.units.map((unit) => unit.startPage)),
      );
      expect(await rootBundle.load(ready.cover), isNotNull);
    },
  );
}
