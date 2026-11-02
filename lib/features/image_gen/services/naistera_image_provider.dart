import 'dart:collection';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/credentials/image_naistera_destinations.dart';
import '../../../core/credentials/image_openrouter_destinations.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/utils/error_format.dart' show activeErrorRedactor;

import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// Naistera image client.
///
/// Mirrors the reference extension (https://github.com/0xl0cal/sillyimages,
/// `NaisteraProvider`): `POST {base}/api/generate` with a JSON body, answered
/// either synchronously with `data_url` or with a `job_id` that is polled on
/// `GET {base}/api/generate/jobs/{id}`. The route Glaze used before
/// (`/prompt/api/img`, `images: [base64]`) is retired and answers
/// 405 Method Not Allowed.
class NaisteraImageProvider {
  NaisteraImageProvider({
    this.baseUrl = NaisteraConstants.baseUrl,
    this.pollInterval = const Duration(seconds: 3),
    this.pollTimeout = const Duration(minutes: 10),
    ImageGenHttp? http,
    ImageGenHttp? assetHttp,
    void Function()? checkCurrent,
    bool Function(String)? isPublicValue,
  }) : _http = http ?? ImageGenHttp(followRedirects: false),
       _assetHttp = assetHttp ?? ImageGenHttp(followRedirects: false),
       _checkCurrent = checkCurrent,
       _isPublicValue = isPublicValue;

  final ImageGenHttp _http, _assetHttp;
  final void Function()? _checkCurrent;
  final bool Function(String)? _isPublicValue;
  static final _defaultPolicy = SecretRedactor();
  final String baseUrl;
  final Duration pollInterval;
  final Duration pollTimeout;

  /// Naistera only: inspect original native JSON keys/string leaves before the
  /// whole encoding. A carried JSON string must not gain another escaping layer
  /// before policy sees it. Keep the whole check for aliases spanning fields.
  /// No custom toJson/toString, clipping, cycles or unbounded traversal.
  static bool nativeJsonIsPublic(Object? value, bool Function(String) public) {
    try {
      if (!_nativeJsonLeavesArePublic(value, public)) return false;
      final whole = jsonEncode(value);
      return whole.length <= 33554432 && public(whole);
    } catch (_) {
      return false;
    }
  }

  /// Structural admission for the ephemeral projection, with no JSON encoding.
  static bool isNativeJsonTree(Object? value) =>
      _nativeJsonLeavesArePublic(value, (_) => true);

  static bool _nativeJsonLeavesArePublic(
    Object? value,
    bool Function(String) public,
  ) {
    const maxDepth = 64, maxNodes = 8192, maxText = 33554432;
    final active = HashSet<Object>.identity();
    var nodes = 0, textLength = 0;
    bool visit(Object? node, int depth) {
      if (++nodes > maxNodes || depth > maxDepth) return false;
      if (node is String) {
        textLength += node.length;
        return textLength <= maxText && public(node);
      }
      if (node == null || node is bool) return true;
      if (node is num) return node.isFinite;
      if (node is! List && node is! Map) return false;
      if (!active.add(node)) return false;
      try {
        if (node is List) {
          for (final child in node) {
            if (!visit(child, depth + 1)) return false;
          }
        } else if (node is Map) {
          for (final entry in node.entries) {
            if (entry.key is! String ||
                !visit(entry.key, depth + 1) ||
                !visit(entry.value, depth + 1))
              return false;
          }
        }
        return true;
      } finally {
        active.remove(node);
      }
    }

    try {
      return visit(value, 0);
    } catch (_) {
      return false;
    }
  }

  bool Function(String) _capturePublic(String key) {
    final original = (activeErrorRedactor ?? _defaultPolicy).withKnownSecrets(
      [key],
      maxInputLength: 33554432,
      maxOutputLength: 33554432,
    );
    return (value) =>
        (_isPublicValue?.call(value) ?? true) &&
        ImageNaisteraDestinations.knownSecretFreeValue(original, value) &&
        ImageNaisteraDestinations.knownSecretFreeValue(
          (activeErrorRedactor ?? _defaultPolicy).withKnownSecrets(
            [key],
            maxInputLength: 33554432,
            maxOutputLength: 33554432,
          ),
          value,
        );
  }

