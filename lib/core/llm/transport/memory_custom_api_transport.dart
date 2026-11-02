import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../credentials/credential_vault.dart';
import '../../credentials/memory_custom_api_credential_owner.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'llm_protocol.dart';
import 'openai_chat_transport.dart';

/// Capture-free native custom Memory requests. The existing custom POST route
/// and native 408 retry are retained; every actual adapter fetch is fenced.
final class MemoryCustomApiTransport implements ChatTransport {
  const MemoryCustomApiTransport(this.original, {this.adapterFactory});
  final MemoryCustomApiInvocation original;
  final HttpClientAdapter Function()? adapterFactory;

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const []; // No custom-key listing/probe grant.

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    original.requireCurrent();
    if (request.apiKey.isNotEmpty ||
        request.savedConnectionId != null ||
        request.savedConnectionAuth != null ||
        request.useResponsesApi ||
        request.stream ||
        request.extraRequestParameters.isNotEmpty ||
        request.tools != null ||
        request.endpoint != original.settings.generationEndpoint ||
        request.model != original.settings.generationModel) {
      throw const CredentialVaultAdmissionDenied();
    }
    final token = cancelToken ?? CancelToken();
    await original.withApiKey<void>((key, requireCurrent) async {
      final snapshot = original.captureRedactor().withKnownSecrets([key]);
      void check() {
        requireCurrent();
        if (token.isCancelled) throw const CredentialVaultAdmissionDenied();
      }

      String safe(String value) => original.redact(value, snapshot);
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          maxRedirects: 0,
          receiveDataWhenStatusError: false,
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      Object? failure;
      try {
        final inner = adapterFactory?.call() ?? dio.httpClientAdapter;
        dio.httpClientAdapter = _MemoryCustomAdapter(
          inner,
          Uri.parse(
            MemoryCustomApiCredentialOwner.destination(original.settings),
          ),
          key,
          token,
          check,
        );
        check();
        await OpenAiChatTransport(
          dio: dio,
          protocol: LlmProtocol.customChatCompletion,
        ).stream(
          request: ChatTransportRequest(
            endpoint: request.endpoint,
            apiKey:
                key, // Ephemeral native request only, never an ordinary DTO.
            model: request.model,
            messages: request.messages,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stream: false,
            omitTemperature: request.omitTemperature,
            omitTopP: request.omitTopP,
            omitReasoning: request.omitReasoning,
            omitReasoningEffort: request.omitReasoningEffort,
            requestReasoning: request.requestReasoning,
            receiveTimeoutMs: request.receiveTimeoutMs,
          ),
          cancelToken: token,
          onUpdate: (text, reasoning) {
            check();
            onUpdate?.call(
              safe(text),
              reasoning == null ? null : safe(reasoning),
            );
          },
          onComplete: (text, reasoning, {rawResponseJson}) {
            check();
            // CURRENT + original coverage precedes every external callback.
            onComplete?.call(
              safe(text),
              reasoning == null ? null : safe(reasoning),
              rawResponseJson: rawResponseJson == null
                  ? null
                  : safe(rawResponseJson),
            );
          },
          onError: (error) {
            check();
            failure = _safeError(error, safe);
          },
        );
        check();
      } finally {
        dio.close(force: true);
      }
      // Closing the adapter is also a custody/policy boundary. Re-redact the
      // ENTIRE cached error here, before the auxiliary attempt log clips it.
      check();
      if (failure != null) onError?.call(_safeError(failure!, safe));
    });
    original.requireCurrent();
  }

  static Object _safeError(Object error, String Function(String) safe) {
    if (error is DioException) {
      final options = RequestOptions(path: '');
      return DioException(
        requestOptions: options,
        response: error.response == null
            ? null
            : Response<void>(
                requestOptions: options,
                statusCode: error.response!.statusCode,
              ),
        type: error.type,
        // A raw Dio dump includes its nested cause. Only the provider's message
        // and fixed classification cross this boundary, never request metadata.
        message: safe(error.message ?? 'Custom Memory request failed.'),
      );
    }
    return StateError(safe(error.toString()));
  }
}

final class _MemoryCustomAdapter implements HttpClientAdapter {
  _MemoryCustomAdapter(
    this.inner,
    this.destination,
    this.key,
    this.token,
    this.check,
  );
  final HttpClientAdapter inner;
  final Uri destination;
  final String key;
  final CancelToken token;
  final void Function() check;
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    check();
    final authentication = options.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'authorization')
        .toList();
    if (_closed ||
        options.method != 'POST' ||
        options.uri != destination ||
        options.followRedirects ||
        options.maxRedirects != 0 ||
        options.cancelToken != token ||
        authentication.length != 1 ||
        authentication.single.value != 'Bearer $key') {
      throw const CredentialVaultAdmissionDenied();
    }
    // No await between the original final check and actual wire invocation.
    final response = await inner.fetch(options, requestStream, cancelFuture);
    check();
    return response;
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    inner.close(force: true);
  }
}
