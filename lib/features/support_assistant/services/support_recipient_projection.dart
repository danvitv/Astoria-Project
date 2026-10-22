import 'package:flutter/foundation.dart';

import '../../../core/credentials/secret_redactor.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/models/api_config.dart';
import '../models/support_permission_scope.dart';
import '../models/support_recipient_resolution.dart';

/// Pure trusted projection of actual transport routing; never builds an
/// authenticated request or silently repairs a questionable saved destination.
final class SupportRecipientProjection {
  const SupportRecipientProjection();

  SupportResolvedRecipient? project({
    required SupportRecipientContext context,
    required ApiConfig config,
    required String modelId,
    required int revision,
    required SecretRedactor redactor,
  }) {
    if (config.mode != 'chat' || !LlmProtocol.isValid(config.protocol)) {
      return null;
    }
    // Extras can affect provider routing. Even a benign active extra is denied
    // until its policy is reviewed; disabled extras have no request effect.
    if (config.extraRequestParameters.any((parameter) => parameter.enabled)) {
      return null;
    }
    final current = redactor.withKnownSecrets([
      config.apiKey,
      config.embeddingApiKey,
    ]);
    if (!_safeId(config.id, current) ||
        !_safeId(modelId, current) ||
        !_safeId(context.supportSessionId, current)) {
      return null;
    }

    final protocol = switch (config.protocol) {
      LlmProtocol.openai || LlmProtocol.customChatCompletion =>
        config.protocol == LlmProtocol.customChatCompletion &&
                config.useResponsesApi
            ? SupportRecipientProtocol.openaiResponses
            : SupportRecipientProtocol.openai,
      LlmProtocol.openaiResponses => SupportRecipientProtocol.openaiResponses,
      LlmProtocol.anthropic => SupportRecipientProtocol.anthropic,
      LlmProtocol.gemini => SupportRecipientProtocol.gemini,
      LlmProtocol.openrouter => SupportRecipientProtocol.openrouter,
      _ => null,
    };
    if (protocol == null) return null;
    // OpenRouter ignores the saved endpoint. Other native bindings validate the
    // raw persisted spelling, without adopting transport-time cleanup.
    final route = protocol == SupportRecipientProtocol.openrouter
        ? 'https://openrouter.ai/api/v1/chat/completions'
        : config.endpoint;
    final uri = Uri.tryParse(route);
    if (uri == null || !_safeRoute(route, uri, current)) return null;
    final pathAllowed = switch (protocol) {
      SupportRecipientProtocol.openai ||
      SupportRecipientProtocol.openrouter => const [
        '/v1/chat/completions',
        '/api/v1/chat/completions',
        '/chat/completions',
      ].contains(uri.path),
      SupportRecipientProtocol.openaiResponses => const [
        '/v1/responses',
        '/api/v1/responses',
        '/responses',
      ].contains(uri.path),
      SupportRecipientProtocol.anthropic => const [
        '/v1/messages',
        '/messages',
      ].contains(uri.path),
      SupportRecipientProtocol.gemini =>
        RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(modelId) &&
            uri.path ==
                '/v1beta/models/$modelId:${config.stream ? 'streamGenerateContent' : 'generateContent'}',
    };
    if (!pathAllowed) return null;
    try {
      return SupportResolvedRecipient(
        context: context,
        recipient: SupportPermissionRecipient(
          connectionId: config.id,
          modelId: modelId,
          protocol: protocol,
          nativeRoute: route,
          configurationRevision: revision,
        ),
        connectionLabel: _label(config.name, current),
        protocolLabel:
            config.protocol == LlmProtocol.customChatCompletion &&
                config.useResponsesApi
            ? 'Custom (Responses)'
            : LlmProtocol.labels[config.protocol]!,
        routingLabel: protocol == SupportRecipientProtocol.openrouter
            ? 'OpenRouter выбирает downstream-провайдера; он не подтверждён.'
            : 'Подтверждается адрес запроса, не внутренние маршруты провайдера.',
        originLabel: _origin(uri),
        operationLabel: switch (protocol) {
          SupportRecipientProtocol.openai ||
          SupportRecipientProtocol.openrouter => 'Chat Completions',
          SupportRecipientProtocol.openaiResponses => 'Responses',
          SupportRecipientProtocol.anthropic => 'Messages',
          SupportRecipientProtocol.gemini =>
            config.stream
                ? 'Gemini streamGenerateContent'
                : 'Gemini generateContent',
        },
      );
    } catch (_) {
      return null;
    }
  }

  // Called only after actual route/redactor/path and native recipient validation.
  // Preserve IPv6 grouping and non-default ports without URL/path/query syntax.
  String _origin(Uri uri) {
    final host = uri.host.contains(':') && !uri.host.startsWith('[')
        ? '[${uri.host}]'
        : uri.host;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final port = uri.port == defaultPort ? '' : ':${uri.port}';
    return '${uri.scheme.toUpperCase()} · $host$port';
  }

  bool _safeId(String value, SecretRedactor redactor) =>
      value.isNotEmpty &&
      value.length <= 256 &&
      RegExp(r'[A-Za-z0-9_.:/-]+').matchAsPrefix(value)?.end == value.length &&
      redactor.redactText(value) == value;

  bool _safeRoute(String route, Uri uri, SecretRedactor redactor) {
    if (route.length > 512 ||
        RegExp(r'\s').hasMatch(route) ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        route.contains('?') ||
        route.contains('#') ||
        route.contains('%') ||
        route.contains('@') ||
        route.contains('\\') ||
        uri.toString() != route) {
      return false;
    }
    // redactUrl escapes the legitimate Gemini operation colon. Compare parsed
    // paths, NOT a redacted string as a usable destination; changed tokens deny.
    final safe = Uri.tryParse(redactor.redactUrl(route));
    return safe != null &&
        safe.scheme == uri.scheme &&
        safe.authority == uri.authority &&
        listEquals(safe.pathSegments, uri.pathSegments) &&
        uri.pathSegments.every((s) => redactor.redactText(s) == s);
  }

  String _label(String raw, SecretRedactor redactor) {
    if (raw.length > 512) return 'Выбранное подключение';
    final safe = redactor
        .redactText(raw)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .trim();
    if (safe.isEmpty) return 'Выбранное подключение';
    return safe.length <= 96 ? safe : '${safe.substring(0, 95)}…';
  }
}
