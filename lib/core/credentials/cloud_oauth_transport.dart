import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'cloud_oauth_record.dart';
import 'cloud_oauth_credential_owner.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Issued alongside this exact token, not recovered from a later owner lookup.
final class CloudOAuthRequestToken {
  const CloudOAuthRequestToken(this.value, this.isCurrent);
  final String value;
  final bool Function() isCurrent;
  @override
  String toString() => 'Cloud OAuth request token receipt';
}

/// Family-specific original HTTP admission, propagated through existing Drive
/// folder/file callbacks. Nested calls retain the root guard, never renew it.
final class CloudOAuthRequestScope {
  CloudOAuthRequestScope(this._capture, this.redaction, {this.registerAliases});
  final bool Function() Function() _capture;
  final SecretRedactionCoordinator redaction;
  final void Function(Object?)? registerAliases;
  final Object _zoneKey = Object();

  _CloudRequestAdmission get _admission =>
      Zone.current[_zoneKey] as _CloudRequestAdmission? ??
      _CloudRequestAdmission(_capture());

  bool Function() get guard => _admission.current;

  /// Immutable original clauses, not a callback that adopts a later refresh.
  bool Function() captureGuard() => _admission.snapshot();
  bool Function() captureOperationGuard() => _admission.operationSnapshot();

  static Map<String, dynamic> tokenAdmission(CloudOAuthRequestToken token) => {
    _tokenGuardKey: token.isCurrent,
  };

  void retainCredentialGuard(bool Function() credential) {
    final admission = Zone.current[_zoneKey] as _CloudRequestAdmission?;
    if (admission == null) throw const CredentialVaultAdmissionDenied();
    // Ordinary reads cannot replace an earlier token admission with a lookup.
    check();
    admission.credential ??= credential;
    check();
  }

  /// Only an actual successful refresh may replace this workflow's own token
  /// clause. Other workflows and already-started HTTP snapshots stay retired.
  void retainRefreshedCredentialGuard(
    bool Function() credential,
    bool Function() issuedRefresh,
  ) {
    final admission = Zone.current[_zoneKey] as _CloudRequestAdmission?;
    if (admission == null ||
        !admission.operationSnapshot()() ||
        !issuedRefresh() ||
        !credential())
      throw const CredentialVaultAdmissionDenied();
    admission.credential = credential;
    check();
  }

  void check() {
    if (!guard()) throw const CredentialVaultAdmissionDenied();
  }

  Future<T> run<T>(Future<T> Function() action, {bool Function()? original}) {
    final inherited = Zone.current[_zoneKey] as _CloudRequestAdmission?;
    final admission = original == null && inherited != null
        ? inherited
        : _CloudRequestAdmission(original ?? _capture());
    return runZoned(() async {
      if (!admission.current()) throw const CredentialVaultAdmissionDenied();
      try {
        final value = await action();
        if (!admission.current()) throw const CredentialVaultAdmissionDenied();
        return value;
      } catch (error) {
        // Preserve an invoked write's verification OR explicit commit unknown.
        // Neither can publish credentials or become a pre-invocation refusal.
        if (error is CloudOAuthRetiredCommit) rethrow;
        if (!admission.current()) throw const CredentialVaultAdmissionDenied();
        rethrow;
      }
    }, zoneValues: {_zoneKey: admission});
  }

  bool isCurrent() => guard();

  void learnAliases(Object? value) {
    registerCloudOAuthAliases(value, redaction);
    registerAliases?.call(value);
  }

  void registerSecret(String value) {
    redaction.registerSecret(value);
    registerAliases?.call({'code': value});
  }

