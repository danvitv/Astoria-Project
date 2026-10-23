import 'dart:math';

import '../llm/transport/llm_protocol.dart';

/// Allocated by native preparation BEFORE review. There is no parsing/import API.
final class NativeKeylessConnectionId {
  NativeKeylessConnectionId.generate() : value = _generate();
  final String value;

  static String _generate() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return 'native-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

/// Native inputs, not a model/tool DTO. No keys, embedding or extra parameters.
final class KeylessApiConfigDraft {
  KeylessApiConfigDraft({
    required NativeKeylessConnectionId nativeId,
    required String displayName,
    required String providerId,
    required String protocol,
    required String endpoint,
    required String model,
    required int maxTokens,
    required int contextSize,
    required double temperature,
  }) : view = KeylessApiConfigView.native(
         connectionId: nativeId.value,
         displayName: displayName,
         providerId: providerId,
         protocol: protocol,
         endpoint: endpoint,
         model: model,
         maxTokens: maxTokens,
         contextSize: contextSize,
         temperature: temperature,
       );
  final KeylessApiConfigView view;
}

/// Entire allowlisted reviewed patch. Routing/provider/protocol cannot change.
final class KeylessApiConfigPatch {
  KeylessApiConfigPatch({
    required this.displayName,
    required this.model,
    required this.maxTokens,
    required this.contextSize,
    required this.temperature,
  });
  final String displayName;
  final String model;
  final int maxTokens;
  final int contextSize;
  final double temperature;

  KeylessApiConfigView applyTo(KeylessApiConfigView before) =>
      KeylessApiConfigView.native(
        connectionId: before.connectionId,
        displayName: displayName,
        providerId: before.providerId,
        protocol: before.protocol,
        endpoint: before.endpoint,
        model: model,
        maxTokens: maxTokens,
        contextSize: contextSize,
        temperature: temperature,
      );
}

/// Safe immutable projection only. It carries no authority or executable JSON.
final class KeylessApiConfigView {
  KeylessApiConfigView.native({
    required this.connectionId,
    required this.displayName,
    required this.providerId,
    required this.protocol,
    required this.endpoint,
    required this.model,
    required this.maxTokens,
    required this.contextSize,
    required this.temperature,
  }) {
    if (!isValid) throw const FormatException('Invalid native connection.');
  }
  final String connectionId;
  final String displayName;
  final String providerId;
  final String protocol;
  final String endpoint;
  final String model;
  final int maxTokens;
  final int contextSize;
  final double temperature;

  bool get isValid =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(connectionId) &&
      _text(displayName, 128) &&
      RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(providerId) &&
      LlmProtocol.isValid(protocol) &&
      _text(model, 200) &&
      !RegExp(r'[\s%?#\\]').hasMatch(model) &&
      maxTokens > 0 &&
      maxTokens <= 32768 &&
      contextSize >= maxTokens &&
      contextSize <= 2000000 &&
      temperature.isFinite &&
      temperature >= 0 &&
      temperature <= 2 &&
      _endpoint();

  bool _endpoint() {
    if (endpoint.length > 2048 ||
        RegExp(r'[\s%\\?#\x00-\x1f\x7f]').hasMatch(endpoint)) {
      return false;
    }
    try {
      final uri = Uri.parse(endpoint);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.toString() != endpoint ||
          uri.pathSegments.any((s) => s.isEmpty || s == '.' || s == '..')) {
        return false;
      }
      final suffix = switch (protocol) {
        LlmProtocol.anthropic => '/messages',
        LlmProtocol.openaiResponses => '/responses',
        LlmProtocol.gemini => '/models/$model:streamGenerateContent',
        _ => '/chat/completions',
      };
      // Native reviews already contain the final compatible URL. In particular,
      // legacy OpenRouter normalization forces its default host: applying it here
      // would reject or redirect an explicitly reviewed custom destination.
      // This is structural validation ONLY; core route approval remains separate.
      return uri.path.endsWith(suffix);
    } on FormatException {
      return false;
    }
  }

  static bool _text(String value, int max) =>
      value.isNotEmpty &&
      value == value.trim() &&
      value.length <= max &&
      !RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]').hasMatch(value);

  @override
  bool operator ==(Object other) =>
      other is KeylessApiConfigView &&
      connectionId == other.connectionId &&
      displayName == other.displayName &&
      providerId == other.providerId &&
      protocol == other.protocol &&
      endpoint == other.endpoint &&
      model == other.model &&
      maxTokens == other.maxTokens &&
      contextSize == other.contextSize &&
      temperature == other.temperature;
  @override
  int get hashCode => Object.hash(
    connectionId,
    displayName,
    providerId,
    protocol,
    endpoint,
    model,
    maxTokens,
    contextSize,
    temperature,
  );
}
