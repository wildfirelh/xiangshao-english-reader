import 'package:english_point_reading/models/textbook_catalog.dart';
import 'package:english_point_reading/models/textbook_unit.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> catalogEntryJson() => {
  'id': 'new_publisher_4_2',
  'title': '新教材 四年级下册',
  'grade': 4,
  'term': 2,
  'cover': '',
  'ready': true,
  'totalUnits': 2,
};

void main() {
  test(
    'parses an extensible entry with a default manifest and optional fields',
    () {
      final entry = TextbookCatalogEntry.fromJson(catalogEntryJson());
      expect(entry.id, 'new_publisher_4_2');
      expect(
        entry.manifestPath,
        'assets/textbooks/new_publisher_4_2/book.json',
      );
      expect(entry.grade, 4);
      expect(entry.term, 2);
      expect(entry.cover, isEmpty);
      expect(entry.firstPageIndex, isNull);
      expect(entry.pageCount, isNull);
      expect(entry.units, isEmpty);
    },
  );

  test('supports an explicit manifest and immutable catalog unit metadata', () {
    final entry = TextbookCatalogEntry.fromJson({
      ...catalogEntryJson(),
      'manifestPath': 'assets/textbooks/new_publisher_4_2/reading.json',
      'firstPageIndex': 5,
      'pageCount': 20,
      'units': [
        {'number': 1, 'title': 'A new beginning', 'startPage': 5},
        {'number': 2, 'title': 'At school', 'startPage': 15},
      ],
    });
    expect(entry.manifestPath, endsWith('/reading.json'));
    expect(entry.firstPageIndex, 5);
    expect(entry.pageCount, 20);
    expect(entry.units.last.label, 'Unit 2 At school');
    expect(
      () => entry.units.add(const TextbookUnit(3, 'Extra', 25)),
      throwsUnsupportedError,
    );
  });

  test('keeps a const constructor available for injected catalogs', () {
    const entry = TextbookCatalogEntry(
      id: 'test_1_1',
      title: 'Test',
      grade: 1,
      term: 1,
      cover: '',
      ready: false,
      totalUnits: 1,
    );
    expect(entry.manifestPath, 'assets/textbooks/test_1_1/book.json');
    expect(entry.ready, isFalse);
  });

  test('rejects missing required metadata', () {
    for (final key in [
      'id',
      'title',
      'grade',
      'term',
      'cover',
      'ready',
      'totalUnits',
    ]) {
      final json = catalogEntryJson()..remove(key);
      expect(
        () => TextbookCatalogEntry.fromJson(json),
        throwsFormatException,
        reason: key,
      );
    }
  });

  test('rejects invalid types and numeric metadata ranges', () {
    final badFields = <(String, Object?)>[
      ('id', 42),
      ('id', '../outside'),
      ('title', '   '),
      ('grade', 0),
      ('grade', 7),
      ('grade', 3.0),
      ('term', 0),
      ('term', 3),
      ('term', '1'),
      ('cover', null),
      ('ready', 'true'),
      ('totalUnits', -1),
      ('totalUnits', 10.0),
      ('firstPageIndex', 0),
      ('pageCount', -1),
      ('pageCount', '65'),
      ('manifestPath', 42),
      ('units', {}),
      ('units', ['Unit 1']),
    ];
    for (final (key, value) in badFields) {
      expect(
        () =>
            TextbookCatalogEntry.fromJson({...catalogEntryJson(), key: value}),
        throwsFormatException,
        reason: '$key=$value',
      );
    }
  });

  test('rejects remote and traversing cover or manifest paths', () {
    for (final key in ['cover', 'manifestPath']) {
      for (final path in [
        'https://example.com/book.json',
        '/assets/textbooks/book.json',
        'assets/textbooks/../../outside.json',
        'assets/textbooks/./book.json',
        'assets/textbooks//book.json',
        r'assets/textbooks\book.json',
        'assets/textbooks/%2e%2e/book.json',
        'assets/textbooks/book.json?token=secret',
        'assets/textbooks/book.json#section',
      ]) {
        expect(
          () =>
              TextbookCatalogEntry.fromJson({...catalogEntryJson(), key: path}),
          throwsFormatException,
          reason: '$key=$path',
        );
      }
    }
  });

  test('rejects duplicate unit numbers and out of range unit starts', () {
    for (final units in [
      [
        {'number': 1, 'title': 'One', 'startPage': 5},
        {'number': 1, 'title': 'Duplicate', 'startPage': 10},
      ],
      [
        {'number': 3, 'title': 'Too many', 'startPage': 5},
      ],
      [
        {'number': 1, 'title': 'Before book', 'startPage': 4},
      ],
      [
        {'number': 1, 'title': 'After book', 'startPage': 25},
      ],
      [
        {'number': 1, 'title': '', 'startPage': 5},
      ],
      [
        {'number': '1', 'title': 'One', 'startPage': 5},
      ],
      [
        {'number': 1, 'title': 'One', 'startPage': 5.0},
      ],
    ]) {
      expect(
        () => TextbookCatalogEntry.fromJson({
          ...catalogEntryJson(),
          'firstPageIndex': 5,
          'pageCount': 20,
          'units': units,
        }),
        throwsFormatException,
      );
    }
  });

  test('preserves existing unit metadata for legacy reader callers', () {
    expect(TextbookUnit.forBook('xiangshao_3_1'), hasLength(10));
    expect(TextbookUnit.forBook('future_book'), isEmpty);
    expect(TextbookUnit.xiangshaoGradeThree.first.startPage, 8);
    expect(TextbookUnit.xiangshaoGradeThree.last.startPage, 63);
  });
}
