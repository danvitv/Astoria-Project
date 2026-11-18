part of 'native_provider_transport.dart';

/// Independent native generation job: no shared Dio/logger/parser/retry/capture.
final class _NativeWireJob {
  _NativeWireJob({
    required this.factory,
    required this.protocol,
    required this.request,
    required this.token,
    required this.current,
    this.onUpdate,
    this.onComplete,
  });
  final NativeProviderTransportFactory factory;
  final String protocol;
  final ChatTransportRequest request;
  final CancelToken token;
  final bool Function() current;
  final ChatTransportOnUpdate? onUpdate;
  final ChatTransportOnComplete? onComplete;
  NativeProviderTransportException? failure;
  bool completed = false;
  bool expired = false;
  Timer? _timer;
  Dio? _dio;
  _NativeFinalAdapter? _adapter;
  _NativeDispatchFence? _fence;
  Completer<void>? _boundSettled;

  Future<T> awaitOwned<T>(Future<T> work) => Future.any<T>([
    work,
    token.whenCancel.then<T>(
      (_) => _nativeFail(
        expired
            ? NativeProviderTransportReason.deadline
            : NativeProviderTransportReason.cancelled,
      ),
    ),
  ]);

  void start() {
    factory.mutations.addFenceListener(_ownerChanged);
    _timer = factory.scheduleDeadline(
      NativeProviderTransportLimits.deadline,
      () {
        expired = true;
        token.cancel();
        _adapter?.close(force: true);
      },
    );
  }

  void _ownerChanged() {
    if (!_nativeCurrent(current)) {
      token.cancel();
      _adapter?.close(force: true);
    }
  }

