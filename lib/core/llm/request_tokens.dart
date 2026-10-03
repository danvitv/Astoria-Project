import 'tokenizer.dart';

/// Counts request text consistently in the next-request and capture views.
/// Image parts and their redaction records are not text; the provider accounts
/// for them separately. Replayed reasoning is included.
int countRequestTokens(Iterable<Map<String, dynamic>> messages) => messages
    .fold(0, (total, message) => total + countRequestMessageTokens(message));

int countRequestMessageTokens(Map<String, dynamic> message) {
  var total = 0;
  for (final text in _texts(message['content'])) {
    total += estimateTokens(text);
  }
  final reasoning = message['reasoning_content'];
  if (reasoning is String) total += estimateTokens(reasoning);
  return total;
}

Iterable<String> _texts(Object? content) sync* {
  if (content is String) {
    yield content;
  } else if (content is List) {
    for (final part in content) {
      yield* _texts(part);
    }
  } else if (content is Map) {
    final text = content['text'];
    // A truncated capture retains only its prefix, so this count is a floor.
    if ((content['type'] == 'text' || content['kind'] == 'truncated_text') &&
        text is String) {
      yield text;
    }
  }
}
