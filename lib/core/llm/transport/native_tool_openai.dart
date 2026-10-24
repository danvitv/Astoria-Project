part of 'native_tool_transport.dart';

typedef _ToolCallSink = void Function(Object? id, Object? name, Object? args);
typedef _ToolTextSink = void Function(Object? text);

List<Map<String, Object?>> _decodeToolChat(
  Map<String, Object?> root,
  _ToolCallSink call,
  _ToolTextSink text,
) {
  final choices = _toolList(root['choices']);
  _ntRequire(choices.length == 1);
  final choice = _toolObject(choices.single);
  _ntRequire(choice['index'] == 0);
  final finish = choice['finish_reason'];
  if (finish == 'length') _ntFail(NativeToolReason.limit);
  _ntRequire(
    finish == 'stop' || finish == 'tool_calls',
    NativeToolReason.providerError,
  );
  final message = _toolObject(choice['message']);
  _toolKeys(message, {
    'role',
    'content',
    'tool_calls',
    'refusal',
    'reasoning_content',
    'reasoning',
  });
  _ntRequire(message['role'] == 'assistant' && message['refusal'] == null);
  final content = message['content'];
  _ntRequire(content == null || content is String);
  if (content != null) text(content);
  for (final key in ['reasoning_content', 'reasoning']) {
    _ntRequire(message[key] == null || message[key] is String);
  }
  final functions = message['tool_calls'] == null
      ? <Object?>[]
      : _toolList(message['tool_calls']);
  _ntRequire((finish == 'tool_calls') == functions.isNotEmpty);
  for (final raw in functions) {
    final tool = _toolObject(raw);
    _toolKeys(tool, {'id', 'type', 'function'});
    _ntRequire(tool['type'] == 'function', NativeToolReason.unsupported);
    final function = _toolObject(tool['function']);
    _toolKeys(function, {'name', 'arguments'});
    _ntRequire(function['arguments'] is String);
    final args = _toolDecodeJson(
      function['arguments'] as String,
      NativeToolLimits.jsonBytes,
    );
    call(tool['id'], function['name'], args);
  }
  return [message];
}

List<Map<String, Object?>> _decodeToolResponses(
  Map<String, Object?> root,
  _ToolCallSink call,
  _ToolTextSink text,
) {
  if (root['status'] == 'incomplete') _ntFail(NativeToolReason.limit);
  _ntRequire(
    root['status'] == 'completed' && root['error'] == null,
    NativeToolReason.providerError,
  );
  _ntRequire(
    root['id'] is String &&
        RegExp(
          r'^[a-zA-Z0-9_-][a-zA-Z0-9_.:-]{0,127}$',
        ).hasMatch(root['id'] as String),
  );
  final replay = <Map<String, Object?>>[];
  final ids = <String>{};
  for (final raw in _toolList(root['output'])) {
    final item = _toolObject(raw);
    final id = item['id'];
    _ntRequire(
      id is String &&
          RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.:-]{0,127}$').hasMatch(id) &&
          ids.add(id),
    );
    switch (item['type']) {
      case 'function_call':
        _toolKeys(item, {
          'type',
          'id',
          'call_id',
          'name',
          'arguments',
          'status',
        });
        _ntRequire(item['status'] == null || item['status'] == 'completed');
        _ntRequire(item['arguments'] is String);
        final args = _toolDecodeJson(
          item['arguments'] as String,
          NativeToolLimits.jsonBytes,
        );
        call(item['call_id'], item['name'], args);
      case 'message':
        _toolKeys(item, {'type', 'id', 'role', 'content', 'status'});
        _ntRequire(
          item['role'] == 'assistant' &&
              (item['status'] == null || item['status'] == 'completed'),
        );
        for (final rawPart in _toolList(item['content'])) {
          final part = _toolObject(rawPart);
          _toolKeys(part, {'type', 'text', 'annotations', 'logprobs'});
          _ntRequire(
            part['type'] == 'output_text',
            NativeToolReason.unsupported,
          );
          // Annotations/logprobs are not tool authority or necessary replay.
          _ntRequire(
            part['annotations'] == null || part['annotations'] is List,
          );
          _ntRequire(part['logprobs'] == null || part['logprobs'] is List);
          text(part['text']);
        }
      case 'reasoning':
        _toolKeys(item, {
          'type',
          'id',
          'summary',
          'encrypted_content',
          'status',
        });
        _ntRequire(
          item['encrypted_content'] == null ||
              item['encrypted_content'] is String,
        );
        for (final rawPart in _toolList(item['summary'])) {
          final part = _toolObject(rawPart);
          _toolKeys(part, {'type', 'text'});
          _ntRequire(part['type'] == 'summary_text' && part['text'] is String);
        }
      default:
        // Built-in tools, computer/browser/function-like prose and unknown items
        // are NEVER interpreted as application calls.
        _ntFail(NativeToolReason.unsupported);
    }
    replay.add(item);
  }
  _ntRequire(replay.isNotEmpty);
  return replay;
}
