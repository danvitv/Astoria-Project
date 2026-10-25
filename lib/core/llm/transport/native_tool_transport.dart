import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../credentials/native_provider_credentials.dart';
import '../../credentials/secret_redactor.dart';
import '../../models/api_config.dart';
import '../converters/reasoning_effort.dart';
import '../converters/thinking_budget.dart';
import 'native_tool_types.dart';

export 'native_tool_types.dart';

part 'native_tool_session.dart';
part 'native_tool_admission.dart';
part 'native_tool_wire.dart';
part 'native_tool_protocol.dart';
part 'native_tool_openai.dart';
part 'native_tool_anthropic_gemini.dart';
part 'native_tool_usage.dart';
part 'native_tool_reasoning.dart';
part 'native_tool_legacy_saved.dart';

/// Original saved configuration. Not a key/route/tool approval issuer.
final class NativeToolRequest {
  NativeToolRequest({
    required ApiConfig config,
    required SavedConnectionAuth savedConnectionAuth,
    required Uri approvedRecipient,
    required List<NativeToolDefinition> tools,
    required List<NativeToolMessage> messages,
  }) : this._(
         config: config,
         savedConnectionAuth: savedConnectionAuth,
         approvedRecipient: approvedRecipient,
         tools: tools,
         messages: messages,
       );

  /// Trusted composition only, for the actual ordinary saved-row key accepted
  /// by the original Send. No native auth, entry, destination approval or key
  /// lookup is invented. The public config is keyless; the key stays private.
  factory NativeToolRequest.legacySaved({
    required ApiConfig config,
    required NativeConnectionStamp sourceStamp,
    required Uri approvedRecipient,
    required List<NativeToolDefinition> tools,
    required List<NativeToolMessage> messages,
  }) {
    final source = _LegacySavedToolSource(
      config,
      sourceStamp,
      approvedRecipient,
    );
    return NativeToolRequest._(
      config: config.copyWith(apiKey: ''),
      savedConnectionAuth: null,
      legacySaved: source,
      approvedRecipient: approvedRecipient,
      tools: tools,
      messages: messages,
    );
  }

  NativeToolRequest._({
    required this.config,
    required this.savedConnectionAuth,
    _LegacySavedToolSource? legacySaved,
    required this.approvedRecipient,
    required List<NativeToolDefinition> tools,
    required List<NativeToolMessage> messages,
  }) : _legacySaved = legacySaved,
       tools = _ntBoundedList(tools, NativeToolLimits.definitions),
       messages = _ntBoundedList(messages, NativeToolLimits.messages) {
    _ntRequire(
      config.apiKey.isEmpty &&
          config.embeddingApiKey.isEmpty &&
          !config.embeddingEnabled &&
          config.extraRequestParameters.isEmpty,
      NativeToolReason.denied,
    );
    _ntRequire(
      approvedRecipient.scheme == 'https' &&
          approvedRecipient.userInfo.isEmpty &&
          !approvedRecipient.hasQuery &&
          !approvedRecipient.hasFragment &&
          approvedRecipient.toString().length <= 2048,
      NativeToolReason.denied,
    );
    _ntRequire(
      tools.isNotEmpty &&
          tools.length <= NativeToolLimits.definitions &&
          messages.isNotEmpty &&
          messages.length <= NativeToolLimits.messages,
      NativeToolReason.limit,
    );
    _ntRequire(tools.map((tool) => tool.name).toSet().length == tools.length);
  }
  final ApiConfig config;
  final SavedConnectionAuth? savedConnectionAuth;
  final _LegacySavedToolSource? _legacySaved;
  final Uri approvedRecipient;
  final List<NativeToolDefinition> tools;
  final List<NativeToolMessage> messages;
  @override
  String toString() => 'NativeToolRequest';
}

/// Construct only in trusted native composition. No per-tool adapter/auth ports,
/// legacy picker, logger, interceptor, diagnostic capture or fallback.
final class NativeToolTransport {
  const NativeToolTransport({
    required this.credentials,
    required this.authIssuer,
    required this.mutations,
    required this.routes,
    required this.currentRedactor,
    required this.adapterFactory,
    this.scheduleDeadline = Timer.new,
  });
  final NativeProviderCredentialVault credentials;
  final NativeSavedConnectionAuthIssuer authIssuer;
  final NativeConnectionMutationOwner mutations;
  final NativeProviderRoutePolicy routes;
  final SecretRedactor Function() currentRedactor;
  final HttpClientAdapter Function() adapterFactory;
  final Timer Function(Duration, void Function()) scheduleDeadline;

  NativeToolSession open({
    required NativeToolRequest request,
    required CancelToken cancelToken,
    required bool Function() isCurrent,
    required NativeToolAdmission beforeWire,
    Duration deadline = NativeToolLimits.deadline,
  }) {
    _ntRequire(
      deadline > Duration.zero && deadline <= NativeToolLimits.deadline,
    );
    return NativeToolSession._(
      this,
      request,
      cancelToken,
      isCurrent,
      beforeWire,
      deadline,
    );
  }
}

Never _ntFail(NativeToolReason reason) => throw NativeToolException(reason);
void _ntRequire(
  bool condition, [
  NativeToolReason reason = NativeToolReason.malformed,
]) {
  if (!condition) _ntFail(reason);
}

bool _ntCurrent(bool Function() predicate) {
  try {
    return predicate();
  } catch (_) {
    return false;
  }
}

List<T> _ntBoundedList<T>(List<T> input, int max) {
  _ntRequire(input.isNotEmpty && input.length <= max, NativeToolReason.limit);
  return List<T>.unmodifiable(input);
}

NativeToolReason _ntCredentialReason(NativeProviderFailure reason) =>
    switch (reason) {
      NativeProviderFailure.stale => NativeToolReason.notCurrent,
      NativeProviderFailure.unavailable => NativeToolReason.transport,
      _ => NativeToolReason.denied,
    };
