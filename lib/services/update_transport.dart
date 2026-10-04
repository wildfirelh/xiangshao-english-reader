import 'dart:io';
import 'dart:typed_data';

import '../models/app_update.dart';

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class DownloadCancellation {
  bool _cancelled = false;
  final List<void Function()> _callbacks = [];

  bool get isCancelled => _cancelled;

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelled();
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in _callbacks) {
      callback();
    }
    _callbacks.clear();
  }
}

abstract interface class UpdateTransport {
  Future<Uint8List> getBytes(Uri url, {required int maxBytes});
  Future<void> download(
    Uri url,
    File destination, {
    required int expectedSize,
    required DownloadCancellation cancellation,
    required void Function(int received, int total) onProgress,
  });
  void close();
}

/// Anonymous HTTPS only; redirects retain neither cookies nor credentials.
class HttpUpdateTransport implements UpdateTransport {
  HttpUpdateTransport({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 20);
    _client.autoUncompress = false;
  }

  final HttpClient _client;
  static const _timeout = Duration(seconds: 40);

  Future<HttpClientResponse> _open(
    Uri url, [
    DownloadCancellation? cancellation,
  ]) async {
    var next = url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!isSecureUpdateUri(next)) {
        throw const FormatException('Update connection must use HTTPS');
      }
      cancellation?.throwIfCancelled();
      final request = await _client.getUrl(next).timeout(_timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'XiangshaoReader-Updater',
      );
      cancellation?.onCancel(() => request.abort(const DownloadCancelled()));
      cancellation?.throwIfCancelled();
      final response = await request.close().timeout(_timeout);
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(_timeout);
        if (location == null) {
          throw const FormatException('Missing download redirect');
        }
        next = next.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(_timeout);
        throw HttpException('Update server returned ${response.statusCode}');
      }
      return response;
    }
    throw const FormatException('Too many update redirects');
  }

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    final response = await _open(url);
    if (response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      throw const FormatException('Update metadata is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('Update metadata is too large');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> download(
    Uri url,
    File destination, {
    required int expectedSize,
    required DownloadCancellation cancellation,
    required void Function(int received, int total) onProgress,
  }) async {
    final response = await _open(url, cancellation);
    if (response.contentLength >= 0 && response.contentLength != expectedSize) {
      await response.listen(null).cancel();
      throw const FormatException('APK content length does not match manifest');
    }
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(_timeout)) {
        cancellation.throwIfCancelled();
        received += chunk.length;
        if (received > expectedSize) {
          throw const FormatException('APK is larger than its manifest');
        }
        sink.add(chunk);
        onProgress(received, expectedSize);
      }
      cancellation.throwIfCancelled();
      if (received != expectedSize) {
        throw const FormatException('Incomplete APK download');
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  @override
  void close() => _client.close(force: true);
}
