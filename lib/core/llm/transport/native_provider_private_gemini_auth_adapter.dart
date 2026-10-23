part of 'native_provider_transport.dart';

/// Native-only representation bridge AFTER the unchanged accepted query-auth
/// capsule checks. No public auth/header/URI rewriting surface is exported.
/// The approved origin/path/action, method, body and original capsule never change.
final class _NativeGeminiPrivateAuthAdapter implements HttpClientAdapter {
  _NativeGeminiPrivateAuthAdapter({
    required PrivateTextRequestPlan this._original,
    required this._secret,
    required this._finalAdapter,
    required this._fence,
    required this._isCurrent,
    required this._currentRedactor,
  });

  PrivateTextRequestPlan? _original;
  String _secret;
  final _NativeFinalAdapter _finalAdapter;
  final _NativeDispatchFence _fence;
  final bool Function() _isCurrent;
  final SecretRedactor Function() _currentRedactor;
  bool _started = false;
  bool _closed = false;

  void _requireOriginal(RequestOptions options) {
    final plan = _original;
    if (_closed || plan == null || _fence.token.isCancelled) {
      _nativeFail(NativeProviderTransportReason.cancelled);
    }
    _nativeRequire(
      _nativeCurrent(_isCurrent) && _fence.binding.isCurrent,
      NativeProviderTransportReason.notCurrent,
    );
    _nativeRequire(
      plan.protocol == LlmProtocol.gemini &&
          plan.request.stream &&
          plan.recipient == _fence.binding.route.endpoint &&
          plan.request.model == _fence.binding.connection.model &&
          plan.request.model == _fence.model &&
          _fence.stream &&
          _fence.binding.purpose == NativeProviderPurpose.astoria &&
          _fence.binding.route.protocol == CredentialProtocol.gemini,
      NativeProviderTransportReason.denied,
    );
    final uri = options.uri;
    final query = uri.queryParametersAll;
    _nativeRequire(
      options.method == 'POST' &&
          options.baseUrl.isEmpty &&
          options.path == plan.wireUri.toString() &&
          options.queryParameters.isEmpty &&
          uri == plan.wireUri &&
          uri.scheme == plan.recipient.scheme &&
          uri.authority == plan.recipient.authority &&
          uri.path == plan.recipient.path &&
          !uri.hasFragment &&
          uri.userInfo.isEmpty &&
          query.length == 2 &&
          query['key']?.length == 1 &&
          query['key']!.single == _secret &&
          query['alt']?.length == 1 &&
          query['alt']!.single == 'sse',
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      !options.followRedirects &&
          options.maxRedirects == 0 &&
          !options.receiveDataWhenStatusError &&
          options.responseType == ResponseType.stream &&
          identical(options.cancelToken, _fence.token) &&
          options.extra.isEmpty,
      NativeProviderTransportReason.invalidRequest,
    );
    final headers = <String, dynamic>{};
    for (final entry in options.headers.entries) {
      final folded = entry.key.toLowerCase();
      _nativeRequire(
        !headers.containsKey(folded),
        NativeProviderTransportReason.invalidRequest,
      );
      headers[folded] = entry.value;
    }
    final length = headers.remove('content-length');
    _nativeRequire(
      headers.length == plan.headers.length &&
          plan.headers.entries.every(
            (entry) => headers[entry.key.toLowerCase()] == entry.value,
          ),
      NativeProviderTransportReason.invalidRequest,
    );
    final bytes = utf8.encode(plan.bodyJson).length;
    _nativeRequire(
      (length == null || length == bytes || length == '$bytes') &&
          options.data is Map<String, dynamic> &&
          _nativeEncode(options.data) == plan.bodyJson &&
          _fence.frozenBodyJson == plan.bodyJson,
      NativeProviderTransportReason.invalidRequest,
    );
    plan.recheckSanitation(_currentRedactor());
    _nativeRequire(
      _nativeCurrent(_isCurrent) && _fence.binding.isCurrent,
      NativeProviderTransportReason.notCurrent,
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    StreamIterator<Uint8List>? upload;
    try {
      _nativeRequire(
        !_started && !_fence.claimed,
        NativeProviderTransportReason.denied,
      );
      _started = true; // Reserve before any await/callback; no adapter reentry.
      _requireOriginal(options);
      final plan = _original!;
      _nativeRequire(
        requestStream != null,
        NativeProviderTransportReason.invalidRequest,
      );
      final expected = Uint8List.fromList(utf8.encode(plan.bodyJson));
      upload = StreamIterator(requestStream!);
      var offset = 0;
      var chunks = 0;
      while (await Future.any<bool>([
        upload.moveNext(),
        _fence.token.whenCancel.then<bool>(
          (_) => _nativeFail(NativeProviderTransportReason.cancelled),
        ),
      ])) {
        _requireOriginal(options);
        final chunk = upload.current;
        _nativeRequire(
          ++chunks <= 8192 &&
              offset + chunk.length <= expected.length &&
              offset + chunk.length <= PrivateTextLimits.requestBytes,
          NativeProviderTransportReason.invalidRequest,
        );
        for (final byte in chunk) {
          _nativeRequire(
            byte == expected[offset++],
            NativeProviderTransportReason.invalidRequest,
          );
        }
      }
      _requireOriginal(options);
      _nativeRequire(
        offset == expected.length,
        NativeProviderTransportReason.invalidRequest,
      );
      await upload.cancel().timeout(
        NativeProviderTransportLimits.drainDeadline,
      );
      upload = null;
      _requireOriginal(options);
      // Never mutate the original authenticated capsule's RequestOptions. Strip
      // auth from ALL destination representations in the new private wire COPY.
      final translated = options.copyWith(
        path: plan.recipient.replace(query: 'alt=sse').toString(),
        baseUrl: '',
        queryParameters: <String, dynamic>{},
        extra: <String, dynamic>{},
        data: _nativeJson(plan.bodyJson),
        headers: <String, dynamic>{
          ...options.headers,
          'x-goog-api-key': _secret,
        },
      );
      _nativeRequire(
        translated.baseUrl.isEmpty &&
            translated.queryParameters.isEmpty &&
            translated.path ==
                plan.recipient.replace(query: 'alt=sse').toString() &&
            translated.uri.queryParametersAll.length == 1 &&
            translated.uri.queryParametersAll['alt']?.single == 'sse',
        NativeProviderTransportReason.invalidRequest,
      );
      // The final adapter invokes this BEFORE and AFTER its factory callback,
      // immediately before actual fetch, and after await. It also independently
      // checks binding, actual header auth and the frozen original body bytes.
      _fence._recheckOriginal = () => _requireOriginal(options);
      _fence.check(translated);
      final response = await _finalAdapter.fetch(
        translated,
        Stream.value(expected),
        cancelFuture,
      );
      _requireOriginal(options);
      return response;
    } on NativeProviderTransportException {
      rethrow;
    } on NativeProviderException {
      rethrow;
    } on PrivateTextFailure {
      rethrow;
    } catch (_) {
      _nativeFail(NativeProviderTransportReason.transport);
    } finally {
      if (upload != null) {
        try {
          await upload.cancel().timeout(
            NativeProviderTransportLimits.drainDeadline,
          );
        } catch (_) {
          _finalAdapter.close(force: true);
        }
      }
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _secret = '';
    _original = null;
    _fence._recheckOriginal = null;
    _finalAdapter.close(force: true);
  }
}
