import 'dart:convert';

import 'chat_message.dart';

/// Exact value comparison for a persisted chat captured by a restore guard.
/// Generated equality still compares AgentSwipe/TriggeredEntry by identity.
/// Encoding recursively invokes their toJson methods without dropping fields,
/// unlike comparing toJson maps that still contain these nested objects.
bool chatSessionContentEquals(ChatSession? current, ChatSession? expected) {
  if (current == null || expected == null) {
    return current == null && expected == null;
  }
  return jsonEncode(current.toJson()) == jsonEncode(expected.toJson());
}
