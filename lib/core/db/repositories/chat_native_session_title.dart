part of 'chat_repo.dart';

/// Exact storage states, not the nullable display projection in ChatSession.
enum ChatNativeTitleKind { absent, nullValue, text }

final class ChatNativeTitleObservation {
  ChatNativeTitleObservation._(
    this._repo,
    this.sessionId,
    this.characterId,
    this.sessionIndex,
    this.kind,
    this.text,
  );
  final ChatRepo _repo;
  final String sessionId, characterId;
  final int sessionIndex;
  final ChatNativeTitleKind kind;
  final String? text;
  bool _used = false;
}

/// Actual original committed receipt. No public/JSON reconstruction path.
final class ChatNativeTitleReceipt {
  const ChatNativeTitleReceipt._(this._before, this._after, this._journal);
  final ChatNativeTitleObservation _before, _after;
  final SupportMutationReservation _journal;
  String get sessionId => _before.sessionId;
  ChatNativeTitleKind get beforeKind => _before.kind;
  String? get beforeText => _before.text;
  String get afterText => _after.text!;
}

final class ChatNativeTitleStorageException implements Exception {
  const ChatNativeTitleStorageException();
}

final class _NativeTitleRefused implements Exception {
  const _NativeTitleRefused();
}

void _titleRequire(bool value) {
  if (!value) throw const _NativeTitleRefused();
}

// A JSON-null title has no display name, but must remain null in storage. Never
// coerce unrelated variable types or persist this display-only projection.
Map<String, String> _modelSessionVars(String? raw) {
  if (raw == null) return {};
  final vars = Map<String, dynamic>.from(jsonDecode(raw) as Map);
  if (vars.containsKey('sessionName') && vars['sessionName'] == null) {
    vars.remove('sessionName');
  }
  return Map<String, String>.from(vars);
}

extension ChatNativeSessionTitleStore on ChatRepo {
  static const titleJournalDomain = 'session.title';

  Future<ChatNativeTitleObservation?> observeNativeTitle(
    String sessionId,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return null;
    try {
      // SQLite projects ONLY identity and title. Malformed/oversized variables
      // never become an invented absent title or transfer their private payload.
      final row = await _db
          .customSelect(
            r'''SELECT character_id, session_index,
          json_type(coalesce(session_vars_json, '{}'), '$.sessionName') AS kind,
          json_extract(coalesce(session_vars_json, '{}'), '$.sessionName') AS title
        FROM chat_sessions WHERE session_id = ?
          AND typeof(character_id) = 'text'
          AND typeof(session_index) = 'integer' AND session_index >= 0
          AND length(CAST(coalesce(session_vars_json, '{}') AS BLOB)) <= 65536
          AND CASE WHEN json_valid(coalesce(session_vars_json, '{}'))
            THEN json_type(coalesce(session_vars_json, '{}')) = 'object'
            ELSE 0 END
          AND (SELECT count(*) FROM json_each(coalesce(session_vars_json, '{}'))
            WHERE key = 'sessionName') <= 1''',
            variables: [Variable.withString(sessionId)],
            readsFrom: {_db.chatSessions},
          )
          .getSingleOrNull();
      if (!isCurrent() || row == null) return null;
      final kind = row.readNullable<String>('kind');
      if (kind != null && kind != 'null' && kind != 'text') return null;
      final text = kind == 'text' ? row.read<String>('title') : null;
      if (text != null && text.length > 256) return null;
      return ChatNativeTitleObservation._(
        this,
        sessionId,
        row.read<String>('character_id'),
        row.read<int>('session_index'),
        kind == null
            ? ChatNativeTitleKind.absent
            : kind == 'null'
            ? ChatNativeTitleKind.nullValue
            : ChatNativeTitleKind.text,
        text,
      );
    } catch (_) {
      return null;
    }
  }

  bool _sameNativeTitle(
    ChatNativeTitleObservation a,
    ChatNativeTitleObservation? b,
  ) =>
      b != null &&
      identical(a._repo, this) &&
      identical(b._repo, this) &&
      a.sessionId == b.sessionId &&
      a.characterId == b.characterId &&
      a.sessionIndex == b.sessionIndex &&
      a.kind == b.kind &&
      a.text == b.text;

  String _titleEvidence(ChatNativeTitleObservation value) =>
      SupportMutationEvidence.encode(
        jsonEncode({
          'v': 1,
          'session': value.sessionId,
          'character': value.characterId,
          'index': value.sessionIndex,
          'kind': value.kind.name,
          'title': value.text,
        }),
      );