  void _check(
    bool Function(String) public,
    CancelToken? cancelToken,
    Iterable<String> values,
  ) {
    _checkCurrent?.call();
    if (cancelToken?.isCancelled == true || !values.every(public)) {
      throw StateError('Naistera image operation unavailable');
    }
  }

  Future<Uint8List> generate({
    required String apiKey,
    required String model,
    required String prompt,
    required String aspectRatio,
    List<Map<String, String>>? references,
    // Whether the selected model round-trips reference images: decided by the
    // caller from the fetched catalog rather than by the shipped deny-list.
    bool supportsReferences = true,
    CancelToken? cancelToken,
  }) async {
    final public = _capturePublic(apiKey); // Before every first HTTP await.
    _check(public, cancelToken, [baseUrl, model, prompt, aspectRatio]);
    if (!nativeJsonIsPublic(references, public)) {
      throw StateError('Naistera image operation unavailable');
    }
    final destinations = ImageNaisteraDestinations(baseUrl);
    final normalizedModel = NaisteraConstants.normalizeModel(model);
    final body = <String, dynamic>{
      'prompt': prompt,
      'aspect_ratio': aspectRatio,
      'model': normalizedModel,
    };
    final referenceObjects = supportsReferences
        ? _referenceObjects(references)
        : const <Map<String, String>>[];
    if (referenceObjects.isNotEmpty) {
      body['reference_objects'] = referenceObjects;
    }
    final originalRequest = {
      'model': model,
      'prompt': prompt,
      'aspectRatio': aspectRatio,
      'references': references,
    };
    final receipts = <Map<String, dynamic>>[];
    void check([Iterable<String> extra = const []]) {
      _check(public, cancelToken, [
        baseUrl,
        destinations.generation,
        model,
        normalizedModel,
        ...extra,
      ]);
      if (!nativeJsonIsPublic(originalRequest, public) ||
          !nativeJsonIsPublic(body, public) ||
          !nativeJsonIsPublic(receipts, public)) {
        throw StateError('Naistera image operation unavailable');
      }
    }

    try {
      void checkTree(Object? value) {
        check();
        if (!nativeJsonIsPublic(value, public)) {
          throw StateError('Naistera image operation unavailable');
        }
      }

      checkTree(body);
      var json = await _http.post(
        url: destinations.generation,
        apiKey: apiKey,
        body: body,
        cancelToken: cancelToken,
        followRedirects: false,
      );
      receipts.add(json);
      checkTree(json);

      final rawJobId = json['job_id'];
      final jobId = rawJobId is String ? rawJobId : '';
      if (json['data_url'] is! String && jobId.isNotEmpty) {
        json = await _pollJob(
          jobId,
          apiKey: apiKey,
          cancelToken: cancelToken,
          destinations: destinations,
          check: check,
          retainReceipt: receipts.add,
        );
      }

      final bytes = await _bytesFrom(
        json,
        cancelToken: cancelToken,
        check: check,
      );
      checkTree(body);
      checkTree(references);
      checkTree(json);
      return bytes;
    } catch (_) {
      throw StateError('Naistera image generation unavailable');
    }
  }

  /// Naistera takes references as `{image, description}` pairs where `image`
  /// is a full data URL — the collector hands over bare base64 plus its mime.
  static List<Map<String, String>> _referenceObjects(
    List<Map<String, String>>? references,
  ) {
    if (references == null || references.isEmpty) return const [];
    final objects = <Map<String, String>>[];
    for (final ref in references) {
      final image = ref['image'] ?? '';
      if (image.isEmpty) continue;
      final mime = ref['mime'] ?? 'image/png';
      objects.add({
        'image': image.startsWith('data:') ? image : 'data:$mime;base64,$image',
        'description': ref['description'] ?? '',
      });
    }
    return objects;
  }

