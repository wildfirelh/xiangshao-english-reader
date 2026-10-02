class Textbook {
  const Textbook({
    required this.bookId,
    required this.title,
    required this.pages,
  });

  final String bookId;
  final String title;
  final List<TextbookPage> pages;

  factory Textbook.fromJson(Map<String, dynamic> json) => Textbook(
    bookId: json['bookId'] as String,
    title: json['title'] as String,
    pages: (json['pages'] as List<dynamic>)
        .map((item) => TextbookPage.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class TextbookPage {
  const TextbookPage({
    required this.pageIndex,
    required this.imagePath,
    required this.sentences,
  });

  final int pageIndex;
  final String imagePath;
  final List<PointSentence> sentences;

  factory TextbookPage.fromJson(Map<String, dynamic> json) => TextbookPage(
    pageIndex: json['pageIndex'] as int,
    imagePath: json['imagePath'] as String,
    sentences: (json['sentences'] as List<dynamic>)
        .map((item) => PointSentence.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class PointSentence {
  const PointSentence({
    required this.id,
    required this.text,
    this.translation,
    required this.audioPath,
    required this.rect,
  });

  final String id;
  final String text;
  final String? translation;
  final String audioPath;
  final NormalizedRect rect;

  factory PointSentence.fromJson(Map<String, dynamic> json) => PointSentence(
    id: json['id'] as String,
    text: json['text'] as String,
    translation: json['translation'] as String?,
    audioPath: json['audioPath'] as String,
    rect: NormalizedRect.fromJson(json['rect'] as Map<String, dynamic>),
  );
}

class NormalizedRect {
  const NormalizedRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  }) : assert(left >= 0 && left <= 1),
       assert(top >= 0 && top <= 1),
       assert(right >= left && right <= 1),
       assert(bottom >= top && bottom <= 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  factory NormalizedRect.fromJson(Map<String, dynamic> json) {
    final left = (json['left'] as num).toDouble();
    final top = (json['top'] as num).toDouble();
    final right = (json['right'] as num).toDouble();
    final bottom = (json['bottom'] as num).toDouble();
    if (!left.isFinite ||
        !top.isFinite ||
        !right.isFinite ||
        !bottom.isFinite ||
        left < 0 ||
        top < 0 ||
        right > 1 ||
        bottom > 1 ||
        left > right ||
        top > bottom) {
      throw const FormatException(
        'NormalizedRect coordinates must be ordered and within 0..1.',
      );
    }
    return NormalizedRect(left: left, top: top, right: right, bottom: bottom);
  }
}
