import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/credential_vault.dart';
import '../../../core/credentials/saucepan_credential_owner.dart';
import '../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../catalog_models.dart';

/// Native (on-device) Saucepan (saucepan.ai) companion extraction — a Dart port
/// of JAR's `saucepan.js`.
///
/// Unlike the JanitorAI path, Saucepan needs no browser: the companion
/// definition is available directly from the authenticated REST API. The catch
/// is that definitions ship as a **shuffled** list of text fragments padded with
/// **decoy** fragments — a naive join is garbled. Each real fragment carries a
/// `proof` hash the decoys fail; reassembly validates the proof, orders the
/// survivors by `key ^ mask`, and concatenates. Ported so the output matches
/// JAR (and Saucepan's own web client) byte-for-byte.
///
/// Data comes from two endpoints (both auth-gated by a Saucepan bearer token):
///   GET /api/v1/companion/definition?companion_id=ID → named prose sections
///   GET /api/v2/companions/ID                         → metadata + body
///                                                        fragments + greetings

const String _saucepanBase = 'https://saucepan.ai';
const String _saucepanUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

// ─── Fragment reassembly (verbatim port of Saucepan's client scheme) ─────────
// 32-bit unsigned integer math throughout: `& 0xFFFFFFFF` emulates JS `>>> 0`
// and `Math.imul(...) >>> 0` (the 56-bit product fits Dart's 64-bit int).

const int _fnvOffset = 2166136261;
const int _fnvPrime = 16777619;

int _rotl(int value, int bits) =>
    ((value << bits) | (value >>> (32 - bits))) & 0xFFFFFFFF;

int _fragmentHash(int mask, int derivedKey, String text) {
  final bytes = utf8.encode(text);
  var h = (_fnvOffset ^ _rotl(mask, 7) ^ _rotl(derivedKey, 13)) & 0xFFFFFFFF;
  for (final b in bytes) {
    h ^= b;
    h = (h * _fnvPrime) & 0xFFFFFFFF;
  }
  return h & 0xFFFFFFFF;
}

int _u32(dynamic v) => v is num ? v.toInt() & 0xFFFFFFFF : 0;

/// Reassembles a `{fragments, mask}` content object into prose, dropping decoys.
/// Real fragments are those whose `proof` matches `_fragmentHash(mask, key^mask,
/// text)`; survivors are ordered by `key ^ mask` and concatenated.
String assembleFragments(dynamic content) {
  if (content is! Map) return '';
  final rawFragments = content['fragments'];
  if (rawFragments is! List) return '';
  final mask = _u32(content['mask']);

  final kept = <MapEntry<int, String>>[];
  for (final f in rawFragments) {
    if (f is! Map) continue;
    final text = f['text'];
    if (text is! String) continue;
    final key = _u32(f['key']);
    final derivedKey = (key ^ mask) & 0xFFFFFFFF;
    if (_fragmentHash(mask, derivedKey, text) == _u32(f['proof'])) {
      kept.add(MapEntry(derivedKey, text));
    }
  }
  kept.sort((a, b) => a.key - b.key);
  return kept.map((e) => e.value).join();
}

/// Extracts the companion UUID from a `saucepan.ai/companion/<id>` URL.
String? parseCompanionId(String url) {
  final m = RegExp(
    r'saucepan\.ai/companion/([a-f0-9-]{8,64})',
    caseSensitive: false,
  ).firstMatch(url);
  return m?.group(1);
}

/// Thrown on any Saucepan extraction failure; [status] mirrors JAR's error
/// codes (401 = not logged in, 400 = bad URL, 502 = upstream).
class SaucepanException implements Exception {
  final String message;
  final int status;
  const SaucepanException(this.message, {this.status = 0});
  @override
  String toString() => message;
}

/// The result of a companion extraction: the recovered character and its id.
class SaucepanExtraction {
  final String companionId;
  final DownloadedCharacter character;
  const SaucepanExtraction({
    required this.companionId,
    required this.character,
  });
}

