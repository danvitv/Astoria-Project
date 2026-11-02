import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../../core/credentials/cloud_oauth_credential_owner.dart';
import '../../../../core/credentials/cloud_oauth_record.dart';
import '../../../../core/credentials/cloud_oauth_transport.dart';
import '../../../../core/credentials/credential_vault.dart';
import '../../../../core/credentials/secret_redaction_coordinator.dart';

import '../oauth_local_server.dart';
import '../../sync_config.dart';

class GDriveAuth {
  GDriveAuth({
    CloudOAuthCredentialOwner? credentials,
    Dio? dio,
    SecretRedactionCoordinator? redaction,
    Future<void> Function()? nativeConnect,
    Future<({String code, String redirectUri})> Function(String url)? authorize,
    String? clientId,
    String? clientSecret,
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
       _clientId = clientId,
       _clientSecret = clientSecret,
       _nativeConnect = nativeConnect {
    requests = CloudOAuthRequestScope(
      () => _isMobile
          ? _captureNativeGuard()
          : (_credentials?.captureGuard() ?? (() => false)),
      redaction ?? credentials?.redaction ?? SecretRedactionCoordinator(),
      registerAliases: credentials?.registerAliases,
    );
    requests.protect(_dio, CloudOAuthProvider.gdrive);
  }
  static const _authBase = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _revokeUrl = 'https://oauth2.googleapis.com/revoke';
  static const _userInfoUrl = 'https://www.googleapis.com/oauth2/v2/userinfo';
  static const _scope = 'https://www.googleapis.com/auth/drive.file';

  final Dio _dio;
  final CloudOAuthCredentialOwner? _credentials;
  // Trusted synthetic SDK-success callback; production retains the real SDK.
  final Future<void> Function()? _nativeConnect;
  bool _syntheticNativeConnected = false;
  int _nativeEpoch = 0;
  final Future<({String code, String redirectUri})> Function(String url)?
  _authorize;
  final String? _clientId, _clientSecret;
  late final CloudOAuthRequestScope requests;
  bool Function()? _connectionGuard;
  bool Function() captureConnectionGuard() => _connectionGuard ?? (() => false);
  bool _disposed = false;
  String? _folderId;
  GoogleSignInAccount? _nativeAccount;
  bool _restoreNativeAccount = false;
  static Future<void>? _nativeInitialization;

  bool get _isMobile =>
      _nativeConnect != null || Platform.isAndroid || Platform.isIOS;
  bool Function() _captureNativeGuard() {
    final epoch = _nativeEpoch;
    return () => !_disposed && epoch == _nativeEpoch;
  }

  CloudOAuthCredentialOwner get _owner =>
      _credentials ??
      (throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      ));
  String? get accessToken => _credentials?.cached?.accessToken;
  String? get folderId =>
      _isMobile ? _folderId : _credentials?.cached?.folderId;
  bool get usesNativeCustody => _isMobile;
  bool get hasWorkflowOwner => _isMobile || _credentials != null;
  bool get isConnected =>
      !_disposed &&
      (_isMobile
          ? _nativeAccount != null || _syntheticNativeConnected
          : _credentials?.connected ?? false);

  void loadTokens(Map<String, dynamic>? tokens) {
    final gd = tokens?['gdrive'];
    if (gd is! Map) return;
    if (_isMobile) {
      _restoreNativeAccount = gd['native_connected'] == true;
      _folderId = gd['folderId'] as String?;
      return;
    }
  }

  Future<void> restoreTokens() async {
    if (!_isMobile) await _owner.load();
  }

  Map<String, dynamic>? saveTokens() {
    if (_isMobile) {
      return _nativeAccount == null
          ? null
          : {
              'gdrive': {'native_connected': true, 'folderId': _folderId},
            };
    }
    return null; // Desktop summaries never serialize protected pairs.
  }

  Future<void> restoreNativeSession() async {
    if (_nativeConnect != null) return;
    if (!_isMobile ||
        !_restoreNativeAccount ||
        !SyncConfig.canStartSyncAuth('gdrive')) {
      return;
    }
    try {
      final current = _captureNativeGuard();
      await _initializeNative();
      if (!current()) return;
      final account = await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      if (!current()) return;
      if (account != null &&
          await account.authorizationClient.authorizationForScopes([_scope]) !=
              null) {
        if (!current()) return;
        _nativeAccount = account;
      }
    } catch (_) {
      // A revoked grant or unavailable Play Services needs an explicit reconnect.
    }
  }

  Future<void> _initializeNative() {
    final initialization = _nativeInitialization ??= GoogleSignIn.instance
        .initialize(
          clientId: Platform.isIOS ? SyncConfig.gdriveIosClientId : null,
          serverClientId: Platform.isAndroid
              ? SyncConfig.gdriveAndroidServerClientId
              : null,
        );
    return initialization.catchError((Object error, StackTrace trace) {
      if (identical(_nativeInitialization, initialization)) {
        _nativeInitialization = null;
      }
      Error.throwWithStackTrace(error, trace);
    });
  }

  Future<void> connect() async {
    if (_isMobile) {
      _nativeEpoch++;
      final current = _captureNativeGuard();
      _connectionGuard = current;
      if (_nativeConnect != null) {
        await _nativeConnect();
        if (!current()) throw const CredentialVaultAdmissionDenied();
        _syntheticNativeConnected = true;
        return;
      }
      if (!SyncConfig.canStartSyncAuth('gdrive')) {
        throw StateError('Google Drive mobile OAuth client not configured');
      }
      await _initializeNative();
      if (!current()) throw const CredentialVaultAdmissionDenied();
      final account =
          _nativeAccount ?? await GoogleSignIn.instance.authenticate();
      if (!current()) throw const CredentialVaultAdmissionDenied();
      // Request Drive access only here, in response to Connect being tapped.
      // Never prompt during app initialization or an automatic background sync.
      await account.authorizationClient.authorizeScopes([_scope]);
      if (!current()) throw const CredentialVaultAdmissionDenied();
      _nativeAccount = account;
      return;
    }
    final current = _owner.beginOperation();
    await requests
        .run(() async {
          _connectionGuard = requests.guard;
          final clientId = _clientId ?? SyncConfig.gdriveClientId;
          if (clientId == null || clientId.isEmpty) {
            throw StateError('GDrive Client ID not configured');
          }

          final verifier = _generateRandomString(128);
          requests.registerSecret(verifier);
          final codeChallenge = _sha256Base64Url(verifier);
          final state = _generateRandomString(32);

          final url =
              '$_authBase?response_type=code&client_id=$clientId&redirect_uri=http://localhost'
              '&scope=${Uri.encodeComponent(_scope)}&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state'
              '&access_type=offline&prompt=consent';
          final synthetic = _authorize;
          late String code, redirect;
          if (synthetic != null) {
            final result = await synthetic(url);
            requests.registerSecret(result.code);
            requests.check();
            code = result.code;
            redirect = result.redirectUri;
          } else {
            final result = await OAuthLocalServer.authenticate(
              url,
              isCurrent: requests.captureGuard(),
              registerAliases: requests.learnAliases,
            );
            requests.registerSecret(result.code);
            requests.check();
            code = result.code;
            redirect = result.redirectUri;
          }
          await _handleCodeExchange(code, redirect, verifier, current);
          requests.check();
        }, original: current)
        .catchError((Object error) {
          if (error is CloudOAuthRetiredCommit) throw error;
          _owner.check(current);
          if (error is CredentialVaultException ||
              error is CredentialVaultAdmissionDenied)
            throw error;
          throw StateError('Google Drive authorization failed');
        });
  }

  Future<void> _handleCodeExchange(
    String code,
    String redirectUri,
    String verifier,
    bool Function() current,
  ) async {
    final body = await _tokenRequest({
      'code': code,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
      'code_verifier': verifier,
    });
    requests.check();
    final pair = _pair(body);
    await _owner.store(pair, current);
    requests.retainCredentialGuard(_owner.credentialGuard(pair));
    requests.check();
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> values) async {
    final clientSecret = _clientSecret ?? SyncConfig.gdriveClientSecret;
    final data = <String, String>{
      ...values,
      'client_id': _clientId ?? SyncConfig.gdriveClientId ?? '',
      if (clientSecret != null && clientSecret.isNotEmpty)
        'client_secret': clientSecret,
    };
    if (data['client_id']?.isNotEmpty != true) {
      throw StateError('Google Drive Client ID not configured');
    }
    requests.learnAliases(data);
    requests.check();
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      data: data,
    );
    requests.learnAliases(response.data);
    requests.check();
    if (response.statusCode != 200 || response.data == null) {
      throw StateError('Google Drive token request failed');
    }
    return response.data!;
  }

