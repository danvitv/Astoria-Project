import 'dart:convert';

import '../../credentials/secret_redactor.dart';
import 'anthropic_chat_transport.dart';
import 'chat_transport_request.dart';
import 'gemini_chat_transport.dart';
import 'llm_protocol.dart';
import 'openai_chat_transport.dart';
import 'openai_responses_transport.dart';
import 'openrouter_chat_transport.dart';
import 'private_text_outcome.dart';

/// Trusted native preparation only; never give this owner to widgets/tools.
final class PrivateTextRequestPlan {
  PrivateTextRequestPlan(
    String protocol,
    ChatTransportRequest input,
    Uri approved,
    SecretRedactor redactor,
  ) {
    if (!LlmProtocol.isValid(protocol) || !input.stream) {
      throw const PrivateTextFailure(PrivateTextReason.unsupported);
    }
    if (input.endpoint.isEmpty || input.endpoint.length > 2048) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    final responses =
        protocol == LlmProtocol.openaiResponses ||
        (protocol == LlmProtocol.customChatCompletion && input.useResponsesApi);
    final endpoint = protocol == LlmProtocol.openrouter
        ? Uri.parse(OpenRouterChatTransport.baseUrl)
        : Uri.tryParse(input.endpoint);
    if (endpoint == null ||
        endpoint != approved ||
        endpoint.scheme != 'https' ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.port < 1 ||
        endpoint.port > 65535 ||
        endpoint.toString().contains(input.apiKey) ||
        endpoint.toString().contains(Uri.encodeComponent(input.apiKey)) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        RegExp(r'[\s\\]').hasMatch(input.endpoint) ||
        input.apiKey.isEmpty ||
        input.apiKey.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(input.apiKey) ||
        input.model.isEmpty ||
        input.model.length > 256 ||
        redactor.redactText(input.model) != input.model) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    final safeRecipient = redactor.redactUrl(endpoint.toString());
    if (safeRecipient == SecretRedactor.removed ||
        safeRecipient == SecretRedactor.limited ||
        safeRecipient.contains(Uri.encodeComponent(SecretRedactor.removed))) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    if (protocol == LlmProtocol.gemini &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(input.model)) {
      throw const PrivateTextFailure(PrivateTextReason.unsupported);
    }
    final validPath = switch (protocol) {
      LlmProtocol.gemini =>
        endpoint.path == '/v1beta/models/${input.model}:streamGenerateContent',
      LlmProtocol.anthropic => const [
        '/v1/messages',
        '/messages',
      ].contains(endpoint.path),
      _ when responses => const [
        '/v1/responses',
        '/api/v1/responses',
        '/responses',
      ].contains(endpoint.path),
      _ => const [
        '/v1/chat/completions',
        '/api/v1/chat/completions',
        '/chat/completions',
      ].contains(endpoint.path),
    };
    if (!validPath) {
      throw const PrivateTextFailure(PrivateTextReason.unsupported);
    }
    if (input.tools != null ||
        input.toolChoice != null ||
        input.responseJsonSchema != null ||
        input.sessionId != null ||
        input.previousMessages != null ||
        input.cacheControlTtl != 'off' ||
        input.promptPostProcessing != 'none' ||
        input.captureContext != null ||
        input.extraRequestParameters.any((entry) => entry.enabled) ||
        input.messages.isEmpty ||
        input.messages.length > PrivateTextLimits.messages ||
        input.messages.last['role'] != 'user' ||
        (input.maxTokens != -1 &&
            (input.maxTokens < 1 || input.maxTokens > 0x7fffffff)) ||
        !input.temperature.isFinite ||
        !input.topP.isFinite ||
        !input.frequencyPenalty.isFinite ||
        !input.presencePenalty.isFinite) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    var characters = 0;
    var bytes = 0;
    final messages = <Map<String, dynamic>>[];
    for (final message in input.messages) {
      final content = message['content'];
      if (message.length != 2 ||
          content is! String ||
          !const ['system', 'user', 'assistant'].contains(message['role']) ||
          content.length > PrivateTextLimits.contextCharacters) {
        throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
      }
      characters += content.length;
      if (characters > PrivateTextLimits.contextCharacters) {
        throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
      }
      bytes += utf8.encode(content).length;
      if (bytes > PrivateTextLimits.contextBytes ||
          utf8.decode(utf8.encode(content)) != content ||
          redactor.redactText(content) != content) {
        throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
      }
      messages.add(Map<String, dynamic>.unmodifiable(message));
    }
    if ((messages.last['content'] as String).isEmpty ||
        (messages.last['content'] as String).length >
            PrivateTextLimits.currentCharacters) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    request = ChatTransportRequest(
      endpoint: endpoint.toString(),
      apiKey: input.apiKey,
      model: input.model,
      messages: List.unmodifiable(messages),
      maxTokens: input.maxTokens,
      temperature: input.temperature,
      topP: input.topP,
      topK: input.topK,
      frequencyPenalty: input.frequencyPenalty,
      presencePenalty: input.presencePenalty,
      useResponsesApi: responses,
      requestReasoning: input.requestReasoning,
      reasoningEffort: input.reasoningEffort,
      omitTemperature: input.omitTemperature,
      omitTopP: input.omitTopP,
      omitTopK: input.omitTopK,
      omitFrequencyPenalty: input.omitFrequencyPenalty,
      omitPresencePenalty: input.omitPresencePenalty,
      omitReasoning: input.omitReasoning,
      omitReasoningEffort: input.omitReasoningEffort,
      showNativeReasoning: false,
      receiveTimeoutMs: 120000,
      sessionIdMode: 'off',
      useSystemInstruction: input.useSystemInstruction,
      completionMetadataSink: input.completionMetadataSink,
    );
    this.protocol = protocol;
    recipient = endpoint;
    decoderProtocol = responses ? LlmProtocol.openaiResponses : protocol;
    final Map<String, dynamic> body;
    if (protocol == LlmProtocol.gemini) {
      final built = GeminiChatTransport.buildRequest(request);
      wireUri = Uri.parse(built.url);
      headers = built.headers;
      body = built.body;
    } else if (protocol == LlmProtocol.anthropic) {
      final built = AnthropicChatTransport.buildRequest(request);
      wireUri = endpoint;
      headers = built.headers;
      body = built.body;
    } else {
      wireUri = endpoint;
      headers = {
        'Authorization': 'Bearer ${input.apiKey}',
        'Content-Type': 'application/json',
        if (protocol == LlmProtocol.openrouter)
          ...OpenRouterChatTransport.extraHeaders,
      };
      body = responses
          ? OpenAiResponsesTransport.buildBody(request)
          : OpenAiChatTransport.buildBody(request, protocol: protocol);
    }
    bodyJson = jsonEncode(body);
    if (utf8.encode(bodyJson).length > PrivateTextLimits.requestBytes) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
  }

  late final String protocol;
  late final String decoderProtocol;
  late final ChatTransportRequest request;
  late final Uri recipient;
  late final Uri wireUri;
  late final Map<String, String> headers;
  late final String bodyJson;

  void recheckSanitation(SecretRedactor current) {
    final redactor = current.withKnownSecrets(
      [request.apiKey],
      maxInputLength: PrivateTextLimits.contextCharacters,
      maxOutputLength: PrivateTextLimits.contextCharacters,
    );
    final safeRecipient = redactor.redactUrl(recipient.toString());
    if (redactor.redactText(request.model) != request.model ||
        safeRecipient == SecretRedactor.removed ||
        safeRecipient == SecretRedactor.limited ||
        safeRecipient.contains(Uri.encodeComponent(SecretRedactor.removed)) ||
        !request.messages.every(
          (message) =>
              redactor.redactText(message['content'] as String) ==
              message['content'],
        )) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
  }

  @override
  String toString() => 'PrivateTextRequestPlan';
}

/// Fixed-safe internal failure. Never carries a provider message or payload.
final class PrivateTextFailure implements Exception {
  const PrivateTextFailure(this.reason);
  final PrivateTextReason reason;
  @override
  String toString() => 'Private text request failed';
}
