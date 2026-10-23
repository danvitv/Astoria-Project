part of 'native_provider_transport.dart';

/// One-shot payloads are validated through the same unchanged strict text
/// decoder by projecting their final message into protocol terminal events.
_NativeProjectionDelta _nativeCompletion(
  _NativeEventProjection projection,
  Map<String, dynamic> response,
) {
  _nativeRequire(
    response['error'] == null,
    NativeProviderTransportReason.providerError,
  );
  final protocol = projection.protocol;
  if (protocol == LlmProtocol.gemini) {
    final delta = projection.consume(response);
    projection.finish();
    return delta;
  }
  if (protocol == LlmProtocol.anthropic) {
    _nativeRequire(
      response['type'] == 'message' &&
          response['role'] == 'assistant' &&
          response['content'] is List,
    );
    projection.consume({
      'type': 'message_start',
      'message': {
        'role': 'assistant',
        'content': <Object?>[],
        'stop_reason': null,
      },
    });
    final text = StringBuffer();
    final reasoning = StringBuffer();
    var index = 0;
    for (final block in response['content'] as List) {
      _nativeRequire(block is Map<String, dynamic>);
      final delta = projection.consume({
        'type': 'content_block_start',
        'index': index,
        'content_block': block,
      });
      text.write(delta.text);
      reasoning.write(delta.reasoning);
      projection.consume({'type': 'content_block_stop', 'index': index++});
    }
    projection.consume({
      'type': 'message_delta',
      'delta': {'stop_reason': response['stop_reason']},
    });
    projection.consume({'type': 'message_stop'});
    projection.finish();
    return _NativeProjectionDelta(text.toString(), reasoning.toString());
  }
  if (protocol == LlmProtocol.openaiResponses) {
    _nativeRequire(response['output'] is List);
    final text = StringBuffer();
    final reasoning = StringBuffer();
    for (final item in response['output'] as List) {
      _nativeRequire(item is Map);
      final map = item as Map;
      if (map['type'] == 'reasoning') {
        final summary = map['summary'];
        _nativeRequire(summary == null || summary is List);
        for (final part in summary as List? ?? const []) {
          _nativeRequire(
            part is Map &&
                part['type'] == 'summary_text' &&
                part['text'] is String,
          );
          reasoning.write(part['text']);
        }
      } else {
        _nativeRequire(
          map['type'] == 'message' &&
              map['role'] == 'assistant' &&
              map['content'] is List,
          NativeProviderTransportReason.unsupported,
        );
        for (final part in map['content'] as List) {
          _nativeRequire(
            part is Map &&
                part['type'] == 'output_text' &&
                part['text'] is String,
            NativeProviderTransportReason.unsupported,
          );
          text.write(part['text']);
        }
      }
    }
    final visible = text.toString();
    projection.consume({
      'type': 'response.output_text.delta',
      'delta': visible,
    });
    final why = response['status'];
    _nativeRequire(why == 'completed' || why == 'incomplete');
    if (why == 'incomplete') {
      // Incomplete output still has to remain entirely text-only.
      projection.consume({
        'type': 'response.output_item.done',
        'item': {'type': 'message'},
      });
    }
    projection.consume({
      'type': why == 'completed' ? 'response.completed' : 'response.incomplete',
      'response': response,
    });
    projection.finish();
    _nativeRequire(
      reasoning.length <= NativeProviderTransportLimits.outputCharacters,
      NativeProviderTransportReason.outputLimit,
    );
    return _NativeProjectionDelta(visible, reasoning.toString());
  }
  final choices = response['choices'];
  _nativeRequire(
    choices is List && choices.length == 1 && choices.first is Map,
  );
  final choice = (choices as List).single as Map;
  final message = choice['message'];
  _nativeRequire(message is Map && message['role'] == 'assistant');
  final delta = projection.consume({
    'choices': [
      {
        'index': choice['index'],
        'delta': message,
        'finish_reason': choice['finish_reason'],
      },
    ],
  });
  try {
    projection.decoder.done();
  } on PrivateTextFailure catch (failure) {
    _nativeFail(_privateReason(failure.reason));
  }
  projection.finish();
  return delta;
}
