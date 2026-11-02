import '../models/chat_message.dart';
import 'embedding_service.dart';

/// A lossless substring of the complete role-prefixed group. Never crosses a
/// message boundary; offsets remain valid even when identical phrases repeat.
class ChatMessageEmbeddingChunk {
  final String text;
  final int groupStart;

  const ChatMessageEmbeddingChunk({
    required this.text,
    required this.groupStart,
  });

  int get groupEnd => groupStart + text.length;
}

abstract final class ChatMessageEmbeddingChunks {
  static const version = 2;

  static List<ChatMessageEmbeddingChunk> split(
    List<ChatMessage> messages,
    int maxChunkTokens,
  ) {
    final result = <ChatMessageEmbeddingChunk>[];
    var groupOffset = 0;
    for (final message in messages) {
      final source = '${message.role}: ${message.content}';
      var cursor = 0;
      for (final text in EmbeddingService.splitTextIntoChunks(
        source,
        maxChunkTokens,
      )) {
        final start = source.indexOf(text, cursor);
        if (start < 0) {
          throw StateError('Embedding chunk no longer matches its source');
        }
        result.add(
          ChatMessageEmbeddingChunk(
            text: text,
            groupStart: groupOffset + start,
          ),
        );
        cursor = start + text.length;
      }
      groupOffset += source.length + 2;
    }
    return result;
  }
}
