import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/textbook.dart';

class TextbookRepository {
  TextbookRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  Future<Textbook> loadBookFromAsset(String jsonPath) async {
    final source = await _bundle.loadString(jsonPath);
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Textbook JSON must be an object.');
    }
    return Textbook.fromJson(json);
  }
}
