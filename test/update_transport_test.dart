import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:english_point_reading/services/update_transport.dart';

void main() {
  late Directory directory;
  late _Client client;
  late HttpUpdateTransport transport;
  final url = Uri.https('gitee.com', '/repo/releases/download/app.apk');
  final redirected = Uri.https('foruda.gitee.com', '/files/app.apk');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-transport-');
    client = _Client();
    transport = HttpUpdateTransport(client: client);
  });
  tearDown(() async {
    transport.close();
    await directory.delete(recursive: true);
  });

  test(
    'anonymous HTTPS redirect keeps requests free of login credentials',
    () async {
      client.responses.addAll([
        _Response(status: 302, location: redirected.toString()),
        _Response(bytes: [1, 2, 3]),
      ]);
      expect(
        await transport.getBytes(url, maxBytes: 100),
        Uint8List.fromList([1, 2, 3]),
      );
      expect(client.urls, [url, redirected]);
      for (final request in client.requests) {
        expect(request.followRedirects, isFalse);
        expect(
          request.recordedHeaders.values[HttpHeaders.cookieHeader],
          isNull,
        );
        expect(
          request.recordedHeaders.values[HttpHeaders.authorizationHeader],
          isNull,
        );
        expect(
          request.recordedHeaders.values[HttpHeaders.acceptEncodingHeader],
          'identity',
        );
      }
    },
  );

  test(
    'plain HTTP and URLs containing credentials never reach the network',
    () async {
      await expectLater(
        transport.getBytes(
          Uri.parse('http://example.com/app.apk'),
          maxBytes: 10,
        ),
        throwsFormatException,
      );
      await expectLater(
        transport.getBytes(
          Uri.parse('https://user:secret@example.com/a'),
          maxBytes: 10,
        ),
        throwsFormatException,
      );
      expect(client.urls, isEmpty);
    },
  );

  test('a downgrade redirect is refused', () async {
    client.responses.add(
      _Response(status: 302, location: 'http://example.com/a'),
    );
    await expectLater(
      transport.getBytes(url, maxBytes: 10),
      throwsFormatException,
    );
    expect(client.urls, [url]);
  });

  test(
    'oversized metadata is refused with and without a length header',
    () async {
      client.responses.add(_Response(bytes: [1, 2, 3], contentLength: 3));
      await expectLater(
        transport.getBytes(url, maxBytes: 2),
        throwsFormatException,
      );
      client.responses.add(_Response(bytes: [1, 2, 3], contentLength: -1));
      await expectLater(
        transport.getBytes(url, maxBytes: 2),
        throwsFormatException,
      );
    },
  );

  test(
    'non-success status and endless redirects cannot produce an APK',
    () async {
      client.responses.add(_Response(status: 403));
      await expectLater(
        transport.getBytes(url, maxBytes: 10),
        throwsA(isA<HttpException>()),
      );
      client.responses.addAll(
        List.generate(
          6,
          (_) => _Response(status: 302, location: url.toString()),
        ),
      );
      await expectLater(
        transport.getBytes(url, maxBytes: 10),
        throwsFormatException,
      );
    },
  );

  test('download writes bytes and reports exact progress', () async {
    client.responses.add(
      _Response(bytes: [0x50, 0x4b, 3, 4], contentLength: 4),
    );
    final file = File('${directory.path}/app.apk.part');
    final progress = <List<int>>[];
    await transport.download(
      url,
      file,
      expectedSize: 4,
      cancellation: DownloadCancellation(),
      onProgress: (received, total) => progress.add([received, total]),
    );
    expect(await file.readAsBytes(), [0x50, 0x4b, 3, 4]);
    expect(progress.last, [4, 4]);
  });

  test(
    'incorrect Content-Length refuses the body before creating a file',
    () async {
      client.responses.add(_Response(bytes: [1, 2], contentLength: 2));
      final file = File('${directory.path}/app.apk.part');
      await expectLater(
        transport.download(
          url,
          file,
          expectedSize: 4,
          cancellation: DownloadCancellation(),
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('truncated and oversized chunked APK streams are refused', () async {
    final file = File('${directory.path}/app.apk.part');
    for (final bytes in [
      [1, 2],
      [1, 2, 3, 4, 5],
    ]) {
      client.responses.add(_Response(bytes: bytes, contentLength: -1));
      await expectLater(
        transport.download(
          url,
          file,
          expectedSize: 4,
          cancellation: DownloadCancellation(),
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
    }
  });

  test('cancelling immediately aborts the active request', () async {
    client.responses.add(_Response(bytes: [1, 2, 3, 4], contentLength: 4));
    final cancellation = DownloadCancellation();
    await expectLater(
      transport.download(
        url,
        File('${directory.path}/app.apk.part'),
        expectedSize: 4,
        cancellation: cancellation,
        onProgress: (_, _) => cancellation.cancel(),
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(client.requests.single.aborted, isTrue);
  });
}

class _Client extends Fake implements HttpClient {
  final responses = <_Response>[];
  final requests = <_Request>[];
  final urls = <Uri>[];

  @override
  set connectionTimeout(Duration? value) {}
  @override
  set autoUncompress(bool value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    final request = _Request(responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  final recordedHeaders = _Headers();
  @override
  bool followRedirects = true;
  bool aborted = false;
  @override
  HttpHeaders get headers => recordedHeaders;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value.toString();
  @override
  String? value(String name) => values[name];
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response({
    List<int> bytes = const [],
    int status = 200,
    int? contentLength,
    String? location,
  }) : _bytes = bytes,
       statusCode = status,
       contentLength = contentLength ?? bytes.length {
    if (location != null) {
      _headers.values[HttpHeaders.locationHeader] = location;
    }
  }
  final List<int> _bytes;
  final _Headers _headers = _Headers();
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  HttpHeaders get headers => _headers;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([_bytes]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