  Future<void> runBound(
    NativeProviderDispatchBinding binding,
    String secret,
  ) async {
    final settled = Completer<void>();
    _boundSettled = settled;
    StreamIterator<Uint8List>? iterator;
    void check() {
      if (expired) _nativeFail(NativeProviderTransportReason.deadline);
      _nativeRequire(
        !token.isCancelled,
        NativeProviderTransportReason.cancelled,
      );
      _nativeRequire(
        _nativeCurrent(current) && binding.isCurrent,
        NativeProviderTransportReason.notCurrent,
      );
    }

    SecretRedactor redactor() => factory.currentRedactor().withKnownSecrets(
      [secret],
      maxInputLength: NativeProviderTransportLimits.contextCharacters,
      maxOutputLength: NativeProviderTransportLimits.contextCharacters,
      maxDepth: 32,
      maxNodes: 8192,
    );
    try {
      check();
      final plan = _NativeWirePlan(
        protocol,
        request,
        binding,
        secret,
        redactor(),
      );
      check();
      final projection = _NativeEventProjection(plan.decoderProtocol);
      final secretForms = _nativeCredentialForms(secret);
      final gate = _NativeOutputGate(
        redactor: redactor,
        check: check,
        callback: request.stream ? onUpdate : null,
        showReasoning: request.showNativeReasoning ?? !request.omitReasoning,
        structured: plan.schema != null,
        hasCredential: (text) => secretForms.any(text.contains),
        hasCrossLaneCredential: (left, right) =>
            secretForms.any((form) => _nativeLiteralCrosses(left, right, form)),
      );
      if (plan.prefill != null) gate.add(plan.prefill!, '');
      final fence = _NativeDispatchFence(
        binding: binding,
        token: token,
        model: request.model,
        stream: request.stream,
        protocol: protocol,
        secret: secret,
        plan: plan,
      );
      _fence = fence;
      final adapter = _NativeFinalAdapter(
        factory: factory.adapterFactory,
        fence: fence,
      );
      _adapter = adapter;
      final timeoutMs = request.receiveTimeoutMs;
      _nativeRequire(
        timeoutMs == null || timeoutMs >= 0,
        NativeProviderTransportReason.invalidRequest,
      );
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          maxRedirects: 0,
          receiveDataWhenStatusError: false,
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: timeoutMs == 0
              ? null
              : Duration(milliseconds: timeoutMs ?? 120000),
        ),
      )..httpClientAdapter = adapter;
      _dio = dio;
      // No interceptors, default platform adapter, captures, cookies or cache.
      check();
      final response = await dio.post<ResponseBody>(
        plan.uri.toString(),
        data: plan.body,
        cancelToken: token,
        options: Options(
          headers: plan.headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          receiveDataWhenStatusError: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      check();
      final body = response.data;
      _nativeRequire(body != null, NativeProviderTransportReason.unexpectedEof);
      iterator = StreamIterator(body!.stream);
      if (request.stream) {
        final frames = _NativeSseFrames();
        while (await _move(iterator)) {
          check();
          for (final frame in frames.add(iterator.current)) {
            check();
            final delta = projection.frame(frame);
            check();
            gate.add(delta.text, delta.reasoning);
            check();
          }
          if (projection.decoder.terminal) break;
        }
        check();
        if (!projection.decoder.terminal) {
          for (final frame in frames.finish()) {
            final delta = projection.frame(frame);
            gate.add(delta.text, delta.reasoning);
            check();
          }
        }
        projection.finish();
      } else {
        final bytes = BytesBuilder(copy: false);
        var length = 0;
        while (await _move(iterator)) {
          check();
          length += iterator.current.length;
          _nativeRequire(
            length <= NativeProviderTransportLimits.frameBytes,
            NativeProviderTransportReason.wireLimit,
          );
          bytes.add(iterator.current);
        }
        check();
        String payload;
        try {
          payload = utf8.decode(bytes.takeBytes());
        } catch (_) {
          _nativeFail(NativeProviderTransportReason.malformed);
        }
        final object = _nativeJson(payload);
        _nativeRequire(object is Map<String, dynamic>);
        final delta = _nativeCompletion(
          projection,
          object as Map<String, dynamic>,
        );
        gate.add(delta.text, delta.reasoning);
      }
      check();
      if (projection.decoder.limited) {
        _nativeFail(NativeProviderTransportReason.providerLimit);
      }
      gate.finish();
      check();
      // Drain/cancel the original body BEFORE completion publication. If an
      // injected drain refuses to settle, force-close within the fixed budget.
      await _drain(iterator);
      iterator = null;
      check();
      adapter.close(force: true);
      check();
      final text = gate.text;
      final reasoning = gate.reasoning.isEmpty ? null : gate.reasoning;
      // Real consumers inspect finish_reason/termination and display raw view.
      // Supply ONLY canonical sanitized text metadata, never a provider tree.
      final raw = jsonEncode({
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': text,
              'reasoning_content': ?reasoning,
            },
            'finish_reason': 'stop',
          },
        ],
        'astoria_stream_termination': 'terminal',
      });
      check();
      completed = true;
      ChatTransportCompletionCapture.record(
        projection.completionMetadata,
        sink: request.completionMetadataSink,
      );
      onComplete?.call(text, reasoning, rawResponseJson: raw);
      check();
    } on NativeProviderTransportException catch (error) {
      failure = NativeProviderTransportException(
        expired ? NativeProviderTransportReason.deadline : error.reason,
      );
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    } on NativeProviderException {
      rethrow;
    } catch (_) {
      failure = NativeProviderTransportException(
        expired
            ? NativeProviderTransportReason.deadline
            : token.isCancelled
            ? NativeProviderTransportReason.cancelled
            : _adapter?.failure?.reason ??
                  NativeProviderTransportReason.transport,
      );
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    } finally {
      if (iterator != null) await _drain(iterator);
      _adapter?.close(force: true);
      try {
        _dio?.close(force: true);
      } catch (_) {
        /* No raw diagnostics. */
      }
      _fence?.retire();
      settled.complete();
    }
  }

  Future<bool> _move(StreamIterator<Uint8List> iterator) => Future.any<bool>([
    iterator.moveNext(),
    token.whenCancel.then<bool>(
      (_) => _nativeFail(
        expired
            ? NativeProviderTransportReason.deadline
            : NativeProviderTransportReason.cancelled,
      ),
    ),
  ]);

  Future<void> _drain(StreamIterator<Uint8List> iterator) async {
    try {
      await iterator.cancel().timeout(
        NativeProviderTransportLimits.drainDeadline,
      );
    } catch (_) {
      _adapter?.close(force: true);
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    factory.mutations.removeFenceListener(_ownerChanged);
    _adapter?.close(force: true);
    try {
      _dio?.close(force: true);
    } catch (_) {
      /* No raw diagnostics. */
    }
    _fence?.retire();
    try {
      await _boundSettled?.future.timeout(
        NativeProviderTransportLimits.drainDeadline,
      );
    } catch (_) {
      /* The closed adapter/currentness fence owns any late drain. */
    }
    _fence = null;
    _adapter = null;
    _dio = null;
  }
}