  /// No redirect carrying tokens, codes or resumable capability URLs. Only
  /// existing provider origins/routes; a reflected upload location is validated
  /// by the actual Drive consumer before invocation.
  void protect(Dio dio, CloudOAuthProvider provider) {
    dio.options.followRedirects = false;
    dio.options.maxRedirects = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final original = captureGuard();
          final token = options.extra[_tokenGuardKey] as bool Function()?;
          bool current() => original() && (token?.call() ?? true);
          final uri = options.uri;
          final hosts = provider == CloudOAuthProvider.dropbox
              ? const {'api.dropboxapi.com', 'content.dropboxapi.com'}
              : const {'oauth2.googleapis.com', 'www.googleapis.com'};
          if (!current() ||
              uri.scheme != 'https' ||
              !hosts.contains(uri.host) ||
              uri.userInfo.isNotEmpty ||
              uri.port != 443 ||
              uri.fragment.isNotEmpty ||
              !_allowedRoute(uri, provider)) {
            handler.reject(_safeError(0, admitted: false));
            return;
          }
          options.followRedirects = false;
          options.maxRedirects = 0;
          options.extra[_guardKey] = current;
          handler.next(options);
        },
        onResponse: (response, handler) {
          _register(response.data);
          final current =
              response.requestOptions.extra[_guardKey] as bool Function()?;
          if (current?.call() != true) {
            handler.reject(_safeError(0, admitted: false));
            return;
          }
          // Successful OAuth token responses stay native. Consumers register and
          // validate them before state publication; sync data is not OAuth state.
          handler.next(response);
        },
        onError: (error, handler) {
          final data = error.response?.data;
          final parsed = _register(data);
          final current =
              error.requestOptions.extra[_guardKey] as bool Function()?;
          final admitted = current?.call() == true;
          // Preserve the status and Dropbox missing-file classification, never the
          // request/header/body/cause. Existing consumers still catch DioException.
          Object? safeBody;
          if (parsed is Map &&
              parsed['error_summary'] is String &&
              (parsed['error_summary'] as String).startsWith(
                'path/not_found',
              )) {
            safeBody = {'error_summary': 'path/not_found'};
          }
          handler.next(
            _safeError(
              error.response?.statusCode ?? 0,
              admitted: admitted,
              body: safeBody,
            ),
          );
        },
      ),
    );
  }

  static const _guardKey = 'astoria.cloud.originalAdmission';
  static const _tokenGuardKey = 'astoria.cloud.originalTokenAdmission';
  bool _allowedRoute(Uri uri, CloudOAuthProvider provider) {
    if (provider == CloudOAuthProvider.dropbox) {
      if (uri.host == 'content.dropboxapi.com') {
        return const {
          '/2/files/upload',
          '/2/files/download',
        }.contains(uri.path);
      }
      return const {
        '/oauth2/token',
        '/2/auth/token/revoke',
        '/2/users/get_current_account',
        '/2/files/create_folder_v2',
        '/2/files/delete_v2',
        '/2/files/list_folder',
        '/2/files/list_folder/continue',
        '/2/files/delete_batch',
        '/2/files/delete_batch/check',
      }.contains(uri.path);
    }
    if (uri.host == 'oauth2.googleapis.com') {
      return const {'/token', '/revoke'}.contains(uri.path);
    }
    return uri.path == '/oauth2/v2/userinfo' ||
        RegExp(
          r'^/(?:upload/)?drive/v3/files(?:/[A-Za-z0-9_-]+)?$',
        ).hasMatch(uri.path);
  }

  Object? _register(Object? data) {
    Object? parsed = data;
    try {
      if (data is String) parsed = jsonDecode(data);
      if (data is List<int>) parsed = jsonDecode(utf8.decode(data));
    } catch (_) {}
    learnAliases(parsed);
    return parsed;
  }

  DioException _safeError(int status, {required bool admitted, Object? body}) {
    final request = RequestOptions(path: 'cloud-sync');
    return DioException(
      requestOptions: request,
      response: Response(
        requestOptions: request,
        statusCode: status,
        data: body,
      ),
      error: admitted ? null : const CredentialVaultAdmissionDenied(),
      message: admitted
          ? 'Cloud request failed (HTTP $status)'
          : 'Cloud operation retired',
      type: DioExceptionType.badResponse,
    );
  }

  Object? redact(Object? value) => redaction.redactor.redactJson(value);
}

final class _CloudRequestAdmission {
  _CloudRequestAdmission(bool Function() original) : guards = [original];
  final List<bool Function()> guards;
  bool Function()? credential;
  bool current() =>
      guards.every((guard) => guard()) && (credential?.call() ?? true);
  bool Function() snapshot() {
    final original = List<bool Function()>.of(guards);
    if (credential != null) original.add(credential!);
    return () => original.every((guard) => guard());
  }

  bool Function() operationSnapshot() {
    final original = List<bool Function()>.of(guards);
    return () => original.every((guard) => guard());
  }
}
