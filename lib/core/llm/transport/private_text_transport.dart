import 'dart:async';

import 'package:dio/dio.dart';

import '../../credentials/secret_redactor.dart';
import 'anthropic_chat_transport.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'gemini_chat_transport.dart';
import 'llm_protocol.dart';
import 'openai_chat_transport.dart';
import 'openai_responses_transport.dart';
import 'openrouter_chat_transport.dart';
import 'private_text_adapter.dart';
import 'private_text_outcome.dart';
import 'private_text_request.dart';

export 'private_text_adapter.dart'
    show
        PrivateTextAuthorization,
        PrivateTextAdmission,
        PrivateTextDispatchCapsule;
export 'private_text_outcome.dart';

/// Capture-free native text generation, independent of Ref/feature/config
/// lookup. Each call owns Dio/adapters and returns exactly one safe settlement.
final class PrivateTextTransport {
  const PrivateTextTransport({
    required this.adapterFactory,
    required this.currentRedactor,
    required this.authorize,
    this.admit,
    this.scheduleDeadline = Timer.new,
  });
  final HttpClientAdapter Function() adapterFactory;
  final SecretRedactor Function() currentRedactor;
  final PrivateTextAuthorization authorize;
  final PrivateTextAdmission? admit;

  /// Native deadline scheduling; injected tests can expire at a fixed barrier.
  final Timer Function(Duration, void Function()) scheduleDeadline;

