part of 'native_tool_types.dart';

Never _toolFail(NativeToolReason reason) => throw NativeToolException(reason);

void _toolRequire(
  bool condition, [
  NativeToolReason reason = NativeToolReason.invalidRequest,
]) {
  if (!condition) _toolFail(reason);
}

String _toolText(String value, {required int max}) {
  _toolRequire(value.length <= max && utf8.decode(utf8.encode(value)) == value);
  _toolRequire(
    _toolJsonRedactor.redactJson(value) == value,
    NativeToolReason.denied,
  );
  return value;
}

String _toolIdentifier(String value, {bool nameOnly = false}) {
  _toolRequire(
    RegExp(
      nameOnly
          ? r'^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$'
          : r'^[a-zA-Z0-9_-][a-zA-Z0-9_.:-]{0,127}$',
    ).hasMatch(value),
  );
  return _toolText(value, max: nameOnly ? 64 : 128);
}

/// Primitives only, no arbitrary toJson, executable callback or mutable alias.
Map<String, Object?> _toolJsonObject(Map<String, Object?> input) {
  final active = Set<Object>.identity();
  var nodes = 0;
  var characters = 0;
  Object? freeze(Object? value, int depth) {
    _toolRequire(
      ++nodes <= NativeToolLimits.jsonNodes &&
          depth <= NativeToolLimits.jsonDepth,
      NativeToolReason.limit,
    );
    if (value == null || value is bool) return value;
    if (value is num) {
      _toolRequire(value.isFinite && value.abs() <= 9007199254740991);
      return value;
    }
    if (value is String) {
      characters += value.length;
      _toolRequire(
        characters <= NativeToolLimits.jsonBytes,
        NativeToolReason.limit,
      );
      return _toolText(value, max: NativeToolLimits.jsonBytes);
    }
    _toolRequire((value is Map || value is List) && active.add(value));
    Object frozen;
    if (value is Map) {
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        _toolRequire(entry.key is String);
        _toolRequire(
          !_toolForbiddenField(entry.key as String),
          NativeToolReason.denied,
        );
        final key = freeze(entry.key, depth + 1) as String;
        map[key] = freeze(entry.value, depth + 1);
      }
      frozen = Map<String, Object?>.unmodifiable(map);
    } else {
      frozen = List<Object?>.unmodifiable(
        (value as List).map((child) => freeze(child, depth + 1)),
      );
    }
    active.remove(value);
    return frozen;
  }

  final frozen = freeze(input, 0) as Map<String, Object?>;
  _toolRequire(
    utf8.encode(jsonEncode(frozen)).length <= NativeToolLimits.jsonBytes,
    NativeToolReason.limit,
  );
  return frozen;
}

final _toolJsonRedactor = SecretRedactor(
  maxInputLength: NativeToolLimits.jsonBytes,
  maxOutputLength: NativeToolLimits.jsonBytes,
);
bool _toolForbiddenField(String key) => const {
  'apikey',
  'embeddingapikey',
  'authorization',
  'proxyauthorization',
  'password',
  'passwd',
  'secret',
  'credential',
  'credentials',
  'cookie',
  'accesstoken',
  'refreshtoken',
  'privatekey',
  'accesskey',
  'signingkey',
}.contains(key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''));

List<NativeToolCall> _toolCallList(List<NativeToolCall> calls) {
  _toolRequire(
    calls.length <= NativeToolLimits.callsPerTurn,
    NativeToolReason.limit,
  );
  return List<NativeToolCall>.unmodifiable(calls);
}
