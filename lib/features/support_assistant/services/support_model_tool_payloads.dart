import 'dart:convert';

import '../../../core/llm/transport/native_tool_types.dart';

/// Run-local DCP only: exact duplicate metadata payloads become backward refs.
/// Correlation, status and effects are never pruned. Every read still executes
/// against fresh native state; no cached result can authorize an application effect.
final class SupportModelToolPayloads {
  final _copies = <(String, String, String), String>{};
  static const _reads = {
    'astoria_preferences_read',
    'astoria_themes_list',
    'astoria_connections_list',
    'astoria_connection_read',
  };

  static bool isRead(String action) => _reads.contains(action);

  NativeToolResult project(NativeToolCall call, NativeToolResult result) {
    if (!isRead(call.name) ||
        result.content['ok'] != true ||
        result.content['effect'] != 'none') {
      return result;
    }
    final identity = (
      call.name,
      argumentsKey(call.arguments),
      argumentsKey(result.content),
    );
    final previous = _copies[identity];
    if (previous == null) {
      _copies[identity] = call.id;
      return result;
    }
    return NativeToolResult(
      callId: result.callId,
      name: result.name,
      content: {
        ...result.content,
        'data': {'exactDuplicateOfCallId': previous},
      },
    );
  }

  static String argumentsKey(Map<String, Object?> value) {
    Object? ordered(Object? v) {
      if (v is Map<String, Object?>) {
        final keys = v.keys.toList()..sort();
        return {for (final key in keys) key: ordered(v[key])};
      }
      if (v is List) return v.map(ordered).toList();
      return v;
    }

    return jsonEncode(ordered(value));
  }
}
