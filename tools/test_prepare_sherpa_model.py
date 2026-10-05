"""Verify lossless bundled models and corrupted packing cache recovery."""
import hashlib
import json
import lzma
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_sherpa_model as model


class PackedModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.raw = b'ONNX fixture\x00\xff\x81' * 2000
        self.sha = hashlib.sha256(self.raw).hexdigest()
        self.target = self.root / 'encoder.int8.onnx'
        self.target.write_bytes(self.raw)

    def test_manifest_keeps_original_hash_and_bundled_xz_identity(self):
        files = {'encoder.int8.onnx': ('source.onnx', len(self.raw), self.sha)}
        with patch.object(model, 'FILES', files), patch.object(model.urllib.request, 'urlopen') as network:
            model.prepare(self.root)
        network.assert_not_called()
        metadata = json.loads((self.root / 'model.json').read_text())['files']['encoder.int8.onnx']
        packed = self.root / metadata['asset']
        self.assertEqual(metadata['sha256'], self.sha)
        self.assertEqual(metadata['size'], len(self.raw))
        self.assertEqual(metadata['compression'], 'xz')
        self.assertEqual(metadata['assetSize'], packed.stat().st_size)
        self.assertEqual(metadata['assetSha256'], hashlib.sha256(packed.read_bytes()).hexdigest())
        self.assertEqual(lzma.decompress(packed.read_bytes()), self.raw)

    def test_valid_packed_cache_not_rewritten_and_corruption_repaired(self):
        metadata = model.pack_model(self.target, len(self.raw), self.sha)
        packed = self.root / metadata['asset']
        before = packed.stat().st_mtime_ns
        self.assertEqual(model.pack_model(self.target, len(self.raw), self.sha), metadata)
        self.assertEqual(packed.stat().st_mtime_ns, before)
        packed.write_bytes(b'truncated XZ')
        repaired = model.pack_model(self.target, len(self.raw), self.sha)
        self.assertEqual(repaired, metadata)
        self.assertEqual(lzma.decompress(packed.read_bytes()), self.raw)

    def test_failed_pack_leaves_no_partial_and_preserves_old_packed_file(self):
        packed = self.target.with_suffix('.onnx.xz')
        packed.write_bytes(b'old invalid cache')
        original_open = model.lzma.open
        def failing_open(path, mode, **kwargs):
            if mode == 'wb':
                Path(path).write_bytes(b'partial')
                raise OSError('simulated write failure')
            return original_open(path, mode, **kwargs)
        with patch.object(model.lzma, 'open', side_effect=failing_open):
            with self.assertRaises(OSError):
                model.pack_model(self.target, len(self.raw), self.sha)
        self.assertEqual(packed.read_bytes(), b'old invalid cache')
        self.assertFalse(packed.with_suffix('.xz.part').exists())


if __name__ == '__main__':
    unittest.main()
