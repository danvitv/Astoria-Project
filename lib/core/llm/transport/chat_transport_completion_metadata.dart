/// Finite provider-wire completion facts emitted by a transport parser. No raw
/// payload, endpoint, model, request text or provider-authored error is kept.
final class ChatTransportCompletionMetadata {
  const ChatTransportCompletionMetadata._({
    required this.wireProtocol,
    required this.finishReasonSource,
    required this.termination,
    required this.finishReason,
  });

  final String wireProtocol;
  final String finishReasonSource;
  final String termination;
  final String? finishReason;

  factory ChatTransportCompletionMetadata.provider({
    required String wireProtocol,
    required String finishReasonSource,
    required String termination,
    Object? finishReason,
  }) => ChatTransportCompletionMetadata._(
    wireProtocol: wireProtocol,
    finishReasonSource: finishReasonSource,
    termination: termination,
    finishReason: _normalize(finishReason),
  );

  static String? _normalize(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    return switch (normalized) {
      'stop' || 'end_turn' || 'completed' => 'stop',
      'length' || 'max_tokens' || 'max_output_tokens' => 'length',
      'content_filter' ||
      'safety' ||
      'recitation' ||
      'prohibited_content' => 'content_filter',
      'tool_calls' || 'tool_use' => 'tool_calls',
      'function_call' => 'function_call',
      'stop_sequence' => 'stop_sequence',
      'refusal' => 'refusal',
      'pause_turn' => 'pause_turn',
      _ => 'other',
    };
  }
}

abstract final class ChatTransportCompletionCapture {
  static void record(
    ChatTransportCompletionMetadata metadata, {
    required void Function(ChatTransportCompletionMetadata metadata)? sink,
  }) {
    sink?.call(metadata);
  }
}
