import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:english_point_reading/services/sherpa_model_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  final original = Uint8List.fromList(
    utf8.encode(
      List.filled(
        64,
        'Sherpa offline original model bytes 0123456789\n',
      ).join(),
    ),
  );
  // Python lzma preset=6, CRC64 fixture exercises compressed LZMA2 blocks;
  // archive's XZEncoder currently emits uncompressed blocks only.
  final packed = base64Decode(
    '/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Au/AENdACmaCKdWAiC23OGDXmKRj1D10px4KkoRunl2p/JUMGebzeK4YnRPNOIfQnHeev0sDWo0Fo0jPwfueztuWJN2euwr+wAAAPgtr5UhAMpUAAFfwBcAAAAC6VYascRn+wIAAAAABFla',
  );

  Map<String, dynamic> manifest([Uint8List? source]) => {
    'size': original.length,
    'sha256': sha256.convert(original).toString(),
    if (source != null) ...{
      'asset': 'encoder.int8.onnx.xz',
      'compression': 'xz',
      'assetSize': source.length,
      'assetSha256': sha256.convert(source).toString(),
    },
  };

  Future<String> restore(Map<String, dynamic> metadata, Uint8List bytes) =>
      materializeSherpaModelAsset(
        name: 'encoder.int8.onnx',
        metadata: metadata,
        directory: directory,
        loadAsset: (_) async => bytes,
      );

  Future<void> expectNoPartials() async {
    final entries = await directory.list().toList();
    expect(entries.where((entry) => entry.path.endsWith('.partial')), isEmpty);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sherpa-model-assets-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('legacy raw manifest materializes byte-identical original', () async {
    final path = await restore(manifest(), original);
    expect(await File(path).readAsBytes(), original);
    await expectNoPartials();
  });

  test('packed LZMA2 asset restores original name and bytes', () async {
    String? requested;
    final path = await materializeSherpaModelAsset(
      name: 'encoder.int8.onnx',
      metadata: manifest(packed),
      directory: directory,
      loadAsset: (name) async {
        requested = name;
        return packed;
      },
    );
    expect(requested, 'encoder.int8.onnx.xz');
    expect(path.endsWith('/encoder.int8.onnx'), isTrue);
    expect(await File(path).readAsBytes(), original);
    await expectNoPartials();
  });

  test('valid original cache skips reading packed asset', () async {
    final cache = File('${directory.path}/encoder.int8.onnx');
    await cache.writeAsBytes(original);
    final path = await materializeSherpaModelAsset(
      name: 'encoder.int8.onnx',
      metadata: manifest(packed),
      directory: directory,
      loadAsset: (_) => throw StateError('must not load a cached asset'),
    );
    expect(path, cache.path);
    await expectNoPartials();
  });

  test('same-size corrupt cached model is repaired atomically', () async {
    final cache = File('${directory.path}/encoder.int8.onnx');
    await cache.writeAsBytes(List.filled(original.length, 0));
    await restore(manifest(packed), packed);
    expect(await cache.readAsBytes(), original);
    await expectNoPartials();
  });

  test('wrong-size cached model is replaced by verified raw asset', () async {
    final cache = File('${directory.path}/encoder.int8.onnx');
    await cache.writeAsBytes([1, 2, 3]);
    await restore(manifest(), original);
    expect(await cache.readAsBytes(), original);
    await expectNoPartials();
  });

  test('packed size mismatch never installs a model', () async {
    final metadata = manifest(packed)..['assetSize'] = packed.length + 1;
    await expectLater(restore(metadata, packed), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test('packed checksum mismatch is rejected before decoding', () async {
    final corrupted = Uint8List.fromList(packed)..[45] ^= 0x08;
    await expectLater(restore(manifest(packed), corrupted), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test('truncated XZ with matching asset metadata is rejected', () async {
    final truncated = Uint8List.fromList(packed.sublist(0, packed.length - 6));
    await expectLater(
      restore(manifest(truncated), truncated),
      throwsA(isA<ArchiveException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('malformed XZ with matching asset metadata is rejected', () async {
    final malformed = Uint8List.fromList(List.filled(132, 0));
    await expectLater(
      restore(manifest(malformed), malformed),
      throwsA(isA<ArchiveException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('internal XZ block checksum is verified', () async {
    final corrupted = Uint8List.fromList(packed)..[102] ^= 0x01;
    await expectLater(
      restore(manifest(corrupted), corrupted),
      throwsA(isA<ArchiveException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('decoded original checksum is independently verified', () async {
    final metadata = manifest(packed)
      ..['sha256'] = sha256.convert([1, 2, 3]).toString();
    await expectLater(restore(metadata, packed), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test('decoded original size is independently verified', () async {
    final metadata = manifest(packed)..['size'] = original.length + 1;
    await expectLater(restore(metadata, packed), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'failed replacement preserves existing cache and deletes partials',
    () async {
      final previous = Uint8List.fromList([1, 2, 3, 4]);
      final cache = File('${directory.path}/encoder.int8.onnx');
      await cache.writeAsBytes(previous);
      final truncated = Uint8List.fromList(packed.sublist(0, 70));
      await expectLater(
        restore(manifest(truncated), truncated),
        throwsA(isA<ArchiveException>()),
      );
      expect(await cache.readAsBytes(), previous);
      await expectNoPartials();
    },
  );

  test(
    'asset read failure preserves existing cache and leaves no partials',
    () async {
      final cache = File('${directory.path}/encoder.int8.onnx');
      await cache.writeAsBytes([1]);
      await expectLater(
        materializeSherpaModelAsset(
          name: 'encoder.int8.onnx',
          metadata: manifest(packed),
          directory: directory,
          loadAsset: (_) => throw StateError('asset missing'),
        ),
        throwsStateError,
      );
      expect(await cache.readAsBytes(), [1]);
      await expectNoPartials();
    },
  );

  test('unknown compression fails before reading bundled asset', () async {
    final metadata = manifest(packed)..['compression'] = 'zip';
    await expectLater(restore(metadata, packed), throwsFormatException);
    expect(await directory.list().toList(), isEmpty);
  });

  test('asset path traversal is rejected', () async {
    final metadata = manifest(packed)..['asset'] = '../encoder.int8.onnx.xz';
    await expectLater(restore(metadata, packed), throwsFormatException);
    expect(await directory.list().toList(), isEmpty);
  });
}