  CloudOAuthPair _pair(Map<String, dynamic> body, {CloudOAuthPair? previous}) {
    final expiry = body['expires_in'] ?? 3600;
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
        'account_id': previous?.accountId,
        'folderId': previous?.folderId,
      },
      CloudOAuthProvider.gdrive,
      requests.redaction,
      legacy: true,
    );
  }

  Future<String> getValidToken() async => (await getRequestToken()).value;

  Future<CloudOAuthRequestToken> getRequestToken() async {
    if (_isMobile) {
      final current = _captureNativeGuard();
      if (!current()) throw const CredentialVaultAdmissionDenied();
      final account = _nativeAccount;
      if (account == null) throw StateError('Not authenticated');
      final authorization = await account.authorizationClient
          .authorizationForScopes([_scope]);
      if (authorization != null)
        requests.registerSecret(authorization.accessToken);
      if (!current()) throw const CredentialVaultAdmissionDenied();
      if (authorization == null) {
        throw StateError(
          'Google Drive permission expired; reconnect to Google Drive',
        );
      }
      final original = requests.captureGuard();
      return CloudOAuthRequestToken(
        authorization.accessToken,
        () => current() && original(),
      );
    }
    return requests
        .run(() async {
          final original = requests.captureGuard();
          final loaded = await _owner.load(isCurrent: original);
          requests.check();
          if (loaded == null)
            throw const CredentialVaultException(
              CredentialVaultFailure.missing,
            );
          CloudOAuthPair pair = loaded;
          if (pair.expired) {
            final refresh = _owner.beginRefresh(
              requests.captureOperationGuard(),
            );
            pair = await requests.run(() async {
              final body = await _tokenRequest({
                'grant_type': 'refresh_token',
                'refresh_token': pair.refreshToken,
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
          final operation = requests.captureOperationGuard();
          final credential = _owner.credentialGuard(pair);
          return CloudOAuthRequestToken(
            pair.accessToken,
            () => operation() && credential(),
          );
        })
        .catchError((Object error) {
          if (error is CloudOAuthRetiredCommit ||
              error is CredentialVaultException ||
              error is CredentialVaultAdmissionDenied ||
              error is DioException)
            throw error;
          throw StateError('Google Drive token unavailable');
        });
  }

  Future<Map<String, dynamic>?> getAccountInfo() async {
    if (_isMobile) {
      final account = _nativeAccount;
      return account == null
          ? null
          : {
              'id': account.id,
              'email': account.email,
              'name': account.displayName,
            };
    }
    try {
      return await requests.run(() async {
        final token = await getRequestToken();
        requests.check();
        final response = await _dio.get<Map<String, dynamic>>(
          _userInfoUrl,
          options: Options(
            headers: {'Authorization': 'Bearer ${token.value}'},
            extra: CloudOAuthRequestScope.tokenAdmission(token),
          ),
        );
        requests.check();
        final accountId = response.data?['id'];
        if (accountId is String && accountId.isNotEmpty) {
          await _owner.bindMetadata(requests.guard, accountId: accountId);
          requests.check();
        }
        final safe = requests.redact({
          'id': response.data?['id'],
          'email': response.data?['email'],
          'name': response.data?['name'],
        });
        return safe is Map<String, dynamic> ? safe : null;
      });
    } catch (error) {
      if (error is CloudOAuthRetiredCommit) rethrow;
      return null;
    }
  }

  Future<CloudOAuthDisconnectOutcome> disconnect() async {
    if (_isMobile) {
      _nativeEpoch++;
      final current = _captureNativeGuard();
      if (_nativeAccount != null) await GoogleSignIn.instance.disconnect();
      if (!current()) throw const CredentialVaultAdmissionDenied();
      _syntheticNativeConnected = false;
      _nativeAccount = null;
      _restoreNativeAccount = false;
      _folderId = null;
      return const CloudOAuthDisconnectOutcome(remoteComplete: true);
    }
    final result = await _owner.disconnect(
      (token, current) => requests.run(() async {
        await _dio.post<void>(_revokeUrl, queryParameters: {'token': token});
        requests.check();
      }, original: current),
    );
    _folderId = null;
    return result;
  }

  Future<void> bindFolder(String folder) async {
    if (_isMobile) {
      requests.check();
      _folderId = folder;
      return;
    }
    final current = requests.guard;
    await _owner.bindMetadata(current, folderId: folder);
    requests.check();
  }

  void dispose() {
    _disposed = true;
    _nativeAccount = null;
    _syntheticNativeConnected = false;
    _folderId = null;
    _credentials?.dispose();
  }

  String _generateRandomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(
      length,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
  }

  String _sha256Base64Url(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
