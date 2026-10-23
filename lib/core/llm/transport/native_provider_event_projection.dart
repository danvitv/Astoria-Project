part of 'native_provider_transport.dart';

final class _NativeProjectionDelta {
  const _NativeProjectionDelta(this.text, this.reasoning);
  final String text;
  final String reasoning;
}

/// The accepted decoder is unchanged. It independently proves text/terminal
/// semantics, while this NEW private projection bounds the reasoning lane.
final class _NativeEventProjection {
  _NativeEventProjection(this.protocol)
    : decoder = PrivateTextEventDecoder(protocol);
  final String protocol;
  final PrivateTextEventDecoder decoder;
  final _thinkingBlocks = <int>{};
  final _responseReasoning = <String, StringBuffer>{};
  int _reasoningCharacters = 0;
  bool _chatFinished = false;

  _NativeProjectionDelta frame(_NativeFrame frame) {
    _nativeRequire(!decoder.terminal);
    if (frame.payload == '[DONE]') {
      _nativeRequire(decoder.acceptsDone);
      try {
        decoder.done();
      } on PrivateTextFailure catch (failure) {
        _nativeFail(_privateReason(failure.reason));
      }
      return const _NativeProjectionDelta('', '');
    }
    final object = _nativeJson(frame.payload);
    _nativeRequire(object is Map<String, dynamic>);
    final event = object as Map<String, dynamic>;
    _nativeRequire(
      frame.event == null ||
          frame.event == 'message' ||
          frame.event == event['type'],
    );
    return consume(event);
  }

  _NativeProjectionDelta consume(Map<String, dynamic> event) {
    _nativeRequire(!decoder.terminal);
    final List<Map<String, dynamic>> projected;
    try {
      projected = decoder.consume(event);
    } on PrivateTextFailure catch (failure) {
      _nativeFail(_privateReason(failure.reason));
    }
    final text = StringBuffer();
    for (final item in projected) {
      if (protocol == LlmProtocol.anthropic) {
        final delta = item['delta'];
        if (delta is Map && delta['text'] is String) text.write(delta['text']);
      } else if (protocol == LlmProtocol.gemini) {
        final candidates = item['candidates'];
        if (candidates is List) {
          for (final part in candidates.first['content']['parts'] as List) {
            text.write(part['text']);
          }
        }
      } else if (protocol == LlmProtocol.openaiResponses) {
        if (item['type'] == 'response.output_text.delta') {
          text.write(item['delta']);
        }
      } else {
        final choices = item['choices'];
        if (choices is List) text.write(choices.first['delta']['content']);
      }
    }
    final reasoning = _reasoning(event);
    _reasoningCharacters += reasoning.length;
    _nativeRequire(
      _reasoningCharacters <= NativeProviderTransportLimits.outputCharacters &&
          utf8.decode(utf8.encode(reasoning)) == reasoning,
      NativeProviderTransportReason.outputLimit,
    );
    return _NativeProjectionDelta(text.toString(), reasoning);
  }

  String _reasoning(Map<String, dynamic> event) {
    if (protocol == LlmProtocol.anthropic) {
      switch (event['type']) {
        case 'content_block_start':
          final block = event['content_block'] as Map;
          if (block['type'] != 'thinking') return '';
          _thinkingBlocks.add(event['index'] as int);
          _nativeRequire(block['thinking'] is String);
          return block['thinking'] as String;
        case 'content_block_delta':
          final delta = event['delta'] as Map;
          if (delta['type'] != 'thinking_delta') return '';
          _nativeRequire(
            _thinkingBlocks.contains(event['index']) &&
                delta['thinking'] is String,
          );
          return delta['thinking'] as String;
        case 'content_block_stop':
          _thinkingBlocks.remove(event['index']);
      }
      return '';
    }
    if (protocol == LlmProtocol.gemini) {
      final candidate = (event['candidates'] as List).single as Map;
      final content = candidate['content'];
      if (content == null) return '';
      return ((content as Map)['parts'] as List)
          .where((part) => part['thought'] == true)
          .map((part) => part['text'] as String)
          .join();
    }
    if (protocol == LlmProtocol.openaiResponses) {
      final type = event['type'];
      if (type == 'response.reasoning_summary_text.delta' ||
          type == 'response.reasoning_text.delta') {
        _nativeRequire(event['delta'] is String);
        final index = event['output_index'];
        final summary = event['summary_index'];
        _nativeRequire(
          (index == null || index is int && index >= 0 && index <= 512) &&
              (summary == null ||
                  summary is int && summary >= 0 && summary <= 512),
        );
        final key =
            '${type == 'response.reasoning_text.delta' ? 'text' : 'summary'}:$index:$summary';
        _nativeRequire(
          _responseReasoning.length < 1024 ||
              _responseReasoning.containsKey(key),
          NativeProviderTransportReason.wireLimit,
        );
        (_responseReasoning[key] ??= StringBuffer()).write(event['delta']);
        return event['delta'] as String;
      }
      if (type == 'response.reasoning_summary_text.done' ||
          type == 'response.reasoning_text.done') {
        final key =
            '${type == 'response.reasoning_text.done' ? 'text' : 'summary'}:${event['output_index']}:${event['summary_index']}';
        _nativeRequire(
          event['text'] is String &&
              event['text'] == (_responseReasoning[key]?.toString() ?? ''),
        );
      }
      return '';
    }
    final choices = event['choices'] as List;
    if (choices.isEmpty) return '';
    final choice = choices.single as Map;
    final delta = choice['delta'] as Map;
    final reasoning = delta['reasoning_content'] ?? delta['reasoning'] ?? '';
    _nativeRequire(
      reasoning is String && (!_chatFinished || reasoning.isEmpty),
    );
    if (choice['finish_reason'] != null) _chatFinished = true;
    return reasoning as String;
  }

  void finish() {
    // EOF only succeeds with a real provider terminal/finish proof; never invent
    // completion from an empty stream or partial/valid-but-nonterminal JSON.
    _nativeRequire(
      decoder.terminal || decoder.canFinishAtEof,
      NativeProviderTransportReason.unexpectedEof,
    );
    decoder.terminal = true;
  }
}

NativeProviderTransportReason _privateReason(
  PrivateTextReason reason,
) => switch (reason) {
  PrivateTextReason.providerError =>
    NativeProviderTransportReason.providerError,
  PrivateTextReason.unsupported => NativeProviderTransportReason.unsupported,
  PrivateTextReason.outputLimit => NativeProviderTransportReason.outputLimit,
  PrivateTextReason.wireLimit => NativeProviderTransportReason.wireLimit,
  _ => NativeProviderTransportReason.malformed,
};
