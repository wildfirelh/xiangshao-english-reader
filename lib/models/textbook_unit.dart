class TextbookUnit {
  const TextbookUnit(this.number, this.title, this.startPage);

  final int number;
  final String title;
  // Physical PDF page, matching TextbookPage.pageIndex (not a list offset).
  final int startPage;

  String get label => 'Unit $number $title';
  int get printedPage => startPage - 7;

  static List<TextbookUnit> forBook(String bookId) =>
      bookId == 'xiangshao_3_1' ? xiangshaoGradeThree : const [];

  static const xiangshaoGradeThree = [
    TextbookUnit(1, 'Hello!', 8),
    TextbookUnit(2, "What's your name?", 13),
    TextbookUnit(3, 'How old are you?', 18),
    TextbookUnit(4, 'This is my family', 28),
    TextbookUnit(5, 'Is this your pen?', 33),
    TextbookUnit(6, 'Touch your head', 38),
    TextbookUnit(7, 'What colour is it?', 48),
    TextbookUnit(8, "What's this?", 53),
    TextbookUnit(9, 'I like apples', 58),
    TextbookUnit(10, 'Happy birthday!', 63),
  ];
}
