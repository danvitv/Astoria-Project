part of 'private_text_event_decoder.dart';

final class _ChatEvents extends PrivateTextEventDecoder {
  _ChatEvents() : super._();
  String? _finish;
  @override
  bool get acceptsDone => true;
  @override
  bool get canFinishAtEof => _finish != null;
  @override
  void done() {
    require(_finish != null);
    terminal = true;
  }

  @override
  List<Map<String, dynamic>> consume(Map<String, dynamic> event) {
    if (event['error'] != null) fail(PrivateTextReason.providerError);
    final choices = event['choices'];
    require(choices is List);
    if ((choices as List).isEmpty) {
      require(event['usage'] is Map);
      _recordUsage(_chatUsage(event['usage']));
      return [];
    }
    require(choices.length == 1 && choices.first is Map);
    final choice = choices.first as Map;
    require(choice['index'] == null || choice['index'] == 0);
    final delta = choice['delta'];
    require(delta is Map);
    final map = delta as Map;
    if (map['tool_calls'] != null || map['function_call'] != null) {
      fail(PrivateTextReason.unsupported);
    }
    if (map['refusal'] != null) fail(PrivateTextReason.providerError);
    require(map['role'] == null || map['role'] == 'assistant');
    require(map['content'] == null || map['content'] is String);
    for (final field in ['reasoning', 'reasoning_content']) {
      require(map[field] == null || map[field] is String);
    }
    final text = map['content'] as String? ?? '';
    require(_finish == null || text.isEmpty);
    append(text);
    final reason = choice['finish_reason'];
    if (reason != null) {
      require(reason is String && _finish == null);
      switch (reason) {
        case 'stop':
          break;
        case 'length':
          limited = true;
        case 'content_filter':
          fail(PrivateTextReason.providerError);
        default:
          fail(PrivateTextReason.unsupported);
      }
      _finish = reason as String;
    }
    _recordUsage(_chatUsage(event['usage']));
    return [
      {
        'choices': [
          {
            'index': 0,
            'delta': {'content': text},
            'finish_reason': reason,
          },
        ],
      },
    ];
  }
}

final class _ResponsesEvents extends PrivateTextEventDecoder {
  _ResponsesEvents() : super._();
  @override
  List<Map<String, dynamic>> consume(Map<String, dynamic> event) {
    if (event['error'] != null) fail(PrivateTextReason.providerError);
    final type = event['type'];
    require(type is String && !terminal);
    switch (type) {
      case 'error':
      case 'response.failed':
        fail(PrivateTextReason.providerError);
      case 'response.incomplete':
        final response = event['response'];
        require(response is Map);
        final detail = (response as Map)['incomplete_details'];
        if (detail is! Map || detail['reason'] != 'max_output_tokens') {
          fail(PrivateTextReason.providerError);
        }
        _recordUsage(_responsesUsage(response['usage']));
        limited = true;
        terminal = true;
        return [];
      case 'response.completed':
        final response = event['response'];
        require(response is Map && response['status'] == 'completed');
        final map = response as Map;
        if (map['error'] != null || map['incomplete_details'] != null) {
          fail(PrivateTextReason.providerError);
        }
        _validateOutput(map['output']);
        _recordUsage(_responsesUsage(map['usage']));
        terminal = true;
        return [
          {
            'type': type,
            'response': {'status': 'completed'},
          },
        ];
      case 'response.output_text.delta':
        final delta = event['delta'];
        require(delta is String);
        append(delta as String);
        return [
          {'type': type, 'delta': delta},
        ];
      case 'response.output_text.done':
        require(event['text'] is String && event['text'] == text);
        return [];
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = event['item'];
        require(item is Map);
        if (!const ['message', 'reasoning'].contains((item as Map)['type'])) {
          fail(PrivateTextReason.unsupported);
        }
        return [];
      case 'response.content_part.added':
      case 'response.content_part.done':
        final part = event['part'];
        require(part is Map);
        if ((part as Map)['type'] != 'output_text') {
          fail(PrivateTextReason.providerError);
        }
        return [];
      case 'response.created':
      case 'response.in_progress':
      case 'response.queued':
      case 'response.reasoning_summary_part.added':
      case 'response.reasoning_summary_part.done':
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_summary_text.done':
      case 'response.reasoning_text.delta':
      case 'response.reasoning_text.done':
        return [];
      default:
        fail(PrivateTextReason.unsupported);
    }
  }

  void _validateOutput(Object? output) {
    require(output is List);
    final finalText = StringBuffer();
    for (final item in output as List) {
      require(item is Map);
      if ((item as Map)['type'] == 'reasoning') continue;
      if (item['type'] != 'message') fail(PrivateTextReason.unsupported);
      require(item['role'] == 'assistant' && item['content'] is List);
      for (final part in item['content'] as List) {
        require(part is Map);
        if ((part as Map)['type'] != 'output_text') {
          fail(PrivateTextReason.providerError);
        }
        require(part['text'] is String);
        finalText.write(part['text']);
      }
    }
    require(finalText.toString() == text);
  }
}

ProviderTokenUsage _chatUsage(Object? value) {
  final map = _usageMap(value);
  return ProviderTokenUsage(
    inputTokens: _tokenCount(map, 'prompt_tokens'),
    outputTokens: _tokenCount(map, 'completion_tokens'),
    totalTokens: _tokenCount(map, 'total_tokens'),
    cachedInputTokens: _tokenCount(
      _usageMap(map['prompt_tokens_details']),
      'cached_tokens',
    ),
    reasoningTokens: _tokenCount(
      _usageMap(map['completion_tokens_details']),
      'reasoning_tokens',
    ),
  );
}

ProviderTokenUsage _responsesUsage(Object? value) {
  final map = _usageMap(value);
  return ProviderTokenUsage(
    inputTokens: _tokenCount(map, 'input_tokens'),
    outputTokens: _tokenCount(map, 'output_tokens'),
    totalTokens: _tokenCount(map, 'total_tokens'),
    cachedInputTokens: _tokenCount(
      _usageMap(map['input_tokens_details']),
      'cached_tokens',
    ),
    reasoningTokens: _tokenCount(
      _usageMap(map['output_tokens_details']),
      'reasoning_tokens',
    ),
  );
}
