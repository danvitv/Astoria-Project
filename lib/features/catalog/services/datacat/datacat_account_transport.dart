import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../core/credentials/credential_vault.dart';
import '../../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../../core/credentials/secret_redactor.dart';
import 'datacat_client.dart';
import 'datacat_errors.dart';

/// Linked-account native transport, not the anonymous or verification transport.
/// Response-token aliases are registered before ANY error/state publication.
final class DatacatAccountTransport {
  DatacatAccountTransport({
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

  static const _aliases = [
    'accessToken',
    'access_token',
    'token',
    'userToken',
    'user_token',
    'sessionToken',
    'session_token',
    'deviceCode',
    'device_code',
  ];
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
  final SecretRedactionCoordinator _redaction;
  final Dio _dio;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _dio.close();
  }

  void check(bool Function() current) {
    if (_disposed || !current()) throw const CredentialVaultAdmissionDenied();
  }

  Map<String, dynamic> _decode(Object? value) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  void _register(Map<String, dynamic> data) {
    for (final alias in _aliases) {
      final value = data[alias];
      if (value is String) _redaction.registerSecret(value);
    }
    // Known response envelopes only, not a generic user-prose secret collector.
    for (final container in ['account', 'data', 'error']) {
      final nested = data[container];
      if (nested is Map) {
        for (final alias in _aliases) {
          final value = nested[alias];
          if (value is String) _redaction.registerSecret(value);
        }
      }
    }
  }

  String safeText(String value) => _redaction.redactor.redactText(value);

  /// Approval URLs intentionally retain their public query. Validate decoded
  /// components instead of diagnostic URL redaction, which strips every query.
  /// Retain the original policy as well as checking newly registered secrets.
  bool Function(String uri, String? userCode) captureApprovalValidator() {
    final original = _redaction.redactor;
    return (value, userCode) {
      if (_disposed) return false;
      bool publicText(String text) =>
          original.redactText(text) == text && safeText(text) == text;
      try {
        final uri = Uri.parse(value);
        if (uri.scheme != 'https' ||
            uri.host != 'datacat.run' ||
            uri.userInfo.isNotEmpty ||
            (uri.hasPort && uri.port != 443) ||
            RegExp(r'[\s\\]').hasMatch(value) ||
            RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(value))
          return false;
        final fields = <String>[
          // Disarm URL recognition without losing whole-value or cross-component
          // known-secret matching. Diagnostic redaction would erase the query.
          Uri.encodeComponent(value),
          uri.host, uri.path, Uri.decodeComponent(uri.path), uri.query,
          Uri.decodeComponent(uri.query), uri.fragment,
          Uri.decodeComponent(uri.fragment), ...uri.pathSegments,
          for (final entry in uri.queryParametersAll.entries) ...[
            entry.key,
            ...entry.value,
          ],
          if (userCode != null) userCode,
        ];
        return fields.every(publicText);
      } catch (_) {
        return false;
      }
    };
  }

  Map<String, dynamic> safeData(Map<String, dynamic> data) {
    final safe = _redaction.redactor
        .withKnownSecrets(
          const [],
          maxInputLength: 400000,
          maxOutputLength: 400000,
          maxNodes: 8192,
        )
        .redactJson(data);
    if (safe is! Map)
      throw const DatacatApiException(
        status: 0,
        message: 'DataCat response could not be read safely',
      );
    return safe.cast<String, dynamic>();
  }

  DatacatApiException _safeError(
    DatacatApiException error,
    SecretRedactor original,
  ) {
    String safe(String value) => safeText(original.redactText(value));
    return DatacatApiException(
      status: error.status,
      message: safe(error.message),
      code: error.code == null ? null : safe(error.code!),
      verificationRequired: error.verificationRequired,
      verificationAction: error.verificationAction == null
          ? null
          : safe(error.verificationAction!),
      accountState: error.accountState == null
          ? null
          : safe(error.accountState!),
      retryAfterSeconds: error.retryAfterSeconds,
    );
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    String? device,
    Map<String, dynamic>? body,
    Map<String, Object?> query = const {},
    required bool Function() isCurrent,
  }) async {
    check(isCurrent);
    if (!datacatConfigured)
      throw const DatacatApiException(
        status: 0,
        code: 'client_id_missing',
        message: 'DataCat client id is not configured',
      );
    if (token != null) _redaction.registerSecret(token);
    if (body != null) _register(body);
    final original = _redaction.redactor;
    try {
      check(isCurrent);
      final response = await _dio.request<String>(
        datacatUrl(path, query),
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'User-Agent': _ua,
            if (body != null) 'Content-Type': 'application/json',
            ...datacatAccountHeaders(token, device),
          },
        ),
      );
      final data = _decode(response.data);
      _register(data); // Including stale responses and error bodies.
      check(isCurrent);
      final status = response.statusCode ?? 0;
      if (status >= 300) {
        throw _safeError(
          datacatError(
            DioException.badResponse(
              statusCode: status,
              requestOptions: response.requestOptions,
              response: Response<Object?>(
                requestOptions: response.requestOptions,
                statusCode: status,
                data: data,
                headers: response.headers,
              ),
            ),
          ),
          original,
        );
      }
      if (status == 204 && method == 'DELETE') return const {};
      if (data.isEmpty)
        throw const DatacatApiException(
          status: 0,
          message: 'DataCat returned an invalid response',
        );
      return data; // Raw aliases are ephemeral inside trusted linking only.
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on DatacatApiException catch (error) {
      check(isCurrent);
      throw _safeError(error, original);
    } on DioException catch (error) {
      _register(_decode(error.response?.data));
      check(isCurrent);
      // No transport message/cause, URL, request headers or body escapes.
      throw DatacatApiException(
        status: error.response?.statusCode ?? 0,
        message: 'DataCat request failed',
      );
    } catch (_) {
      check(isCurrent);
      throw const DatacatApiException(
        status: 0,
        message: 'DataCat request failed',
      );
    }
  }
}
