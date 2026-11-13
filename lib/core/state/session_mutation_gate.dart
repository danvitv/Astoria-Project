import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-scoped exclusion between foreground session work and a rewrite apply.
/// Claims are synchronous, before preparation awaits; no DB/network work runs
/// under a lock or waits for another claim. Independent sessions do not contend.
final class SessionMutationGate {
  final _foreground = <String, Set<Object>>{};
  final _applies = <String, Object>{};
  final _applyCharacters = <Object, String>{};
  final _applySettled = <Object, Completer<void>>{};
  final _selections = <String, Set<Object>>{};
  bool _disposed = false;

  SessionMutationLease? tryForeground(String sessionId) {
    if (_disposed || _applies.containsKey(sessionId)) return null;
    final identity = Object();
    (_foreground[sessionId] ??= {}).add(identity);
    return SessionMutationLease._(() {
      final active = _foreground[sessionId];
      active?.remove(identity);
      if (active?.isEmpty == true) _foreground.remove(sessionId);
    });
  }

  SessionMutationLease? tryApply(String sessionId, {String? characterId}) {
    if (_disposed ||
        _applies.containsKey(sessionId) ||
        (_selections[characterId]?.isNotEmpty ?? false) ||
        (_foreground[sessionId]?.isNotEmpty ?? false)) {
      return null;
    }
    final identity = Object();
    _applies[sessionId] = identity;
    if (characterId != null) _applyCharacters[identity] = characterId;
    final settled = Completer<void>();
    _applySettled[identity] = settled;
    return SessionMutationLease._(() {
      if (identical(_applies[sessionId], identity)) _applies.remove(sessionId);
      _applyCharacters.remove(identity);
      _applySettled.remove(identity);
      if (!settled.isCompleted) settled.complete();
    });
  }

  /// Selection resolves a target session asynchronously and changes the loaded
  /// character owner's binding. Fence that selection against Apply before the
  /// target is known; foreground commands still retain their exact session.
  SessionMutationLease? trySelection(String characterId) {
    if (_disposed || _applyCharacters.containsValue(characterId)) return null;
    final identity = Object();
    (_selections[characterId] ??= {}).add(identity);
    return SessionMutationLease._(() {
      final active = _selections[characterId];
      active?.remove(identity);
      if (active?.isEmpty == true) _selections.remove(characterId);
    });
  }

  /// A replacement provider may rebuild as Apply retires its old owner. Wait
  /// for command settlement, not a DB/network lock, before reading its binding.
  Future<SessionMutationLease?> waitSelection(String characterId) async {
    while (!_disposed) {
      final selection = trySelection(characterId);
      if (selection != null) return selection;
      final pending = [
        for (final entry in _applyCharacters.entries)
          if (entry.value == characterId) _applySettled[entry.key]!.future,
      ];
      await Future.wait(pending);
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    _foreground.clear();
    _applies.clear();
    _applyCharacters.clear();
    for (final settled in _applySettled.values) {
      if (!settled.isCompleted) settled.complete();
    }
    _applySettled.clear();
    _selections.clear();
  }
}

final class SessionMutationLease {
  SessionMutationLease._(this._release);
  void Function()? _release;

  void release() {
    final release = _release;
    _release = null;
    release?.call();
  }
}

final sessionMutationGateProvider = Provider<SessionMutationGate>((ref) {
  final gate = SessionMutationGate();
  ref.onDispose(gate.dispose);
  return gate;
});
