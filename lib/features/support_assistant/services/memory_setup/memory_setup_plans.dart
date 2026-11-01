part of 'memory_setup_service.dart';

enum MemorySetupScope { session, automation, draftConnection }

enum MemorySetupAutomation { manual, emptyDrafts, llmDrafts }

enum MemorySetupProfile { economy, balanced, detail }

/// Exact painted native target; the mutable owner's next session is NOT a choice.
final class MemorySetupTarget {
  MemorySetupTarget._(this._service, this._owner, this.sessionId,
    this._revision, this._checkpoint);
  final MemorySetupService _service;
  final ChatNativeOwner _owner;
  final String sessionId;
  final int _revision;
  final Object _checkpoint;
  bool _navigationRetired = false;
  String get characterId => _owner.characterId;

  /// Once opened, ordinary Scan/Generate need not keep the wizard's read lease
  /// or idle state. Only the originally selected chat owner may feed the sheet.
  bool get isActiveOwner {
    final owners = _service.owners;
    if (!_navigationRetired &&
        (!owners.isCurrent ||
            owners.revision != _revision ||
            !owners.loaded.any((owner) => identical(owner, _owner)) ||
            _owner.sessionId() != sessionId)) {
      _navigationRetired = true;
    }
    return !_navigationRetired;
  }
}

/// Five finite answers; saved connection choices are native-issued objects.
final class MemorySetupAnswers {
  const MemorySetupAnswers({
    this.automation = MemorySetupAutomation.manual,
    this.profile = MemorySetupProfile.balanced,
    this.tokens = 2048,
    this.semantic = false,
    this.connection,
  });
  final MemorySetupAutomation automation;
  final MemorySetupProfile profile;
  final int tokens;
  final bool semantic;
  final MemorySetupConnection? connection;
  MemorySetupAnswers copyWith({
    MemorySetupAutomation? automation,
    MemorySetupProfile? profile,
    int? tokens,
    bool? semantic,
    MemorySetupConnection? connection,
  }) => MemorySetupAnswers(
    automation: automation ?? this.automation,
    profile: profile ?? this.profile,
    tokens: tokens ?? this.tokens,
    semantic: semantic ?? this.semantic,
    connection: connection ?? this.connection,
  );
}

final class MemorySetupConnection {
  MemorySetupConnection._(this._service, this._id, this.label);
  final MemorySetupService _service;
  final String _id;
  final String label;
}

/// Safe passive before/after. This object has no public restoration constructor.
final class MemorySetupReview {
  MemorySetupReview._(
    this._service,
    this._intent,
    this.scope,
    Map<String, Object?> before,
    Map<String, Object?> after,
    this._checkpoint, {
    this.observed,
    Map<String, Object?> fields = const {},
    _MemorySetupGlobal? global,
    MemorySetupReceipt? undo,
    MemoryBookSetupTicket? bookTicket,
  }) : before = Map.unmodifiable(_freeze(before)),
       after = Map.unmodifiable(_freeze(after)),
       _fields = Map.unmodifiable(fields),
       _global = global,
       _undo = undo,
       _bookTicket = bookTicket;
  // The original native DB ticket is not included in before/after metadata.
  final MemoryBookSetupTicket? _bookTicket;
  final MemorySetupService _service;
  final int _intent;
  final MemorySetupScope scope;
  final Map<String, Object?> before, after;
  final Object? _checkpoint;
  final MemoryBookControlObservation? observed;
  final Map<String, Object?> _fields;
  final _MemorySetupGlobal? _global;
  final MemorySetupReceipt? _undo;
  bool _used = false;
  bool get current => !_used && _service.current && _intent == _service._intent &&
      (scope != MemorySetupScope.session || _bookTicket?.current == true);
  bool get isUndo => _undo != null;
  static Map<String, Object?> _freeze(Map<String, Object?> v) =>
      Map.unmodifiable(v.map((k, value) => MapEntry(k, _freezeValue(value))));
  static Object? _freezeValue(Object? v) => v is Map
      ? Map<Object?, Object?>.unmodifiable(
          v.map((k, value) => MapEntry(k, _freezeValue(value))),
        )
      : v is List
      ? List<Object?>.unmodifiable(v.map(_freezeValue))
      : v;
}

enum MemorySetupEffect {
  refused,
  conflict,
  applied,
  undone,
  reconciliationRequired,
}

final class MemorySetupResult {
  const MemorySetupResult(
    this.effect, {
    this.receipt,
    this.refreshPending = false,
  });
  final MemorySetupEffect effect;
  final MemorySetupReceipt? receipt;
  final bool refreshPending;
  static const refused = MemorySetupResult(MemorySetupEffect.refused);
}

final class MemorySetupReceipt {
  MemorySetupReceipt._(
    this._service,
    this.scope,
    this.before,
    this.after,
    this._checkpoint, {
    MemoryBookSetupCommit? session,
    _MemorySetupGlobal? global,
    SupportMutationReservation? journal,
  }) : _session = session,
       _global = global,
       _journal = journal;
  final MemorySetupService _service;
  final MemorySetupScope scope;
  final Map<String, Object?> before, after;
  final Object? _checkpoint;
  final MemoryBookSetupCommit? _session;
  final _MemorySetupGlobal? _global;
  final SupportMutationReservation? _journal;
  bool _used = false;
}

/// Private raw saved document and exact original store ticket, never journalled.
final class _MemorySetupGlobal {
  _MemorySetupGlobal(
    this.key,
    this.raw,
    this.lease,
    this.before,
    this.after,
    this.nextRaw,
  );
  final String key;
  final String? raw;
  final SavedPreferencesLease lease;
  final Map<String, Object?> before, after;
  final String nextRaw;
}