  Future<PrivateTextOutcome> generate({
    required String protocol,
    required ChatTransportRequest request,
    required Uri approvedRecipient,
    required CancelToken cancelToken,
    required bool Function() isCurrent,
    void Function()? onActivity,
    Duration deadline = PrivateTextLimits.deadline,
  }) async {
    PrivateTextAdapter? adapter;
    Dio? dio;
    Timer? timer;
    var reason = PrivateTextReason.none;
    var nativeComplete = false;
    var nativeFailed = false;
    bool current() {
      try {
        return isCurrent();
      } catch (_) {
        return false;
      }
    }

    try {
      if (cancelToken.isCancelled) {
        throw const PrivateTextFailure(PrivateTextReason.cancelled);
      }
      if (!current()) {
        throw const PrivateTextFailure(PrivateTextReason.notCurrent);
      }
      if (deadline <= Duration.zero || deadline > PrivateTextLimits.deadline) {
        throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
      }
      final redactor = currentRedactor().withKnownSecrets(
        [request.apiKey],
        maxInputLength: PrivateTextLimits.contextCharacters,
        maxOutputLength: PrivateTextLimits.contextCharacters,
      );
      final plan = PrivateTextRequestPlan(
        protocol,
        request,
        approvedRecipient,
        redactor,
      );
      adapter = PrivateTextAdapter(
        factory: adapterFactory,
        authorize: authorize,
        admit: admit,
        plan: plan,
        cancelToken: cancelToken,
        isCurrent: current,
        currentRedactor: currentRedactor,
        onActivity: onActivity,
      );
      dio = Dio(
        BaseOptions(
          followRedirects: false,
          maxRedirects: 0,
          receiveDataWhenStatusError: false,
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 120),
        ),
      )..httpClientAdapter = adapter;
      timer = scheduleDeadline(deadline, () {
        reason = PrivateTextReason.deadline;
        cancelToken.cancel();
      });
      await _native(plan, dio).stream(
        request: plan.request,
        cancelToken: cancelToken,
        onComplete: (_, _, {rawResponseJson}) {
          nativeComplete = true;
        },
        onError: (_) {
          nativeFailed = true;
          if (reason == PrivateTextReason.none) {
            reason = PrivateTextReason.transport;
          }
        },
      );
      // Native callback/future alone is NOT a terminal proof. The strict guard
      // independently owns terminal/error/limit classification and visible text.
      if (reason != PrivateTextReason.deadline) {
        reason =
            adapter.guard?.reason != null &&
                adapter.guard!.reason != PrivateTextReason.none
            ? adapter.guard!.reason
            : adapter.reason;
        if (cancelToken.isCancelled && reason != PrivateTextReason.notCurrent) {
          reason = PrivateTextReason.cancelled;
        }
        if (!current()) {
          reason = PrivateTextReason.notCurrent;
        }
        if (reason == PrivateTextReason.none && nativeFailed) {
          reason = PrivateTextReason.transport;
        }
        if (reason == PrivateTextReason.none &&
            (!nativeComplete || adapter.guard?.decoder.terminal != true)) {
          reason = PrivateTextReason.unexpectedEof;
        }
      }
      if (adapter.admittedFailed) reason = PrivateTextReason.admittedFailed;
    } on PrivateTextFailure catch (failure) {
      reason = failure.reason;
    } catch (_) {
      reason = PrivateTextReason.transport;
    } finally {
      timer?.cancel();
      try {
        dio?.close(force: true);
      } catch (_) {
        if (reason == PrivateTextReason.none) {
          reason = PrivateTextReason.transport;
        }
      }
    }
    final decoder = adapter?.guard?.decoder;
    var text = '';
    try {
      text = currentRedactor()
          .withKnownSecrets(
            [request.apiKey],
            maxInputLength: PrivateTextLimits.responseCharacters,
            maxOutputLength: PrivateTextLimits.responseCharacters,
          )
          .redactText(decoder?.text ?? '');
      if (text == SecretRedactor.limited ||
          text.length > PrivateTextLimits.responseCharacters) {
        text = '';
        reason = PrivateTextReason.sanitationLimit;
      }
    } catch (_) {
      reason = PrivateTextReason.sanitationLimit;
    }
    if (reason == PrivateTextReason.none && decoder?.limited == true) {
      reason = PrivateTextReason.providerLimit;
    }
    if (adapter?.admittedFailed == true) {
      reason = PrivateTextReason.admittedFailed;
      text = '';
    }
    final status = switch (reason) {
      PrivateTextReason.cancelled ||
      PrivateTextReason.notCurrent => PrivateTextStatus.stopped,
      PrivateTextReason.outputLimit ||
      PrivateTextReason.providerLimit ||
      PrivateTextReason.wireLimit ||
      PrivateTextReason.sanitationLimit => PrivateTextStatus.limited,
      PrivateTextReason.none => PrivateTextStatus.complete,
      _ => text.isEmpty ? PrivateTextStatus.error : PrivateTextStatus.partial,
    };
    return PrivateTextOutcome(
      status: status,
      text: text,
      reason: reason,
      // Invalid terminal/native settlement never upgrades status. Earlier
      // accepted snapshots remain evidence; an unadmitted failure has none.
      usage: adapter?.admittedFailed == true ? null : decoder?.usage,
      httpStatus: reason == PrivateTextReason.httpStatus
          ? adapter?.httpStatus
          : null,
      dispatch: adapter?.admittedFailed == true
          ? PrivateTextDispatch.admittedFailed
          : (adapter?.dispatchCount ?? 0) > 0
          ? PrivateTextDispatch.admitted
          : PrivateTextDispatch.notAdmitted,
    );
  }

  ChatTransport _native(
    PrivateTextRequestPlan plan,
    Dio dio,
  ) => switch (plan.protocol) {
    LlmProtocol.anthropic => AnthropicChatTransport(dio: dio),
    LlmProtocol.gemini => GeminiChatTransport(dio: dio),
    LlmProtocol.openaiResponses => OpenAiResponsesTransport(dio: dio),
    LlmProtocol.customChatCompletion => CustomChatCompletionTransport(
      chatCompletions: OpenAiChatTransport(
        dio: dio,
        protocol: LlmProtocol.customChatCompletion,
      ),
      responses: OpenAiResponsesTransport(dio: dio),
    ),
    // The OR outer wrapper adds only routing/cache/diagnostic behavior. Cache
    // and session forwarding are forbidden here; reuse its actual native inner
    // with the same hardcoded recipient/headers, without its model debug log.
    LlmProtocol.openrouter => OpenAiChatTransport(
      dio: dio,
      protocol: LlmProtocol.openrouter,
      extraHeaders: OpenRouterChatTransport.extraHeaders,
    ),
    _ => OpenAiChatTransport(dio: dio),
  };
}
