import 'dart:convert';

import 'package:dio/dio.dart';

import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

/// Fixed safe exception; never retains Dio requests, response bodies or causes.
final class DatacatAnonymousHttpException implements Exception {
  const DatacatAnonymousHttpException(this.status);
  final int status;
  @override
  String toString() => 'DataCat extraction request failed (HTTP $status)';
}

/// Original anonymous site endpoints, NOT the linked Client API. This native
/// transport refuses redirects on each request, including injected Dio clients.
final class DatacatAnonymousTransport {
  DatacatAnonymousTransport({
    required SecretRedactionCoordinator redaction,
    Dio? dio,
  }) : _redaction = redaction,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 20),
               responseType: ResponseType.plain,
               validateStatus: (_) => true,
               followRedirects: false,
             ),
           );

  static const _base = 'https://datacat.run';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
  static const _aliases = {
    'sessionToken',
    'session_token',
    'token',
    'accessToken',
    'access_token',
    'userToken',
    'user_token',
  };
  final SecretRedactionCoordinator _redaction;
  final Dio _dio;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _dio.close();
  }

  void _check(bool Function() current) {
    if (_disposed || !current()) throw const CredentialVaultAdmissionDenied();
  }

  Map<String, dynamic> _decode(Object? raw) {
    try {
      final data = raw is String ? jsonDecode(raw) : raw;
      return data is Map ? data.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  void _register(Map<String, dynamic> data) {
    void aliases(Map<Object?, Object?> value) {
      for (final key in _aliases) {
        final raw = value[key];
        if (raw is String) _redaction.registerSecret(raw);
      }
    }

    aliases(data);
    for (final key in ['data', 'error', 'session', 'account']) {
      final nested = data[key];
      if (nested is Map) aliases(nested);
    }
  }

  bool _allowed(String method, String path) {
    if (RegExp(r'[\s\\]').hasMatch(path)) return false;
    final uri = Uri.tryParse('$_base$path');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'datacat.run' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty)
      return false;
    if (method == 'POST') {
      return !uri.hasQuery &&
          const {
            '/api/liberator/identify',
            '/api/saucepan-extract/run',
            '/api/character/smart-extract-v2',
          }.contains(uri.path);
    }
    return method == 'GET' &&
        (uri.path == '/api/extraction/status' ||
            RegExp(r'^/api/characters/[A-Za-z0-9_-]+$').hasMatch(uri.path));
  }

  Future<T> _request<T>(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
    required bool Function() current,
    required Future<T> Function(Map<String, dynamic>, SecretRedactor) consume,
  }) async {
    _check(current);
    if (!_allowed(method, path)) throw const DatacatAnonymousHttpException(0);
    if (token != null) _redaction.registerSecret(token);
    if (body != null) _register(body);
    final original = _redaction.redactor;
    try {
      _check(current);
      final response = await _dio.request<String>(
        '$_base$path',
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
          headers: {
            'User-Agent': _ua,
            if (body != null) 'Content-Type': 'application/json',
            'Origin': _base,
            'Referer': '$_base/',
            if (token != null) 'X-Session-Token': token,
          },
        ),
      );
      final data = _decode(response.data);
      _register(data); // Synchronous, BEFORE stale/error/publication checks.
      _check(current);
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300)
        throw DatacatAnonymousHttpException(status);
      if (data.isEmpty) throw const DatacatAnonymousHttpException(0);
      final result = await consume(data, original);
      _check(current);
      return result;
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on DatacatAnonymousHttpException {
      _check(current);
      rethrow;
    } on DioException catch (error) {
      _register(_decode(error.response?.data));
      _check(current);
      throw DatacatAnonymousHttpException(error.response?.statusCode ?? 0);
    } catch (_) {
      _check(current);
      throw const DatacatAnonymousHttpException(0);
    }
  }

  Future<void> identify(
    String device,
    bool Function() current,
    Future<void> Function(String token) commit,
  ) => _request<void>(
    'POST',
    '/api/liberator/identify',
    body: {'deviceToken': device},
    current: current,
    consume: (data, _) async {
      final token = data['sessionToken'];
      if (token is! String || token.isEmpty)
        throw const DatacatAnonymousHttpException(0);
      _redaction.registerSecret(token);
      _check(current);
      await commit(token);
      _check(current);
    },
  );

  Future<Map<String, dynamic>> request(
    String method,
    String path,
    String token,
    bool Function() current, {
    Map<String, dynamic>? body,
  }) => _request(
    method,
    path,
    token: token,
    body: body,
    current: current,
    consume: (data, original) async {
      final safe = _safeData(data, original);
      _check(current);
      return safe;
    },
  );

  /// Native card data is not a diagnostic export. Keep public/signed avatar URL
  /// queries and source content intact while removing submitted/returned aliases
  /// with BOTH original and current coverage. URL-disarmed inspection is never
  /// published: an already-escaped known secret omits the whole string, while
  /// unrelated public URL bytes round-trip without decoding or rewriting them.
  Map<String, dynamic> _safeData(
    Map<String, dynamic> data,
    SecretRedactor original,
  ) {
    SecretRedactor bounded(SecretRedactor value) => value.withKnownSecrets(
      const [],
      maxInputLength: 1200000,
      maxOutputLength: 1200000,
    );
    final before = bounded(original), now = bounded(_redaction.redactor);
    String safeText(String value) {
      if (value.length > 400000) throw const DatacatAnonymousHttpException(0);
      final encoded = Uri.encodeComponent(value);
      final safe = now.redactText(before.redactText(encoded));
      if (safe.contains(SecretRedactor.limited))
        throw const DatacatAnonymousHttpException(0);
      // Encoding an existing %XX would hide the common encoded-secret form.
      // Inspect one escaping layer separately, but never return that projection:
      // otherwise an innocent signed query containing %XX would be rewritten.
      final escapedInspection = encoded.replaceAll('%25', '%');
      if (escapedInspection != encoded) {
        final checked = now.redactText(before.redactText(escapedInspection));
        if (checked.contains(SecretRedactor.limited))
          throw const DatacatAnonymousHttpException(0);
        if (checked != escapedInspection) return SecretRedactor.removed;
      }
      return Uri.decodeComponent(safe);
    }

    var nodes = 0;
    Object? visit(Object? value, int depth) {
      if (++nodes > 8192 || depth > 32)
        throw const DatacatAnonymousHttpException(0);
      if (value is String) return safeText(value);
      if (value is Map)
        return <String, dynamic>{
          for (final entry in value.entries)
            safeText(entry.key as String):
                SecretRedactor.isSecretField(entry.key as String) ||
                    _aliases.contains(entry.key)
                ? SecretRedactor.removed
                : visit(entry.value, depth + 1),
        };
      if (value is List)
        return [for (final entry in value) visit(entry, depth + 1)];
      return value;
    }

    final safe = visit(data, 0) as Map<String, dynamic>;
    if (jsonEncode(safe).length > 400000)
      throw const DatacatAnonymousHttpException(0);
    return safe;
  }
}
