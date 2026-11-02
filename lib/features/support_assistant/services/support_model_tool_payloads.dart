import 'dart:convert';

import '../../../core/llm/transport/native_tool_types.dart';
import '../models/support_source_tool_names.dart';

/// Run-local DCP only: exact duplicate metadata payloads become backward refs.
/// Correlation, status and effects are never pruned. Every read still executes
/// against fresh native state; no cached result can authorize an application effect.
final class SupportModelToolPayloads {
  final _copies = <(String, String, String), String>{};
  static const _reads = {
    ...SupportSourceToolNames.all,
    'astoria_preferences_read',
    'astoria_themes_list',
    'astoria_connections_list',
    'astoria_connection_read',
    'astoria_content_catalog',
    'astoria_content_handles',
    'astoria_roleplay_inspect',
    'astoria_memory_inspect',
    'astoria_canon_validate',
    'astoria_session_diagnostics',
    'astoria_extension_controls_read',
    'astoria_diagnostics_read',
    'astoria_secondary_profiles_read',
    'astoria_database_health',
    'astoria_session_integrity',
    'astoria_session_title_receipts',
    'astoria_active_selection_receipts',
    'astoria_global_regex_receipts',
    'astoria_memory_entry_text_receipts',
  };

  static bool isRead(String action) => _reads.contains(action);

  NativeToolResult project(NativeToolCall call, NativeToolResult result) {
    if (SupportSourceToolNames.body.contains(call.name) ||
        !isRead(call.name) ||
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
