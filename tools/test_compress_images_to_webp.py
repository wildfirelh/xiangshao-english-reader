import copy
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from tools.compress_images_to_webp import compress_images


class WebPCompressionTests(unittest.TestCase):
    def fixture(self, root):
        book = root / 'assets/textbooks/test'
        (book / 'images').mkdir(parents=True)
        Image.new('RGBA', (80, 100), (50, 100, 150, 120)).save(book / 'images/page_008.png')
        data = {'bookId': 'test', 'pages': [{'pageIndex': 8,
                'imagePath': 'assets/textbooks/test/images/page_008.png',
                'sentences': [{'id': 'one', 'translation': '你好', 'audioPath': 'audio.mp3',
                               'rect': {'left': 0.1, 'top': 0.2, 'right': 0.3, 'bottom': 0.4}}]}]}
        (book / 'book.json').write_text(json.dumps(data), encoding='utf-8')
        return book, data

    def test_converts_validates_updates_only_image_path_and_removes_png(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            book, original = self.fixture(root)
            report = compress_images(book, root)
            self.assertEqual(report['converted'], 1)
            self.assertEqual(report['quality'], 85)
            self.assertFalse((book / 'images/page_008.png').exists())
            with Image.open(book / 'images/page_008.webp') as image:
                self.assertEqual(image.size, (80, 100))
                self.assertEqual(image.getpixel((0, 0))[3], 120)
            expected = copy.deepcopy(original)
            expected['pages'][0]['imagePath'] = 'assets/textbooks/test/images/page_008.webp'
            self.assertEqual(json.loads((book / 'book.json').read_text(encoding='utf-8')), expected)
            self.assertEqual(compress_images(book, root)['converted'], 0)

    def test_corrupt_image_preserves_all_originals_and_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            book, _ = self.fixture(root)
            (book / 'images/page_009.png').write_bytes(b'not a PNG')
            manifest = (book / 'book.json').read_bytes()
            with self.assertRaises(OSError):
                compress_images(book, root)
            self.assertTrue((book / 'images/page_008.png').exists())
            self.assertTrue((book / 'images/page_009.png').exists())
            self.assertEqual((book / 'book.json').read_bytes(), manifest)

    def test_manifest_path_outside_images_is_rejected_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            book, data = self.fixture(root)
            data['pages'][0]['imagePath'] = '../outside.png'
            (book / 'book.json').write_text(json.dumps(data), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'outside'):
                compress_images(book, root)
            self.assertTrue((book / 'images/page_008.png').exists())


if __name__ == '__main__':
    unittest.main()
