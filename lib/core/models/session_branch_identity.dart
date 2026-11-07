import 'dart:convert';

import 'chat_message.dart';

/// Stable identity and ancestry for one isolated chat history.
final class SessionBranchIdentity {
  const SessionBranchIdentity({
    required this.branchId,
    required this.rootSessionId,
    this.parentSessionId,
    this.forkMessageId,
    this.forkSwipeId,
    this.forkAgentSwipeId,
  });

  static const branchIdKey = '__memoryBranchId';
  static const rootSessionIdKey = '__memoryBranchRootSessionId';
  static const parentSessionIdKey = '__memoryBranchParentSessionId';
  static const forkStampKey = '__memoryBranchForkStamp';

  final String branchId;
  final String rootSessionId;
  final String? parentSessionId;
  final String? forkMessageId;
  final int? forkSwipeId;
  final int? forkAgentSwipeId;

  /// Legacy sessions resolve to themselves. Malformed explicit metadata fails
  /// closed instead of silently assigning potentially wrong ancestry.
  static SessionBranchIdentity? resolve({
    required String sessionId,
    required Map<String, String> sessionVars,
  }) {
    if (sessionId.isEmpty) return null;
    final branchId = sessionVars[branchIdKey];
    final rootId = sessionVars[rootSessionIdKey];
    final parentId = sessionVars[parentSessionIdKey];
    final stampJson = sessionVars[forkStampKey];
    if (branchId == null &&
        rootId == null &&
        parentId == null &&
        stampJson == null) {
      return SessionBranchIdentity(
        branchId: sessionId,
        rootSessionId: sessionId,
      );
    }
    if (branchId != sessionId || rootId == null || rootId.isEmpty) return null;
    if (parentId == null) {
      if (stampJson != null || rootId != sessionId) return null;
      return SessionBranchIdentity(branchId: sessionId, rootSessionId: rootId);
    }
    if (parentId.isEmpty || parentId == sessionId || stampJson == null) {
      return null;
    }
    try {
      final stamp = jsonDecode(stampJson);
      if (stamp is! Map<String, dynamic> ||
          stamp['messageId'] is! String ||
          (stamp['messageId'] as String).isEmpty ||
          stamp['swipeId'] is! int ||
          stamp['agentSwipeId'] is! int) {
        return null;
      }
      return SessionBranchIdentity(
        branchId: sessionId,
        rootSessionId: rootId,
        parentSessionId: parentId,
        forkMessageId: stamp['messageId'] as String,
        forkSwipeId: stamp['swipeId'] as int,
        forkAgentSwipeId: stamp['agentSwipeId'] as int,
      );
    } on Object {
      return null;
    }
  }

  static SessionBranchIdentity? fromSessionVarsJson({
    required String sessionId,
    required String? sessionVarsJson,
  }) {
    try {
      final decoded = sessionVarsJson == null || sessionVarsJson.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(sessionVarsJson);
      if (decoded is! Map) return null;
      final vars = <String, String>{};
      for (final item in decoded.entries) {
        if (item.key is! String || item.value is! String) return null;
        vars[item.key as String] = item.value as String;
      }
      return resolve(sessionId: sessionId, sessionVars: vars);
    } on Object {
      return null;
    }
  }

  static Map<String, String> childSessionVars({
    required Map<String, String> parentSessionVars,
    required String parentSessionId,
    required String branchSessionId,
    required ChatMessage forkMessage,
  }) {
    final parent = resolve(
      sessionId: parentSessionId,
      sessionVars: parentSessionVars,
    );
    if (parent == null) {
      throw StateError('Parent session has invalid branch identity.');
    }
    return {
      ...parentSessionVars,
      branchIdKey: branchSessionId,
      rootSessionIdKey: parent.rootSessionId,
      parentSessionIdKey: parentSessionId,
      forkStampKey: jsonEncode({
        'messageId': forkMessage.id,
        'swipeId': forkMessage.swipeId,
        'agentSwipeId': forkMessage.agentSwipeId,
      }),
    };
  }
}