/// Native REST consumer. Only secret-free account metadata is retained here;
/// bearer tokens are ephemeral callback arguments from the Saucepan owner.
class SaucepanExtractor {
  SaucepanExtractor({
    SaucepanCredentialOwner? credentials,
    SecretRedactionCoordinator? redaction,
    Dio? dio,
  }) : _credentials = credentials,
       _redaction = redaction ?? SecretRedactionCoordinator(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 20),
               responseType: ResponseType.plain,
               // Accept a 4xx without throwing so we can read the error body ourselves.
               validateStatus: (_) => true,
               // Never forward a bearer token or login body through an upstream redirect.
               followRedirects: false,
             ),
           ) {
    if (credentials != null && redaction == null) {
      throw ArgumentError(
        'Saucepan credentials require their redaction owner.',
      );
    }
  }

  final SaucepanCredentialOwner? _credentials;
  final SecretRedactionCoordinator _redaction;
  final Dio _dio;
  bool _disposed = false;
  SaucepanCredentialAccount _account = const SaucepanCredentialAccount();
  SaucepanCredentialAccount get account => _account;
  bool get isLoggedIn => _account.authenticated;
  SaucepanCredentialOwner get _owner =>
      _credentials ?? (throw const SaucepanExceptionStorage());

  bool Function() captureAuthGuard() {
    final current = _owner.captureAuthGuard();
    return () => !_disposed && current();
  }

  void dispose() => _disposed = true;

  static void _check(bool Function() isCurrent) {
    if (!isCurrent()) throw const CredentialVaultAdmissionDenied();
  }

  Map<String, String> _headers({String? token}) => {
    'User-Agent': _saucepanUa,
    'Accept': '*/*',
    'Origin': _saucepanBase,
    'Referer': '$_saucepanBase/',
    'x-saucepan-client-version': '1',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// Loads the persisted token (call once on boot / before use).
  Future<void> loadToken() async {
    final current = captureAuthGuard();
    final value = await _owner.load();
    _check(current);
    _account = value;
  }

  /// Sets and persists the bearer token directly (for users who paste one).
  Future<void> setToken(
    String token, {
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) {
    _redaction.registerSecret(token);
    return _mutate(
      (publish) => _owner.setToken(token, onCommitted: publish),
      onCommitted,
    );
  }

  /// Clears the stored session.
  Future<void> logout({
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) => _mutate((publish) => _owner.logout(onCommitted: publish), onCommitted);

  Future<void> _mutate(
    Future<SaucepanCredentialAccount> Function(
      void Function(SaucepanCredentialAccount) publish,
    )
    operation,
    void Function(SaucepanCredentialAccount)? onCommitted,
  ) async {
    if (_disposed) throw const CredentialVaultAdmissionDenied();
    final pending = operation((value) {
      if (_disposed) throw const CredentialVaultAdmissionDenied();
      _publish(value, onCommitted);
    });
    final current = captureAuthGuard();
    final value = await pending;
    _check(current);
    _publish(value, onCommitted);
  }

  void _publish(
    SaucepanCredentialAccount value,
    void Function(SaucepanCredentialAccount)? onCommitted,
  ) {
    _account = value;
    onCommitted?.call(value);
    if (value.metadataUnavailable) {
      throw SaucepanException(
        'Saucepan authentication committed, but account metadata could not be saved.',
      );
    }
  }

  /// Logs in with handle + password, storing the returned bearer token.
  Future<void> login(
    String handle,
    String password, {
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) async {
    _redaction.registerSecret(
      password,
    ); // Before admission, transport or errors.
    final original = _redaction.redactor.withKnownSecrets([password]);
    await _mutate(
      (publish) => _owner.login(handle, (commit, ownerCurrent) async {
        bool current() => !_disposed && ownerCurrent();
        final res = await _request(
          () => _dio.post<String>(
            '$_saucepanBase/api/v1/auth/sign_in_password',
            data: jsonEncode({'handle': handle.trim(), 'password': password}),
            options: Options(
              headers: {
                ..._headers(),
                'Content-Type': 'application/json',
                'Referer': '$_saucepanBase/sign-in',
              },
              followRedirects: false,
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          ),
          current,
          registerReturnedToken: true,
        );
        final data = _tryJson(res.data);
        if ((res.statusCode ?? 0) >= 300) {
          throw _httpError(data, res.statusCode ?? 0, original);
        }
        final token = _returnedToken(data);
        if (token == null || token.trim().isEmpty) {
          throw SaucepanException('login succeeded but no token was returned');
        }
        _check(current);
        await commit(token);
        _check(current);
      }, onCommitted: publish),
      onCommitted,
    );
  }

  /// Errors deliberately carry no Dio request/response/headers/body/cause.
  /// Partial-v2 response semantics prevent using catalogGet's all-or-throw API.
  Future<Response<String>> _request(
    Future<Response<String>> Function() send,
    bool Function() isCurrent, {
    bool registerReturnedToken = false,
  }) async {
    _check(isCurrent);
    try {
      final res = await send();
      if (registerReturnedToken) {
        final data = _tryJson(res.data);
        for (final key in [
          'token',
          'access_token',
          'session_token',
          'sessionToken',
        ]) {
          final token = data?[key];
          if (token is String) _redaction.registerSecret(token);
        }
      }
      _check(isCurrent);
      return res;
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on DioException catch (error) {
      _check(isCurrent);
      throw SaucepanException(
        'Saucepan request failed.',
        status: error.response?.statusCode ?? 502,
      );
    } catch (_) {
      _check(isCurrent);
      throw SaucepanException('Saucepan request failed.', status: 502);
    }
  }

  static String? _returnedToken(Map<String, dynamic>? data) {
    final value =
        data?['token'] ??
        data?['access_token'] ??
        data?['session_token'] ??
        data?['sessionToken'];
    return value is String ? value : null;
  }

  SaucepanException _httpError(
    Map<String, dynamic>? data,
    int status,
    SecretRedactor original, {
    int? publishedStatus,
  }) {
    final error = data?['error'];
    final message = error is Map ? error['message'] : null;
    final text = message is String ? message : 'Saucepan HTTP $status';
    return SaucepanException(
      _redaction.redactor.redactText(original.redactText(text)),
      status: publishedStatus ?? status,
    );
  }

  Future<({int status, Map<String, dynamic>? data})> _getJson(
    String path, {
    required String token,
    required bool Function() isCurrent,
  }) async {
    final res = await _request(
      () => _dio.get<String>(
        '$_saucepanBase$path',
        options: Options(
          headers: _headers(token: token),
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      ),
      isCurrent,
    );
    _check(isCurrent);
    return (status: res.statusCode ?? 0, data: _tryJson(res.data));
  }

  /// Fetches a Saucepan companion by URL and builds a [DownloadedCharacter].
  /// Requires a stored token (definition + scenarios are auth-gated).
  Future<SaucepanExtraction> extractCompanion(String url) async {
    final operationCurrent = captureAuthGuard();
    // Carry only a safe typed failure outside the vault callback, whose generic
    // consumer-error wrapper intentionally must not retain arbitrary exceptions.
    SaucepanException? failure;
    SaucepanExtraction? extraction;
    try {
      await _owner.withToken((token, ownerCurrent) async {
        bool current() => operationCurrent() && ownerCurrent();
        try {
          extraction = await _extractWithToken(url, token, current);
          _check(current);
        } on SaucepanException catch (error) {
          failure = error;
        }
      });
    } on CredentialVaultException catch (error) {
      _check(operationCurrent);
      if (error.failure == CredentialVaultFailure.missing) {
        throw SaucepanException(
          'No Saucepan token configured — log in first.',
          status: 401,
        );
      }
      throw const SaucepanExceptionStorage();
    }
    _check(operationCurrent);
    if (failure != null) throw failure!;
    return extraction!;
  }

  Future<SaucepanExtraction> _extractWithToken(
    String url,
    String token,
    bool Function() isCurrent,
  ) async {
    final original = _redaction.redactor.withKnownSecrets([token]);
    _check(isCurrent);
    final companionId = parseCompanionId(url);
    if (companionId == null) {
      throw SaucepanException('Not a Saucepan companion URL.', status: 400);
    }

    final defRes = await _getJson(
      '/api/v1/companion/definition?companion_id=$companionId',
      token: token,
      isCurrent: isCurrent,
    );
    _check(isCurrent);
    final compRes = await _getJson(
      '/api/v2/companions/$companionId',
      token: token,
      isCurrent: isCurrent,
    );
    _check(isCurrent);

    if (defRes.status >= 300 || defRes.data == null) {
      throw _httpError(
        defRes.data,
        defRes.status,
        original,
        publishedStatus: defRes.status == 401 ? 401 : 502,
      );
    }

    // Named prose sections from the definition endpoint.
    final sections = <String, String>{};
    final rawSections = defRes.data!['sections'];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is Map && s['title'] is String && s['content'] != null) {
          sections[s['title'] as String] = assembleFragments(s['content']);
        }
      }
    }

    final companion = compRes.data?['companion'];
    final comp = companion is Map ? companion : const <String, dynamic>{};
    if (compRes.status >= 300 || companion is! Map) {
      debugPrint(
        _redaction.redactor.redactText(
          original.redactText(
            '[saucepan] greetings/metadata unavailable '
            '(companions/$companionId HTTP ${compRes.status})',
          ),
        ),
      );
    }

    // Body: prefer the definition's "Companion Core", fall back to the v2 body.
    var description = sections['Companion Core'] ?? '';
    if (description.isEmpty && comp['full_description_fragments'] != null) {
      description = assembleFragments(comp['full_description_fragments']);
    }

    // Greetings live only on the v2 companion as starting scenarios.
    final greetings = <String>[];
    final scenarios = comp['starting_scenarios_fragments'];
    if (scenarios is List) {
      for (final sc in scenarios) {
        final text = sc is Map ? assembleFragments(sc['message']) : '';
        if (text.trim().isNotEmpty) greetings.add(text);
      }
    }

    // Advanced Prompt / Response Formatting have no dedicated V2 field — keep
    // them (labeled) in creator notes so nothing authored is silently dropped.
    final notesParts = <String>[];
    final shortDesc = (comp['short_description'] ?? '').toString().trim();
    if (shortDesc.isNotEmpty) notesParts.add(shortDesc);
    if ((sections['Advanced Prompt'] ?? '').isNotEmpty) {
      notesParts.add('--- Advanced Prompt ---\n${sections['Advanced Prompt']}');
    }
    if ((sections['Response Formatting Instructions'] ?? '').isNotEmpty) {
      notesParts.add(
        '--- Response Formatting ---\n${sections['Response Formatting Instructions']}',
      );
    }

    final imageId = comp['image'] is Map ? comp['image']['id'] : null;
    final avatarUrl = imageId != null
        ? '$_saucepanBase/cdn/${Uri.encodeComponent(imageId.toString())}/card'
        : null;

    final character = DownloadedCharacter(
      charData: CharacterData(
        name: (comp['display_name'] ?? comp['name'] ?? 'Unknown').toString(),
        description: description,
        firstMes: greetings.isNotEmpty ? greetings.first : '',
        alternateGreetings: greetings.length > 1
            ? greetings.sublist(1)
            : const [],
        mesExample: sections['Example Dialogue'] ?? '',
        creatorNotes: notesParts.join('\n\n'),
        tags: comp['tags'] is List
            ? (comp['tags'] as List).map((e) => e.toString()).toList()
            : const [],
      ),
      avatarUrl: avatarUrl,
    );

    _check(isCurrent);
    return SaucepanExtraction(companionId: companionId, character: character);
  }

  static Map<String, dynamic>? _tryJson(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// Fixed safe unavailable error: no original storage exception is retained.
final class SaucepanExceptionStorage extends SaucepanException {
  const SaucepanExceptionStorage()
    : super('Saucepan credentials are unavailable.', status: 503);
}

final saucepanCredentialOwnerProvider = Provider<SaucepanCredentialOwner>((
  ref,
) {
  final owner = SaucepanCredentialOwner(
    vault: ref.watch(credentialVaultProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    originalPreferences: ref.watch(sharedPreferencesProvider.future),
  );
  ref.onDispose(owner.dispose);
  return owner;
});

/// Native composition: pure reassembly/URL helpers never acquire platform stores.
final saucepanExtractorProvider = Provider<SaucepanExtractor>((ref) {
  final extractor = SaucepanExtractor(
    credentials: ref.watch(saucepanCredentialOwnerProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
  );
  ref.onDispose(extractor.dispose);
  return extractor;
});
