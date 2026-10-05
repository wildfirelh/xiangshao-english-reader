import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Restores a bundled model into the private cache, preserving its original
/// bytes. A manifest without packing metadata remains compatible with raw
/// assets. Callers serialize preparation of the same model directory.
Future<String> materializeSherpaModelAsset({
  required String name,
  required Map<String, dynamic> metadata,
  required Directory directory,
  required Future<Uint8List> Function(String assetName) loadAsset,
}) async {
  final spec = _ModelAssetSpec.fromManifest(name, metadata);
  await directory.create(recursive: true);
  final destination = File('${directory.path}/$name');
  if (await _matchesFileOffThread(destination.path, spec.size, spec.sha256)) {
    return destination.path;
  }

  // Unique staging names also prevent stale partial files from a terminated
  // process being mistaken for an intact model.
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final staged = File('${destination.path}.$suffix.asset.partial');
  final decoded = File('${destination.path}.$suffix.partial');
  try {
    final bytes = await loadAsset(spec.assetName);
    if (bytes.lengthInBytes != spec.assetSize) {
      throw StateError('Model asset size mismatch: ${spec.assetName}');
    }
    await staged.writeAsBytes(bytes, flush: true);
    await _decodeAndVerifyOffThread(staged.path, decoded.path, spec);
    // Same-directory rename replaces an old invalid file only after the new
    // model passes both checks; an interrupted decode leaves the cache intact.
    await decoded.rename(destination.path);
    return destination.path;
  } finally {
    for (final partial in [staged, decoded]) {
      if (await partial.exists()) await partial.delete();
    }
  }
}

class _ModelAssetSpec {
  const _ModelAssetSpec({
    required this.name,
    required this.size,
    required this.sha256,
    required this.assetName,
    required this.assetSize,
    required this.assetSha256,
    required this.compression,
  });

  factory _ModelAssetSpec.fromManifest(
    String name,
    Map<String, dynamic> metadata,
  ) {
    final assetName = metadata['asset'] as String? ?? name;
    final compression = metadata['compression'] as String?;
    if (!_isBasename(name) || !_isBasename(assetName)) {
      throw FormatException('Invalid model asset filename: $name');
    }
    if (compression != null && compression != 'xz') {
      throw FormatException('Unsupported model compression: $compression');
    }
    final size = metadata['size'] as int;
    final originalHash = metadata['sha256'] as String;
    final assetSize = compression == null
        ? metadata['assetSize'] as int? ?? size
        : metadata['assetSize'] as int;
    final assetHash = compression == null
        ? metadata['assetSha256'] as String? ?? originalHash
        : metadata['assetSha256'] as String;
    if (size <= 0 || assetSize <= 0) {
      throw FormatException('Invalid model size: $name');
    }
    final hashPattern = RegExp(r'^[0-9a-fA-F]{64}$');
    if (!hashPattern.hasMatch(originalHash) ||
        !hashPattern.hasMatch(assetHash)) {
      throw FormatException('Invalid model checksum: $name');
    }
    return _ModelAssetSpec(
      name: name,
      size: size,
      sha256: originalHash.toLowerCase(),
      assetName: assetName,
      assetSize: assetSize,
      assetSha256: assetHash.toLowerCase(),
      compression: compression,
    );
  }

  static bool _isBasename(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains(RegExp(r'[/\\:]'));

  final String name;
  final int size;
  final String sha256;
  final String assetName;
  final int assetSize;
  final String assetSha256;
  final String? compression;
}

// These narrow wrappers keep bundle bytes and UI/plugin objects out of the
// closures sent to the worker isolate.
Future<bool> _matchesFileOffThread(
  String path,
  int size,
  String expectedHash,
) => Isolate.run(() => _matchesFile(path, size, expectedHash));

Future<bool> _matchesFile(String path, int size, String expectedHash) async {
  final file = File(path);
  if (!await file.exists() || await file.length() != size) return false;
  return (await sha256.bind(file.openRead()).first).toString() == expectedHash;
}

Future<void> _decodeAndVerifyOffThread(
  String stagedPath,
  String decodedPath,
  _ModelAssetSpec spec,
) => Isolate.run(() => _decodeAndVerify(stagedPath, decodedPath, spec));

Future<void> _decodeAndVerify(
  String stagedPath,
  String decodedPath,
  _ModelAssetSpec spec,
) async {
  if (!await _matchesFile(stagedPath, spec.assetSize, spec.assetSha256)) {
    throw StateError('Model asset checksum mismatch: ${spec.assetName}');
  }
  if (spec.compression == 'xz') {
    final input = InputFileStream(stagedPath);
    OutputFileStream? output;
    try {
      output = OutputFileStream(decodedPath);
      final success = XZDecoder().decodeStream(
        input,
        output,
        verify: true,
        throwOnError: true,
      );
      if (!success) throw StateError('Model XZ decoding failed: ${spec.name}');
    } finally {
      try {
        output?.closeSync();
      } finally {
        input.closeSync();
      }
    }
  } else {
    await File(stagedPath).rename(decodedPath);
  }
  if (!await _matchesFile(decodedPath, spec.size, spec.sha256)) {
    throw StateError('Decoded model size or checksum mismatch: ${spec.name}');
  }
}
