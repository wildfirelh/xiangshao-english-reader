import copy
import unittest

from tools.patch_translations import correct_translation, patch_book


class TranslationPatchTests(unittest.TestCase):
    def test_latin_names_touching_chinese_and_titles_with_periods(self):
        actual, _ = correct_translation('Hello!', '我是Peter，Miss Li和Mr. Zhang来了，Tim也是。')
        self.assertEqual(actual, '我是彼得，李老师和张老师来了，蒂姆也是。')

    def test_does_not_replace_substrings_or_unrelated_chinese_words(self):
        original = 'timing, timetable, Peterborough, Anniversary，添加恐龙。'
        self.assertEqual(correct_translation('Tim and Dino.', original)[0], original)
        self.assertEqual(correct_translation('A dinosaur.', '恐龙和凌凌。')[0], '恐龙和凌凌。')
        self.assertEqual(correct_translation('Dino sees a dinosaur.', '迪诺看到一只恐龙。')[0], '迪诺看到一只恐龙。')

    def test_known_mistranslations_and_missing_names(self):
        self.assertEqual(correct_translation('Lingling', '凌凌')[0], '玲玲')
        self.assertEqual(correct_translation('Mingming', '茗茗')[0], '明明')
        self.assertEqual(correct_translation('Anne', '三胞菌属')[0], '安妮')
        self.assertEqual(correct_translation('Hello, I’m Tim.', '你好，我是')[0], '你好，我是蒂姆。')

    def test_only_translation_changes_and_patch_is_idempotent(self):
        book = {'bookId': 'example', 'pages': [{'pageIndex': 8, 'imagePath': 'image.png',
          'sentences': [{'id': 'one', 'text': 'Peter', 'translation': 'Peter',
                        'audioPath': 'audio.mp3', 'rect': {'left': 0.2}},
                       {'id': 'two', 'text': 'Hello', 'translation': None}]}]}
        before = copy.deepcopy(book)
        patched, stats = patch_book(book)
        self.assertEqual(book, before)
        self.assertEqual(stats['scanned'], 2)
        self.assertEqual(stats['changed'], 1)
        expected = copy.deepcopy(before)
        expected['pages'][0]['sentences'][0]['translation'] = '彼得'
        self.assertEqual(patched, expected)
        self.assertEqual(patch_book(patched)[1]['changed'], 0)


if __name__ == '__main__':
    unittest.main()
