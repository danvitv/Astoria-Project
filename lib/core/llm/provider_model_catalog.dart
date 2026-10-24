import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../credentials/native_provider_credentials.dart';
import '../credentials/provider_models_endpoint.dart';
import '../credentials/secret_redaction_coordinator.dart';
import '../models/api_config.dart';

/// No request/response, key, URL or provider error is exposed to the model picker.
final class ProviderModelCatalogException implements Exception {
  const ProviderModelCatalogException();
  @override
  String toString() => 'Provider model catalog unavailable.';
}

/// One GET /models on the saved server. Never generate, probe or follow redirects.
final class ProviderModelCatalog {
  ProviderModelCatalog({
    required this._readSavedConnection,
    required this._credentials,
    required this._auth,
    required this._mutations,
    required this._redaction,
    required this._adapterFactory,
  });

  final Future<ApiConfig?> Function(String) _readSavedConnection;
  final NativeProviderCredentialVault _credentials;
  final NativeSavedConnectionAuthIssuer _auth;
  final NativeConnectionMutationOwner _mutations;
  final SecretRedactionCoordinator _redaction;
  final HttpClientAdapter Function() _adapterFactory;

  Future<List<String>> fetchModelIds({
    required String connectionId,
    required bool Function() isCurrent,
    required CancelToken cancelToken,
  }) async {
    final stamp = _mutations.observe();
    bool current() {
      if (stamp == null || cancelToken.isCancelled) return false;
      try {
        return _mutations.isCurrent(stamp) &&
            isCurrent() &&
            _mutations.isCurrent(stamp) &&
            !cancelToken.isCancelled;
      } catch (_) {
        return false;
      }
    }

    void requireCurrent() {
      if (!current()) throw const ProviderModelCatalogException();
    }

    void changed() {
      if (!current() && !cancelToken.isCancelled) cancelToken.cancel();
    }

    _mutations.addFenceListener(changed);
    final deadline = Timer(
      const Duration(seconds: 20),
      () => cancelToken.cancel(),
    );
    try {
      requireCurrent();
      final saved = await _readSavedConnection(connectionId);
      requireCurrent();
      if (saved == null || saved.mode != 'chat') {
        throw const ProviderModelCatalogException();
      }
      final presence = await _credentials.inspectNativePresence(
        connectionId: connectionId,
        isCurrent: current,
      );
      requireCurrent();
      List<String>? models;
      if (presence == NativeProviderCredentialPresence.present) {
        final reference = _auth.referenceFor(
          saved,
          NativeProviderPurpose.astoria,
        );
        if (reference == null) throw const ProviderModelCatalogException();
        final broker = NativeProviderCredentialBroker(
          credentials: _credentials,
          transport: (binding, secret) async {
            final uri = binding.modelsEndpoint;
            void check(Uri actual) {
              requireCurrent();
              binding.requireModelListRequest(uri: actual, method: 'GET');
              requireCurrent();
            }

            models = await _get(
              uri,
              saved.protocol,
              secret,
              cancelToken,
              check,
            );
          },
        );
        await broker.dispatchModelList(reference, isCurrent: current);
      } else if (presence == NativeProviderCredentialPresence.absent ||
          presence == NativeProviderCredentialPresence.prepared) {
        // A prepared native profile has no key: catalog metadata may be public.
        // Never borrow a legacy key or fall back on a corrupt/disabled native key.
        final prepared = presence == NativeProviderCredentialPresence.prepared;
        if (prepared &&
            (saved.apiKey.isNotEmpty ||
                saved.embeddingApiKey.isNotEmpty ||
                saved.embeddingEnabled ||
                saved.extraRequestParameters.isNotEmpty)) {
          throw const ProviderModelCatalogException();
        }
        final secret = prepared ? '' : saved.apiKey;
        _redaction.registerSecret(secret);
        requireCurrent();
        final protocol = saved.useResponsesApi
            ? 'openai_responses'
            : saved.protocol;
        final uri = providerModelsEndpoint(Uri.parse(saved.endpoint), protocol);
        models = await _get(uri, protocol, secret, cancelToken, (actual) {
          requireCurrent();
          if (actual != uri) throw const ProviderModelCatalogException();
        });
      } else {
        throw const ProviderModelCatalogException();
      }
      requireCurrent();
      return models ?? const [];
    } catch (_) {
      throw const ProviderModelCatalogException();
    } finally {
      deadline.cancel();
      _mutations.removeFenceListener(changed);
    }
  }

  Future<List<String>> _get(
    Uri uri,
    String protocol,
    String secret,
    CancelToken token,
    void Function(Uri) check,
  ) async {
    final headers = <String, Object>{'Accept': 'application/json'};
    if (secret.isNotEmpty) {
      switch (protocol) {
        case 'anthropic':
          headers['x-api-key'] = secret;
          headers['anthropic-version'] = '2023-06-01';
        case 'gemini':
          headers['x-goog-api-key'] = secret;
        default:
          headers['Authorization'] = 'Bearer $secret';
      }
    }
    final dio = Dio(
      BaseOptions(
        followRedirects: false,
        maxRedirects: 0,
        connectTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    try {
      check(uri);
      dio.httpClientAdapter = _adapterFactory();
      check(uri);
      final options = RequestOptions(
        path: uri.toString(),
        method: 'GET',
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status == 200,
        cancelToken: token,
      );
      check(options.uri);
      final response = await dio.fetch<ResponseBody>(options);
      check(options.uri);
      if (response.statusCode != 200 || response.data == null) {
        throw const ProviderModelCatalogException();
      }
      final bytes = <int>[];
      await for (final chunk in response.data!.stream.timeout(
        const Duration(seconds: 20),
      )) {
        check(options.uri);
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const ProviderModelCatalogException();
        }
        bytes.addAll(chunk);
      }
      check(options.uri);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) {
        throw const ProviderModelCatalogException();
      }
      final rows = json[protocol == 'gemini' ? 'models' : 'data'];
      if (rows is! List || rows.length > 4096) {
        throw const ProviderModelCatalogException();
      }
      final result = <String>{};
      for (final row in rows) {
        if (row is! Map<String, dynamic>) continue;
        final value = row[protocol == 'gemini' ? 'name' : 'id'];
        if (value is! String) continue;
        final id = protocol == 'gemini' && value.startsWith('models/')
            ? value.substring(7)
            : value;
        if (id.isNotEmpty &&
            id.length <= 256 &&
            RegExp(r'^[A-Za-z0-9_.:/-]+$').hasMatch(id) &&
            _redaction.redactor.redactText(id) == id) {
          result.add(id);
        }
      }
      check(options.uri);
      return List.unmodifiable(result.toList()..sort());
    } finally {
      dio.close(force: true);
    }
  }
}
