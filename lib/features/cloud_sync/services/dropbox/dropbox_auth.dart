import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/credentials/cloud_oauth_credential_owner.dart';
import '../../../../core/credentials/cloud_oauth_record.dart';
import '../../../../core/credentials/cloud_oauth_transport.dart';
import '../../../../core/credentials/credential_vault.dart';
import '../../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../../core/services/deep_link_service.dart';
import '../../../../core/services/oauth_state.dart';
import '../../cloud_read_only_adapter.dart';
import '../../sync_config.dart';
import '../oauth_local_server.dart';

class DropboxAuth {
  DropboxAuth({
    CloudOAuthCredentialOwner? credentials,
    Dio? dio,
    Future<({String code, String redirectUri})> Function(String url)? authorize,
    String? appKey,
  }) : _credentials = credentials,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 60),
             ),
           ),
       _authorize = authorize,
       _appKey = appKey {
    requests = CloudOAuthRequestScope(
      () => _credentials?.captureGuard() ?? (() => false),
      credentials?.redaction ?? SecretRedactionCoordinator(),
      registerAliases: credentials?.registerAliases,
    );
    requests.protect(_dio, CloudOAuthProvider.dropbox);
  }

  static const _authBase = 'https://www.dropbox.com/oauth2/authorize';
  static const _tokenUrl = 'https://api.dropboxapi.com/oauth2/token';
  static const _revokeUrl = 'https://api.dropboxapi.com/2/auth/token/revoke';
  final CloudOAuthCredentialOwner? _credentials;
  final Dio _dio;
  final Future<({String code, String redirectUri})> Function(String url)?
  _authorize;
  final String? _appKey;
  late final CloudOAuthRequestScope requests;
  bool Function()? _connectionGuard;
  bool Function() captureConnectionGuard() => _connectionGuard ?? (() => false);

  CloudOAuthCredentialOwner get _owner =>
      _credentials ??
      (throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      ));
  String? get accessToken => _credentials?.cached?.accessToken;
  bool get isConnected => _credentials?.connected ?? false;
  bool get hasWorkflowOwner => _credentials != null;

  /// Legacy map entry points cannot grant custody or re-emit token pairs.
  void loadTokens(Map<String, dynamic>? tokens) {}
  Map<String, dynamic>? saveTokens() => null;
  Future<void> restoreTokens() async {
    await _owner.load();
  }

  Future<void> connect() {
    final current = _owner
        .beginOperation(); // Before browser/config/HTTP waits.
    return requests
        .run(() async {
          _connectionGuard = requests.guard;
          final appKey = _appKey ?? SyncConfig.dropboxAppKey;
          if (appKey == null || appKey.isEmpty) {
            throw StateError('Dropbox App Key not configured');
          }
          final verifier = _generateRandomString(128);
          requests.registerSecret(verifier);
          final challenge = _sha256Base64Url(verifier);
          final state = _generateRandomString(32);
          final prefix =
              '$_authBase?response_type=code&client_id=$appKey'
              '&code_challenge=$challenge&code_challenge_method=S256&state=$state'
              '&token_access_type=offline';
          late String code, redirect;
          if (_authorize != null) {
            final result = await _authorize(
              '$prefix&redirect_uri=http://localhost',
            );
            requests.registerSecret(result.code);
            requests.check();
            code = result.code;
            redirect = result.redirectUri;
          } else if (Platform.isAndroid || Platform.isIOS) {
            redirect = SyncConfig.dropboxRedirectNative;
            final deepLink = DeepLinkService.instance;
            deepLink.beginOAuth('dropbox', state);
            try {
              await launchUrl(
                Uri.parse(
                  '$prefix&redirect_uri=${Uri.encodeComponent(redirect)}',
                ),
                mode: LaunchMode.externalApplication,
              );
              requests.check();
              final callback = await deepLink.awaitOAuthCallback('dropbox');
              requests.learnAliases(callback.queryParameters);
              requests.check();
              final returned = callback.queryParameters['code'];
              if (returned == null ||
                  oauthStateMismatchMessage(
                        state,
                        callback.queryParameters['state'],
                      ) !=
                      null) {
                throw StateError('Dropbox authorization failed');
              }
              code = returned;
            } finally {
              deepLink.endOAuth('dropbox', state);
            }
          } else {
            final result = await OAuthLocalServer.authenticate(
              '$prefix&redirect_uri=http://localhost',
              port: SyncConfig.dropboxDesktopPort,
              isCurrent: requests.captureGuard(),
              registerAliases: requests.learnAliases,
            );
            requests.registerSecret(result.code);
            requests.check();
            code = result.code;
            redirect = result.redirectUri;
          }
          requests.check();
          final body = await _tokenRequest({
            'code': code,
            'grant_type': 'authorization_code',
            'client_id': appKey,
            'redirect_uri': redirect,
            'code_verifier': verifier,
          });
          requests.check();
          final pair = _pair(body);
          await _owner.store(pair, current);
          requests.retainCredentialGuard(_owner.credentialGuard(pair));
          requests.check();
        }, original: current)
        .catchError((Object error) {
          if (error is CloudOAuthRetiredCommit) throw error;
          _owner.check(current);
          if (error is CredentialVaultException ||
              error is CredentialVaultAdmissionDenied)
            throw error;
          throw StateError('Dropbox authorization failed');
        });
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> values) async {
    if (values['client_id']?.isNotEmpty != true) {
      throw StateError('Dropbox App Key not configured');
    }
    for (final key in ['code', 'refresh_token', 'code_verifier']) {
      final value = values[key];
      if (value != null) requests.registerSecret(value);
    }
    requests.check();
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      data: values,
    );
    requests.learnAliases(response.data);
    requests.check();
    if (response.statusCode != 200 || response.data == null) {
      throw StateError('Dropbox token request failed');
    }
    return response.data!;
  }

  CloudOAuthPair _pair(Map<String, dynamic> body, {CloudOAuthPair? previous}) {
    if (previous != null &&
        ((body['account_id'] != null &&
                body['account_id'] != previous.accountId) ||
            (body['uid'] != null && body['uid'] != previous.uid))) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    final expiry = body['expires_in'] ?? 14400;
    if (expiry is! int || expiry <= 0 || expiry > 31536000) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    return decodeCloudOAuthPair(
      {
        ...body,
        'refresh_token': body['refresh_token'] ?? previous?.refreshToken,
        'expires_at': DateTime.now().millisecondsSinceEpoch + expiry * 1000,
        'account_id': body['account_id'] ?? previous?.accountId,
        'uid': body['uid'] ?? previous?.uid,
      },
      CloudOAuthProvider.dropbox,
      requests.redaction,
      legacy: true,
    );
  }

  /// Synchronous existing cache only. No refresh, vault read, prefs or new grant.
  String requireExistingTokenForReadOnlyDownload() {
    final pair = _credentials?.cached;
    if (pair == null ||
        pair.expiresAt == null ||
        pair.expired ||
        _credentials?.credentialGuard(pair).call() != true) {
      throw const CloudReadOnlyDownloadException(
        CloudReadOnlyDownloadStatus.reauthenticate,
      );
    }
    return pair.accessToken;
  }

  bool Function() captureReadOnlyCredentialGuard() {
    final pair = _credentials?.cached;
    return pair == null ? (() => false) : _owner.credentialGuard(pair);
  }

  Future<String> getValidToken() => requests
      .run(() async {
        final original = requests.captureGuard();
        final loaded = await _owner.load(isCurrent: original);
        requests.check();
        if (loaded == null)
          throw const CredentialVaultException(CredentialVaultFailure.missing);
        CloudOAuthPair pair = loaded;
        if (pair.expired) {
          final refresh = _owner.beginRefresh(requests.captureOperationGuard());
          pair = await requests.run(() async {
            final body = await _tokenRequest({
              'grant_type': 'refresh_token',
              'refresh_token': pair.refreshToken,
              'client_id': _appKey ?? SyncConfig.dropboxAppKey ?? '',
            });
            requests.check();
            final next = _pair(body, previous: pair);
            await _owner.store(next, refresh);
            requests.check();
            return next;
          }, original: refresh);
          requests.retainRefreshedCredentialGuard(
            _owner.credentialGuard(pair),
            refresh,
          );
        }
        requests.retainCredentialGuard(_owner.credentialGuard(pair));
        requests.check();
        return pair.accessToken;
      })
      .catchError((Object error) {
        if (error is CloudOAuthRetiredCommit ||
            error is CredentialVaultException ||
            error is CredentialVaultAdmissionDenied ||
            error is DioException)
          throw error;
        throw StateError('Dropbox token unavailable');
      });

  Future<CloudOAuthDisconnectOutcome> disconnect() => _owner.disconnect(
    (token, current) => requests.run(() async {
      await _dio.post<void>(
        _revokeUrl,
        options: Options(
          headers: {'Authorization': 'Bearer $token', 'Content-Type': ''},
        ),
      );
      requests.check();
    }, original: current),
  );

  void dispose() => _credentials?.dispose();

  String _generateRandomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(
      length,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
  }

  String _sha256Base64Url(String input) => base64Url
      .encode(sha256.convert(utf8.encode(input)).bytes)
      .replaceAll('=', '');
}
