import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_auth.dart';

class _DropboxResponseAdapter implements HttpClientAdapter {
  _DropboxResponseAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    409,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DropboxAdapter dropboxWithResponse(String body) {
    final auth = DropboxAuth()
      ..loadTokens({
        'dropbox': {
          'access_token': 'test-token',
          'refresh_token': 'test-refresh',
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      });
    final dio = Dio()..httpClientAdapter = _DropboxResponseAdapter(body);
    return DropboxAdapter(auth, dio: dio);
  }

  const missing =
      '{"error_summary":"path/not_found/...",'
      '"error":{".tag":"path","path":{".tag":"not_found"}}}';

  test('missing binary returns CloudFileNotFoundException', () async {
    final dropbox = dropboxWithResponse(missing);

    await expectLater(
      dropbox.downloadBinary('/Astoria-dev/gallery/card/avatar.png'),
      throwsA(isA<CloudFileNotFoundException>()),
    );
  });

  test('missing JSON returns CloudFileNotFoundException', () async {
    final dropbox = dropboxWithResponse(missing);

    await expectLater(
      dropbox.download('/Astoria-dev/manifest.json'),
      throwsA(isA<CloudFileNotFoundException>()),
    );
  });

  test('another Dropbox 409 is not treated as a missing file', () async {
    final dropbox = dropboxWithResponse(
      jsonEncode({
        'error_summary': 'path/restricted_content/...',
        'error': {
          '.tag': 'path',
          'path': {'.tag': 'restricted_content'},
        },
      }),
    );

    await expectLater(
      dropbox.downloadBinary('/Astoria-dev/gallery/card/avatar.png'),
      throwsA(isA<DioException>()),
    );
  });
}
