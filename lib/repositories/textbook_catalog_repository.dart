import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/textbook.dart';
import '../models/textbook_catalog.dart';
import 'textbook_repository.dart';

/// Catalog metadata loads independently; full books load on selection only.
class TextbookCatalogRepository {
  TextbookCatalogRepository({
    AssetBundle? bundle,
    TextbookRepository? bookRepository,
  }) : _bundle = bundle ?? rootBundle,
       _bookRepository = bookRepository ?? TextbookRepository(bundle: bundle);

  final AssetBundle _bundle;
  final TextbookRepository _bookRepository;
  final Map<(String, String), Future<Textbook>> _books = {};

  Future<List<TextbookCatalogEntry>> loadCatalog({
    String jsonPath = 'assets/textbooks/catalog.json',
  }) async {
    final decoded = jsonDecode(await _bundle.loadString(jsonPath));
    if (decoded is! List) {
      throw const FormatException('Textbook catalog JSON must be a list.');
    }
    final entries = <TextbookCatalogEntry>[];
    final ids = <String>{};
    for (final value in decoded) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException(
          'Textbook catalog entries must be objects.',
        );
      }
      final entry = TextbookCatalogEntry.fromJson(value);
      if (!ids.add(entry.id)) {
        throw FormatException('Duplicate textbook id: ${entry.id}.');
      }
      entries.add(entry);
    }
    return List<TextbookCatalogEntry>.unmodifiable(entries);
  }

  Future<Textbook> loadBook(TextbookCatalogEntry entry) {
    if (!entry.ready) {
      return Future<Textbook>.error(
        StateError('Textbook ${entry.id} is not ready.'),
      );
    }
    final key = (entry.id, entry.manifestPath);
    return _books.putIfAbsent(key, () => _loadBook(entry, key));
  }

  Future<Textbook> _loadBook(
    TextbookCatalogEntry entry,
    (String, String) key,
  ) async {
    try {
      final book = await Future<Textbook>.sync(
        () => _bookRepository.loadBookFromAsset(entry.manifestPath),
      );
      if (book.bookId != entry.id) {
        throw FormatException(
          'Textbook manifest id ${book.bookId} does not match ${entry.id}.',
        );
      }
      return book;
    } catch (_) {
      // A temporary failure must not poison the cache or disable retry.
      _books.remove(key);
      rethrow;
    }
  }
}