  /// Loads the model catalog from `GET {base}/api/models`.
  ///
  /// Ported from https://github.com/0xl0cal/sillyimages
  /// (`NaisteraProvider.fetchModels`): the token decides which tier of models
  /// comes back, hidden and deprecated entries are dropped, and reference
  /// support is read off each entry instead of a hardcoded deny-list. When the
  /// authenticated request cannot be made at all, the public catalog is tried
  /// once without the token.
  Future<List<NaisteraModelInfo>> fetchModels({
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    final public = _capturePublic(apiKey);
    final destinations = ImageNaisteraDestinations(baseUrl);
    final url = destinations.models;
    void check([Iterable<String> extra = const []]) =>
        _check(public, cancelToken, [baseUrl, url, ...extra]);
    check();

    try {
      Map<String, dynamic> payload;
      try {
        payload = await _http.getJson(
          url: url,
          apiKey: apiKey,
          cancelToken: cancelToken,
          followRedirects: false,
        );
      } on DioException catch (error) {
        if (apiKey.isEmpty ||
            cancelToken?.isCancelled == true ||
            CancelToken.isCancel(error) ||
            error.response != null) {
          rethrow;
        }
        // No response at all (connection refused, TLS, CORS-style block) — the
        // public catalog still tells us which models exist.
        check();
        payload = await _http.getJson(
          url: url,
          cancelToken: cancelToken,
          followRedirects: false,
        );
      }
      check();

      final models = payload['models'];
      if (models is! List) return const [];
      final catalog = <NaisteraModelInfo>[];
      for (final raw in models) {
        if (raw is! Map) continue;
        final model = Map<String, dynamic>.from(raw);
        final rawId = (model['id'] ?? '').toString();
        final id = rawId.trim();
        final name = (model['name'] ?? id).toString();
        if (![
          rawId,
          id,
          name,
          NaisteraConstants.normalizeModel(id),
        ].every(public))
          continue;
        if (id.isEmpty) continue;
        if (model['visible'] == false || model['deprecated'] == true) continue;
        catalog.add(
          NaisteraModelInfo(
            id: id,
            name: name,
            references: model['references'] != false,
          ),
        );
      }
      check();
      return catalog
          .where(
            (model) =>
                public(model.id) &&
                public(model.name) &&
                public(NaisteraConstants.normalizeModel(model.id)),
          )
          .toList();
    } catch (_) {
      throw StateError('Naistera image catalog unavailable');
    }
  }

  Future<Map<String, dynamic>> _pollJob(
    String jobId, {
    required String apiKey,
    CancelToken? cancelToken,
    required ImageNaisteraDestinations destinations,
    required void Function([Iterable<String>]) check,
    required void Function(Map<String, dynamic>) retainReceipt,
  }) async {
    final url = destinations.job(jobId);
    check([jobId, url]);
    final deadline = DateTime.now().add(pollTimeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      check([jobId, url]);
      if (!DateTime.now().isBefore(deadline)) break;
      if (cancelToken?.isCancelled ?? false) {
        throw Exception('Naistera generation cancelled');
      }
      final json = await _http.getJson(
        url: url,
        apiKey: apiKey,
        cancelToken: cancelToken,
        followRedirects: false,
      );
      retainReceipt(json);
      check([jobId, url]);
      final rawStatus = json['status'];
      final status = (rawStatus is String ? rawStatus : '').toLowerCase();
      if (json['data_url'] is String || status == 'completed') return json;
      if (status == 'failed' || json['error'] != null) {
        throw StateError('Naistera generation failed');
      }
    }
    throw Exception(
      'Naistera polling timed out after ${pollTimeout.inSeconds}s',
    );
  }

  Future<Uint8List> _bytesFrom(
    Map<String, dynamic> json, {
    CancelToken? cancelToken,
    required void Function([Iterable<String>]) check,
  }) async {
    final raw = json['data_url'];
    final dataUrl = raw is String ? raw : '';
    check([dataUrl]);
    if (dataUrl.isEmpty) {
      throw Exception('No data_url in Naistera response');
    }
    if (dataUrl.startsWith('http://') || dataUrl.startsWith('https://')) {
      ImageOpenRouterDestinations.validateDownload(dataUrl);
      // Separate asset client: no account bearer and no redirects. Never decode
      // or normalize a signed query into the URL handed to the downloader.
      final response = await _assetHttp.getRaw(
        dataUrl,
        cancelToken: cancelToken,
        followRedirects: false,
      );
      check([dataUrl]);
      return response.data ?? Uint8List(0);
    }
    return ImageGenHttp.base64ToBytes(ImageGenHttp.stripBase64Prefix(dataUrl));
  }
}
