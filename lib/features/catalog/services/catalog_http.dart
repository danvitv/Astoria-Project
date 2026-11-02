import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/credentials/secret_redactor.dart';
import '../../../core/utils/error_format.dart';

const _timeout = Duration(seconds: 20);

/// Browser User-Agent for the raw catalog Dio client. Without this, dart:io
/// sends `Dart/x (dart:io)`, which Cloudflare / WAF-fronted hosts (jannyai.com,
/// datacat.run) reject with 403. The janitor provider avoids this by routing
/// through a real WebView; janny/datacat use this client directly, so they must
/// carry a plausible browser UA themselves.
const _catalogUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

final _dio = Dio(
  BaseOptions(
    connectTimeout: _timeout,
    receiveTimeout: _timeout,
    responseType: ResponseType.plain,
    headers: {'User-Agent': _catalogUA},
    // Take all responses so we can surface the server's error body instead of
    // Dio throwing an opaque DioException before our own status check runs.
    validateStatus: (_) => true,
  ),
);

/// Replaces the transport under the shared catalog client.
///
/// The client is a file-private singleton on purpose — every provider must
/// carry the same browser UA — so this is the seam the provider tests use to
/// answer a request without a network round-trip.
@visibleForTesting
void setCatalogHttpAdapter(HttpClientAdapter adapter) {
  _dio.httpClientAdapter = adapter;
}

/// The HTTP status a catalog failure reported, or null when the request never
/// reached a server that answered.
///
/// Providers used to decide whether to re-authenticate by searching
/// `e.toString()` for `'401'`, which matches a 401 that merely appears
/// somewhere in the server's *body* just as readily as a real one — and reads
/// as a 401 for a request whose status was something else entirely.
int? catalogErrorStatus(Object error) =>
    error is DioException ? error.response?.statusCode : null;

/// Raises a [DioException] carrying the response, so callers can run it through
/// the shared `formatError()` (same friendly, localized handling as LLM
/// requests) instead of showing a raw dump. Debug publication and the exception
/// use retained request coverage AND the current snapshot, never raw credentials.
Never _throwHttp(Response<dynamic> res, SecretRedactor requestRedactor) {
  final error = _safeError(
    DioException.badResponse(
      statusCode: res.statusCode ?? 0,
      requestOptions: res.requestOptions,
      response: res,
    ),
    requestRedactor,
  );
  assert(() {
    final data = error.response?.data;
    final body = data is String ? data.trim() : '';
    debugPrint(
      '[catalog] HTTP ${error.response?.statusCode} ${error.requestOptions.uri}'
      '${body.isEmpty ? '' : ' — ${body.length > 500 ? '${body.substring(0, 500)}…' : body}'}',
    );
    return true;
  }());
  throw error;
}

final _defaultRedactor = SecretRedactor();

SecretRedactor _requestRedactor(Map<String, String> headers) =>
    (activeErrorRedactor ?? _defaultRedactor).withKnownSecrets([
      for (final entry in headers.entries)
        if (SecretRedactor.isSecretField(entry.key) ||
            entry.key.toLowerCase() == 'samwise')
          entry.value,
    ]);

DioException _safeError(DioException error, SecretRedactor requestRedactor) {
  final redactor = activeErrorRedactor ?? _defaultRedactor;
  final options = RequestOptions(
    path: redactor.redactUrl(
      requestRedactor.redactUrl(error.requestOptions.uri.toString()),
    ),
    method: error.requestOptions.method,
  );
  final original = error.response;
  Object? data = original?.data;
  if (data is List<int>) {
    try {
      data = utf8.decode(data);
    } catch (_) {
      data = SecretRedactor.removed;
    }
  }
  final safeData = data is String
      ? redactor.redactText(requestRedactor.redactText(data))
      : redactor.redactJson(requestRedactor.redactJson(data));
  return DioException(
    requestOptions: options,
    response: original == null
        ? null
        : Response<Object?>(
            requestOptions: options,
            statusCode: original.statusCode,
            data: safeData,
          ),
    type: error.type,
    message: 'Catalog request failed',
    stackTrace: StackTrace.empty,
  );
}

Future<Response<T>> _request<T>(
  Future<Response<T>> Function() send,
  SecretRedactor requestRedactor,
) async {
  try {
    return await send();
  } on DioException catch (error) {
    throw _safeError(error, requestRedactor);
  } catch (_) {
    // No arbitrary adapter/transport exception may leak its message/cause.
    throw DioException(
      requestOptions: RequestOptions(path: '[REDACTED]'),
      message: 'Catalog request failed',
      stackTrace: StackTrace.empty,
    );
  }
}

Future<Map<String, dynamic>> catalogGet(
  String url,
  Map<String, String> headers,
) async {
  final original = _requestRedactor(headers);
  final res = await _request(
    () => _dio.get<String>(
      url,
      options: Options(headers: headers, responseType: ResponseType.plain),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
  return _parseJson(res.data ?? '');
}

Future<String> catalogGetText(String url, Map<String, String> headers) async {
  final original = _requestRedactor(headers);
  final res = await _request(
    () => _dio.get<String>(
      url,
      options: Options(headers: headers, responseType: ResponseType.plain),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
  return res.data ?? '';
}

/// Raw bytes, for endpoints that answer with an image rather than JSON.
///
/// DataCat's Client API serves archived character images from an endpoint that
/// needs the same headers as every other call (client id, transfer lease), so
/// the bytes cannot be fetched with a bare `Dio()` the way a public avatar URL
/// can.
Future<List<int>> catalogGetBytes(
  String url,
  Map<String, String> headers,
) async {
  final original = _requestRedactor(headers);
  final res = await _request(
    () => _dio.get<List<int>>(
      url,
      options: Options(headers: headers, responseType: ResponseType.bytes),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
  return res.data ?? const [];
}

Future<Map<String, dynamic>> catalogPost(
  String url,
  Map<String, dynamic> body,
  Map<String, String> headers,
) async {
  final allHeaders = {'Content-Type': 'application/json', ...headers};
  final original = _requestRedactor(allHeaders);
  final res = await _request(
    () => _dio.post<String>(
      url,
      data: jsonEncode(body),
      options: Options(headers: allHeaders, responseType: ResponseType.plain),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
  return _parseJson(res.data ?? '');
}

/// A DELETE whose success is the status alone. Used by endpoints that answer
/// `204 No Content`, where parsing a body would only ever fail.
Future<void> catalogDelete(String url, Map<String, String> headers) async {
  final original = _requestRedactor(headers);
  final res = await _request(
    () => _dio.delete<String>(
      url,
      options: Options(headers: headers, responseType: ResponseType.plain),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
}

Map<String, dynamic> _parseJson(String text) {
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    throw Exception('Server returned invalid JSON');
  }
}

List<dynamic> _parseJsonList(String text) {
  try {
    return jsonDecode(text) as List<dynamic>;
  } catch (_) {
    throw Exception('Server returned invalid JSON');
  }
}

Future<List<dynamic>> catalogGetList(
  String url,
  Map<String, String> headers,
) async {
  final original = _requestRedactor(headers);
  final res = await _request(
    () => _dio.get<String>(
      url,
      options: Options(headers: headers, responseType: ResponseType.plain),
    ),
    original,
  );
  if (res.statusCode != null && res.statusCode! >= 400) {
    _throwHttp(res, original);
  }
  return _parseJsonList(res.data ?? '[]');
}
