/// A failed stream together with the output received before it failed.
class ChatStreamException implements Exception {
  final String reason;
  final String partialText;
  final String partialReasoning;
  final String message;

  const ChatStreamException({
    required this.reason,
    required this.message,
    required this.partialText,
    required this.partialReasoning,
  });

  @override
  String toString() => 'ChatStreamException($reason): $message';
}
