import 'textbook_unit.dart';

/// Lightweight metadata: opening the shelf does not load textbook pages/audio.
class TextbookCatalogEntry {
  const TextbookCatalogEntry({
    required this.id,
    required this.title,
    required this.grade,
    required this.term,
    required this.cover,
    required this.ready,
    required this.totalUnits,
    String? manifestPath,
    this.firstPageIndex,
    this.pageCount,
    this.units = const [],
    // A public override stays nullable; the getter always resolves a local path.
    // ignore: prefer_initializing_formals
  }) : _manifestPath = manifestPath;

  final String id;
  final String title;
  final int grade;
  final int term;
  final String cover;
  final bool ready;
  final int totalUnits;
  final String? _manifestPath;
  final int? firstPageIndex;
  final int? pageCount;
  final List<TextbookUnit> units;

  String get manifestPath => _manifestPath ?? 'assets/textbooks/$id/book.json';

  factory TextbookCatalogEntry.fromJson(Map<String, dynamic> json) {
    final id = _string(json, 'id');
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException(
        'Textbook id must be a safe asset identifier.',
      );
    }
    final title = _string(json, 'title');
    final grade = _integer(json, 'grade', minimum: 1, maximum: 6);
    final term = _integer(json, 'term', minimum: 1, maximum: 2);
    final cover = _string(json, 'cover', allowEmpty: true);
    if (cover.isNotEmpty) _validateAssetPath(cover, 'cover');
    final ready = json['ready'];
    if (ready is! bool) {
      throw const FormatException('Textbook ready must be a boolean.');
    }
    final totalUnits = _integer(json, 'totalUnits', minimum: 0);
    final manifest = json['manifestPath'];
    if (manifest != null) {
      if (manifest is! String) {
        throw const FormatException('Textbook manifestPath must be a string.');
      }
      _validateAssetPath(manifest, 'manifestPath');
    }
    final firstPageIndex = _optionalPositiveInteger(json, 'firstPageIndex');
    final pageCount = _optionalPositiveInteger(json, 'pageCount');
    final rawUnits = json['units'];
    if (rawUnits != null && rawUnits is! List) {
      throw const FormatException('Textbook units must be a list.');
    }
    final units = <TextbookUnit>[];
    final numbers = <int>{};
    for (final raw in rawUnits as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Textbook unit must be an object.');
      }
      final unit = TextbookUnit.fromJson(raw);
      if (!numbers.add(unit.number) || unit.number > totalUnits) {
        throw const FormatException(
          'Textbook unit numbers must be unique and within totalUnits.',
        );
      }
      if (firstPageIndex != null &&
          (unit.startPage < firstPageIndex ||
              (pageCount != null &&
                  unit.startPage >= firstPageIndex + pageCount))) {
        throw const FormatException(
          'Textbook unit starts outside the declared page range.',
        );
      }
      units.add(unit);
    }
    return TextbookCatalogEntry(
      id: id,
      title: title,
      grade: grade,
      term: term,
      cover: cover,
      ready: ready,
      totalUnits: totalUnits,
      manifestPath: manifest as String?,
      firstPageIndex: firstPageIndex,
      pageCount: pageCount,
      units: List<TextbookUnit>.unmodifiable(units),
    );
  }

  static String _string(
    Map<String, dynamic> json,
    String key, {
    bool allowEmpty = false,
  }) {
    final value = json[key];
    if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
      throw FormatException('Textbook $key must be a non-empty string.');
    }
    return value;
  }

  static int _integer(
    Map<String, dynamic> json,
    String key, {
    required int minimum,
    int? maximum,
  }) {
    final value = json[key];
    if (value is! int ||
        value < minimum ||
        (maximum != null && value > maximum)) {
      throw FormatException('Textbook $key is outside its integer range.');
    }
    return value;
  }

  static int? _optionalPositiveInteger(Map<String, dynamic> json, String key) =>
      json[key] == null ? null : _integer(json, key, minimum: 1);

  static void _validateAssetPath(String path, String field) {
    if (!path.startsWith('assets/textbooks/') ||
        RegExp(r'[\\\x00-\x1f\x7f:?%#]').hasMatch(path) ||
        path
            .split('/')
            .any(
              (segment) => segment.isEmpty || segment == '.' || segment == '..',
            )) {
      throw FormatException('Textbook $field must be a local textbook asset.');
    }
  }
}
