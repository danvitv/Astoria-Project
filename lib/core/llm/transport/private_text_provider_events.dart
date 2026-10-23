part of 'private_text_event_decoder.dart';

final class _AnthropicEvents extends PrivateTextEventDecoder {
  _AnthropicEvents() : super._();
  final _blocks = <int, String>{};
  bool _started = false;
  bool _finished = false;
  @override
  List<Map<String, dynamic>> consume(Map<String, dynamic> event) {
    if (event['error'] != null || event['type'] == 'error') {
      fail(PrivateTextReason.providerError);
    }
    final type = event['type'];
    require(type is String && !terminal);
    if (type == 'ping') return [];
    if (type == 'message_start') {
      require(!_started && event['message'] is Map);
      final message = event['message'] as Map;
      require(
        message['role'] == 'assistant' &&
            message['content'] is List &&
            (message['content'] as List).isEmpty &&
            message['stop_reason'] == null,
      );
      _started = true;
      return [];
    }
    require(_started && !_finished || type == 'message_stop');
    switch (type) {
      case 'content_block_start':
        final index = event['index'];
        final block = event['content_block'];
        require(
          index is int &&
              index >= 0 &&
              index <= 512 &&
              block is Map &&
              !_blocks.containsKey(index),
        );
        final kind = (block as Map)['type'];
        if (!const ['text', 'thinking', 'redacted_thinking'].contains(kind)) {
          fail(PrivateTextReason.unsupported);
        }
        _blocks[index as int] = kind as String;
        if (kind != 'text') return [];
        require(block['text'] is String);
        final text = block['text'] as String;
        append(text);
        return [
          {
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': text},
          },
        ];
      case 'content_block_delta':
        final delta = event['delta'];
        final index = event['index'];
        require(delta is Map && index is int && _blocks.containsKey(index));
        final map = delta as Map;
        if (map['type'] == 'text_delta') {
          require(_blocks[index] == 'text' && map['text'] is String);
          append(map['text'] as String);
          return [
            {
              'type': type,
              'delta': {'type': 'text_delta', 'text': map['text']},
            },
          ];
        }
        require(
          _blocks[index] == 'thinking' &&
              const ['thinking_delta', 'signature_delta'].contains(map['type']),
        );
        return [];
      case 'content_block_stop':
        require(
          event['index'] is int && _blocks.remove(event['index']) != null,
        );
        return [];
      case 'message_delta':
        require(_blocks.isEmpty && event['delta'] is Map);
        final reason = (event['delta'] as Map)['stop_reason'];
        switch (reason) {
          case 'end_turn':
          case 'stop_sequence':
            break;
          case 'max_tokens':
            limited = true;
          case 'refusal':
            fail(PrivateTextReason.providerError);
          default:
            fail(PrivateTextReason.unsupported);
        }
        _finished = true;
        return [];
      case 'message_stop':
        require(_started && _finished && _blocks.isEmpty);
        terminal = true;
        return [
          {'type': type},
        ];
      default:
        fail(PrivateTextReason.unsupported);
    }
  }
}

final class _GeminiEvents extends PrivateTextEventDecoder {
  _GeminiEvents() : super._();
  @override
  List<Map<String, dynamic>> consume(Map<String, dynamic> event) {
    if (event['error'] != null) fail(PrivateTextReason.providerError);
    require(!terminal);
    final feedback = event['promptFeedback'];
    if (feedback is Map && feedback['blockReason'] != null) {
      fail(PrivateTextReason.providerError);
    }
    final candidates = event['candidates'];
    require(
      candidates is List && candidates.length == 1 && candidates.first is Map,
    );
    final candidate = (candidates as List).first as Map;
    require(candidate['index'] == null || candidate['index'] == 0);
    final content = candidate['content'];
    final text = StringBuffer();
    if (content != null) {
      require(
        content is Map &&
            content['parts'] is List &&
            (content['role'] == null || content['role'] == 'model'),
      );
      for (final part in (content as Map)['parts'] as List) {
        require(part is Map);
        final map = part as Map;
        if (map.keys.any(
          (key) => !const ['text', 'thought', 'thoughtSignature'].contains(key),
        )) {
          fail(PrivateTextReason.unsupported);
        }
        if (map['text'] is! String) fail(PrivateTextReason.unsupported);
        require(map['thought'] == null || map['thought'] is bool);
        if (map['thought'] != true) text.write(map['text']);
      }
    }
    final delta = text.toString();
    append(delta);
    final reason = candidate['finishReason'];
    if (reason != null) {
      switch (reason) {
        case 'STOP':
          break;
        case 'MAX_TOKENS':
          limited = true;
        case 'SAFETY':
        case 'RECITATION':
        case 'BLOCKLIST':
        case 'PROHIBITED_CONTENT':
        case 'SPII':
          fail(PrivateTextReason.providerError);
        default:
          fail(PrivateTextReason.unsupported);
      }
      terminal = true;
    }
    return [
      {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': delta},
              ],
            },
          },
        ],
      },
    ];
  }
}
