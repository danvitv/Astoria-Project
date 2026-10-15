import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_read_only_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/dropbox/dropbox_auth.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'synthetic-access-secret';
const _providerSecret = 'synthetic-provider-body-secret';

class _RecordingHttpAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  String body = '{"complete":"body"}';
  Object? failure;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final error = failure;
    if (error != null) throw error;
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (status >= 300 && status < 400)
          'location': ['https://untrusted.example/$_providerSecret'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Makes accidentally using ordinary refreshing auth fail even on valid tokens.
class _DiagnosticOnlyAuth extends DropboxAuth {
  int regularTokenCalls = 0;

  @override
  Future<String> getValidToken() async {
    regularTokenCalls++;
    throw StateError('Diagnostic must not use refreshing auth');
  }
}

void _loadSyntheticTokens(
  DropboxAuth auth, {
  String? token = _token,
  int? expiresAt,
  String? refreshToken = 'synthetic-refresh-secret',
}) {
  auth.loadTokens({
    'dropbox': {
      'access_token': token,
      'refresh_token': refreshToken,
      'expires_at': expiresAt,
    },
  });
}

Matcher _safeFailure(CloudReadOnlyDownloadStatus status, String text) =>
    isA<CloudReadOnlyDownloadException>()
        .having((error) => error.status, 'status', status)
        .having((error) => error.toString(), 'fixed text', text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _DiagnosticOnlyAuth auth;
  late _RecordingHttpAdapter http;
  late DropboxAdapter dropbox;
  late SharedPreferences prefs;
  late Map<String, Object?> beforePrefs;
  late Map<String, dynamic>? beforeTokens;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'gz_sync_tokens': '{"sentinel":"synthetic-prefs-secret"}',
      'unrelated': 42,
    });
    prefs = await SharedPreferences.getInstance();
    beforePrefs = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    auth = _DiagnosticOnlyAuth();
    _loadSyntheticTokens(
      auth,
      expiresAt: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    beforeTokens = auth.saveTokens();
    http = _RecordingHttpAdapter();
    dropbox = DropboxAdapter(auth, dio: Dio()..httpClientAdapter = http);
  });

  tearDown(() {
    expect(auth.regularTokenCalls, 0);
    expect(auth.saveTokens(), beforeTokens);
    expect({
      for (final key in prefs.getKeys()) key: prefs.get(key),
    }, beforePrefs);
  });

  for (final expiry in ['expired', 'unknown']) {
    test(
      '$expiry token rejects synchronously without HTTP or writes',
      () async {
        _loadSyntheticTokens(
          auth,
          expiresAt: expiry == 'expired'
              ? DateTime.now().millisecondsSinceEpoch - 1
              : null,
        );
        beforeTokens = auth.saveTokens();
        expect(
          auth.requireExistingTokenForReadOnlyDownload,
          throwsA(
            _safeFailure(
              CloudReadOnlyDownloadStatus.reauthenticate,
              'Cloud diagnostic requires reauthentication.',
            ),
          ),
        );
        await expectLater(
          dropbox.downloadReadOnly(cloudPath('character', 'card_1')),
          throwsA(isA<CloudReadOnlyDownloadException>()),
        );
        expect(http.requests, isEmpty);
      },
    );
  }

  for (final token in <String?>[null, '']) {
    test('absent/empty token rejects without HTTP', () async {
      _loadSyntheticTokens(auth, token: token);
      beforeTokens = auth.saveTokens();
      await expectLater(
        dropbox.downloadReadOnly(cloudPath('character', 'card-1')),
        throwsA(
          _safeFailure(
            CloudReadOnlyDownloadStatus.reauthenticate,
            'Cloud diagnostic requires reauthentication.',
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });
  }

  for (final type in ['character', 'character_knowledge', 'memory_graph']) {
    test(
      '$type downloads only official content endpoint with channel mapping',
      () async {
        final path = cloudPath(type, 'Card_1-session-2');
        expect(dropbox, isA<CloudReadOnlyAdapter>());
        expect(await dropbox.downloadReadOnly(path), http.body);
        expect(http.requests, hasLength(1));
        final request = http.requests.single;
        expect(
          request.uri.toString(),
          'https://content.dropboxapi.com/2/files/download',
        );
        expect(request.method, 'POST');
        expect(request.data, isNull);
        expect(request.headers['Authorization'], 'Bearer $_token');
        expect(jsonDecode(request.headers['Dropbox-API-Arg'] as String), {
          'path':
              '${isStableChannel ? '' : '/$buildChannel'}'
              '${path.substring(cloudBase.length)}',
        });
        expect(request.followRedirects, isFalse);
        expect(request.responseType, ResponseType.plain);
      },
    );
  }

  test(
    'returns full body without diagnostic parsing/transfer truncation',
    () async {
      http.body = 'x' * (256 * 1024 + 1);
      expect(
        await dropbox.downloadReadOnly(cloudPath('character', 'id')),
        http.body,
      );
      expect(http.requests, hasLength(1));
    },
  );

  for (final entry in {
    401: CloudReadOnlyDownloadStatus.reauthenticate,
    409: CloudReadOnlyDownloadStatus.missing,
    403: CloudReadOnlyDownloadStatus.unreadable,
    500: CloudReadOnlyDownloadStatus.unreadable,
    302: CloudReadOnlyDownloadStatus.unreadable,
    307: CloudReadOnlyDownloadStatus.unreadable,
  }.entries) {
    test('HTTP ${entry.key} is fixed safe status, no retry/redirect', () async {
      http.status = entry.key;
      http.body = '$_providerSecret $_token';
      final expectedText = switch (entry.value) {
        CloudReadOnlyDownloadStatus.reauthenticate =>
          'Cloud diagnostic requires reauthentication.',
        CloudReadOnlyDownloadStatus.missing =>
          'Cloud diagnostic file is missing.',
        _ => 'Cloud diagnostic file is unreadable.',
      };
      await expectLater(
        dropbox.downloadReadOnly(cloudPath('character', 'id')),
        throwsA(_safeFailure(entry.value, expectedText)),
      );
      expect(http.requests, hasLength(1));
      expect(http.requests.single.followRedirects, isFalse);
    });
  }

  test('transport failure strips raw Dio request, body and cause', () async {
    http.failure = DioException(
      requestOptions: RequestOptions(
        path: 'https://untrusted.example/$_providerSecret',
        headers: {'Authorization': 'Bearer $_token'},
      ),
      type: DioExceptionType.connectionError,
      error: StateError(_providerSecret),
      message: _token,
    );
    await expectLater(
      dropbox.downloadReadOnly(cloudPath('character', 'id')),
      throwsA(
        _safeFailure(
          CloudReadOnlyDownloadStatus.unreadable,
          'Cloud diagnostic file is unreadable.',
        ),
      ),
    );
    expect(http.requests, hasLength(1));
  });

  test('unexpected transport errors also discard raw causes', () async {
    http.failure = StateError('$_providerSecret $_token');
    await expectLater(
      dropbox.downloadReadOnly(cloudPath('character', 'id')),
      throwsA(
        _safeFailure(
          CloudReadOnlyDownloadStatus.unreadable,
          'Cloud diagnostic file is unreadable.',
        ),
      ),
    );
    expect(http.requests, hasLength(1));
  });

  test('valid access token needs no refresh credential', () async {
    _loadSyntheticTokens(
      auth,
      refreshToken: null,
      expiresAt: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    beforeTokens = auth.saveTokens();
    expect(
      await dropbox.downloadReadOnly(cloudPath('character', 'id')),
      http.body,
    );
    expect(http.requests, hasLength(1));
  });

  test('invalid diagnostic paths never reach HTTP', () async {
    for (final path in [
      '$cloudBase/manifest.json',
      cloudPath('persona', 'id'),
      '$cloudBase/gallery/id/image.png',
      '/characters/id.json',
      '${cloudBase}other/characters/id.json',
      '$cloudBase/characters/.json',
      '$cloudBase/characters/../id.json',
      '$cloudBase/characters/a/../id.json',
      '$cloudBase/characters/id.json?token=$_token',
      '$cloudBase/characters/id.json#fragment',
      '$cloudBase/characters/id%2Fother.json',
      '$cloudBase/characters/%2e%2e.json',
      '$cloudBase/characters/id\\other.json',
      '$cloudBase/characters/id.json\n',
      '$cloudBase/characters/id.json/extra',
      '$cloudBase//characters/id.json',
      'https://untrusted.example/characters/id.json',
    ]) {
      await expectLater(
        dropbox.downloadReadOnly(path),
        throwsA(
          _safeFailure(
            CloudReadOnlyDownloadStatus.invalidPath,
            'Cloud diagnostic path is invalid.',
          ),
        ),
      );
    }
    expect(http.requests, isEmpty);
  });

  test('ordinary token accessor/download preserve existing behavior', () async {
    final ordinaryAuth = DropboxAuth();
    _loadSyntheticTokens(ordinaryAuth);
    // Ordinary auth still accepts legacy tokens with unknown expiry.
    expect(await ordinaryAuth.getValidToken(), _token);
    final ordinary = DropboxAdapter(
      ordinaryAuth,
      dio: Dio()..httpClientAdapter = http,
    );
    expect(
      await ordinary.download(cloudPath('manifest', 'manifest')),
      http.body,
    );
    http.status = 409;
    http.body = '{"error_summary":"path/not_found/..."}';
    await expectLater(
      ordinary.download(cloudPath('manifest', 'manifest')),
      throwsA(isA<CloudFileNotFoundException>()),
    );
    // Ordinary expired auth still attempts refresh (fails here before HTTP).
    _loadSyntheticTokens(ordinaryAuth, expiresAt: 0, refreshToken: null);
    await expectLater(ordinaryAuth.getValidToken(), throwsStateError);
  });
}