  Future<T?> _nativeTitleTransaction<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    try {
      _titleRequire(current());
      return await outsideDatabaseTransaction(
        _db,
        () => _db.transaction(() async {
          _titleRequire(current());
          final result = await work();
          _titleRequire(current());
          return result;
        }),
        onRejected: () => const _NativeTitleRefused(),
      );
    } on _NativeTitleRefused {
      return null;
    } catch (_) {
      throw const ChatNativeTitleStorageException();
    }
  }

  Future<void> _writeNativeTitle(
    ChatNativeTitleObservation expected,
    ChatNativeTitleObservation next,
    bool Function() current,
  ) async {
    _titleRequire(current());
    final kind = expected.kind == ChatNativeTitleKind.absent
        ? null
        : expected.kind == ChatNativeTitleKind.nullValue
        ? 'null'
        : 'text';
    final patch = next.kind == ChatNativeTitleKind.absent
        ? r"json_remove(coalesce(session_vars_json, '{}'), '$.sessionName')"
        : r"json_set(coalesce(session_vars_json, '{}'), '$.sessionName', ?)";
    final changed = await _db.customUpdate(
      '''UPDATE chat_sessions SET session_vars_json = $patch
        WHERE session_id = ? AND character_id = ? AND session_index = ?
          AND json_type(coalesce(session_vars_json, '{}'), '\$.sessionName') IS ?
          AND json_extract(coalesce(session_vars_json, '{}'), '\$.sessionName') IS ?''',
      variables: [
        if (next.kind != ChatNativeTitleKind.absent)
          Variable<String>(next.text),
        Variable.withString(expected.sessionId),
        Variable.withString(expected.characterId),
        Variable.withInt(expected.sessionIndex),
        Variable<String>(kind),
        Variable<String>(expected.text),
      ],
      updates: {_db.chatSessions},
    );
    _titleRequire(current() && changed == 1);
    _titleRequire(
      _sameNativeTitle(next, await observeNativeTitle(next.sessionId, current)),
    );
    _titleRequire(current());
  }

  /// Called on the ORIGINAL loaded owner's queue after finite ROOT admission.
  /// Journal and narrow title CAS commit together; stale inner completions roll
  /// both back. A durable receipt is never erased by a post-commit Stop.
  Future<ChatNativeTitleReceipt?> renameNativeTitle({
    required ChatNativeTitleObservation before,
    required String title,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required int createdAt,
    required bool Function() isCurrent,
  }) async {
    if (!identical(before._repo, this) ||
        before._used ||
        !isCurrent() ||
        !support.usesDatabase(_db) ||
        title.isEmpty ||
        title.length > 256)
      return null;
    before._used = true;
    final after = ChatNativeTitleObservation._(
      this,
      before.sessionId,
      before.characterId,
      before.sessionIndex,
      ChatNativeTitleKind.text,
      title,
    );
    return _nativeTitleTransaction(isCurrent, () async {
      _titleRequire(
        _sameNativeTitle(
          before,
          await observeNativeTitle(before.sessionId, isCurrent),
        ),
      );
      _titleRequire(isCurrent());
      final pending = await support.reserveMutation(
        record: SupportMutationRecord(
          id: operationId,
          sessionId: parentSession,
          domain: titleJournalDomain,
          targetId: before.sessionId,
          beforeJson: _titleEvidence(before),
          afterJson: _titleEvidence(after),
          status: 'pending',
          createdAt: createdAt,
        ),
        isCurrent: isCurrent,
      );
      _titleRequire(isCurrent() && pending != null);
      _titleRequire(
        _sameNativeTitle(
          before,
          await observeNativeTitle(before.sessionId, isCurrent),
        ),
      );
      _titleRequire(isCurrent());
      await _writeNativeTitle(before, after, isCurrent);
      _titleRequire(isCurrent());
      final journal = await support.settleMutation(
        expected: pending!,
        fact: SupportMutationFact.applied,
        hasOriginalDbCustody: isCurrent,
      );
      _titleRequire(isCurrent() && journal != null);
      _titleRequire(
        _sameNativeTitle(
          after,
          await observeNativeTitle(before.sessionId, isCurrent),
        ),
      );
      return ChatNativeTitleReceipt._(before, after, journal!);
    });
  }

  Future<bool?> undoNativeTitle({
    required ChatNativeTitleReceipt receipt,
    required ChatNativeTitleObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._repo, this) ||
        observed._used ||
        !_sameNativeTitle(receipt._after, observed) ||
        !isCurrent() ||
        !support.usesDatabase(_db) ||
        receipt._journal.record.sessionId != parentSession)
      return null;
    observed._used = true;
    return _nativeTitleTransaction(isCurrent, () async {
      _titleRequire(
        _sameNativeTitle(
          observed,
          await observeNativeTitle(observed.sessionId, isCurrent),
        ),
      );
      _titleRequire(isCurrent());
      final pending = await support.reserveMutationUndo(
        expected: receipt._journal,
        isCurrent: isCurrent,
      );
      _titleRequire(isCurrent() && pending != null);
      _titleRequire(
        pending!.record.beforeJson == _titleEvidence(receipt._before) &&
            pending.record.afterJson == _titleEvidence(receipt._after),
      );
      _titleRequire(
        _sameNativeTitle(
          observed,
          await observeNativeTitle(observed.sessionId, isCurrent),
        ),
      );
      _titleRequire(isCurrent());
      await _writeNativeTitle(observed, receipt._before, isCurrent);
      _titleRequire(isCurrent());
      final journal = await support.settleMutation(
        expected: pending,
        fact: SupportMutationFact.undone,
        hasOriginalDbCustody: isCurrent,
      );
      _titleRequire(isCurrent() && journal != null);
      _titleRequire(
        _sameNativeTitle(
          receipt._before,
          await observeNativeTitle(observed.sessionId, isCurrent),
        ),
      );
      return true;
    });
  }
}
