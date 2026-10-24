part of 'native_tool_transport.dart';

List<Map<String, Object?>> _decodeToolAnthropic(
  Map<String, Object?> root,
  _ToolCallSink call,
  _ToolTextSink text,
) {
  _ntRequire(root['type'] == 'message' && root['role'] == 'assistant');
  final stop = root['stop_reason'];
  if (stop == 'max_tokens') _ntFail(NativeToolReason.limit);
  _ntRequire(
    stop == 'tool_use' || stop == 'end_turn',
    NativeToolReason.providerError,
  );
  final content = _toolList(root['content']);
  var count = 0;
  for (final raw in content) {
    final block = _toolObject(raw);
    switch (block['type']) {
      case 'text':
        _toolKeys(block, {'type', 'text'});
        text(block['text']);
      case 'tool_use':
        _toolKeys(block, {'type', 'id', 'name', 'input'});
        call(block['id'], block['name'], block['input']);
        count++;
      case 'thinking':
        _toolKeys(block, {'type', 'thinking', 'signature'});
        _ntRequire(
          block['thinking'] is String &&
              block['signature'] is String &&
              (block['signature'] as String).isNotEmpty &&
              (block['signature'] as String).length <=
                  NativeToolLimits.jsonBytes,
        );
      case 'redacted_thinking':
        _toolKeys(block, {'type', 'data'});
        _ntRequire(
          block['data'] is String && (block['data'] as String).isNotEmpty,
        );
      default:
        _ntFail(NativeToolReason.unsupported);
    }
  }
  _ntRequire((stop == 'tool_use') == (count > 0));
  return [
    {'role': 'assistant', 'content': content},
  ];
}

List<Map<String, Object?>> _decodeToolGemini(
  Map<String, Object?> root,
  _ToolCallSink call,
  _ToolTextSink text,
  int round,
) {
  final candidates = _toolList(root['candidates']);
  _ntRequire(candidates.length == 1);
  final candidate = _toolObject(candidates.single);
  _ntRequire(candidate['index'] == null || candidate['index'] == 0);
  if (candidate['finishReason'] == 'MAX_TOKENS') {
    _ntFail(NativeToolReason.limit);
  }
  _ntRequire(
    candidate['finishReason'] == 'STOP',
    NativeToolReason.providerError,
  );
  final content = _toolObject(candidate['content']);
  _toolKeys(content, {'role', 'parts'});
  _ntRequire(content['role'] == 'model');
  var index = 0;
  for (final raw in _toolList(content['parts'])) {
    final part = _toolObject(raw);
    _toolKeys(part, {'text', 'thought', 'thoughtSignature', 'functionCall'});
    _ntRequire(part['thought'] == null || part['thought'] is bool);
    _ntRequire(
      part['thoughtSignature'] == null ||
          (part['thoughtSignature'] is String &&
              (part['thoughtSignature'] as String).isNotEmpty &&
              (part['thoughtSignature'] as String).length <=
                  NativeToolLimits.jsonBytes),
    );
    _ntRequire(part.containsKey('text') != part.containsKey('functionCall'));
    if (part.containsKey('functionCall')) {
      _ntRequire(part['thought'] != true);
      final function = _toolObject(part['functionCall']);
      _toolKeys(function, {'id', 'name', 'args'});
      final id = function.containsKey('id')
          ? function['id']
          : 'gemini_${round}_$index';
      call(id, function['name'], function['args']);
      index++;
    } else {
      _ntRequire(part['text'] is String);
      if (part['thought'] != true) text(part['text']);
    }
  }
  return [content];
}
