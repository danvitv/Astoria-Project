part of '../support_repo.dart';

/// Fixed schema-safe lifecycle, independent of any feature or external store.
enum SupportMutationStatus {
  pending('pending'),
  applied('applied'),
  failed('failed'),
  reconciliationRequired('reconciliation_required'),
  undoPending('undo_pending'),
  undone('undone'),
  undoConflict('undo_conflict');

  const SupportMutationStatus(this.value);
  final String value;
  bool get unresolved =>
      this == pending || this == undoPending || this == reconciliationRequired;

  static SupportMutationStatus? parse(String value) {
    for (final status in values) {
      if (status.value == value) return status;
    }
    return null;
  }
}

/// Facts, not arbitrary status edits. The trusted caller must classify actual
/// observation; this core boundary cannot establish causality in another store.
/// Applied/undone require the admitted effect owner's verified persistence;
/// failed means observed no effect, not merely a thrown external write. Ambiguous
/// write-then-throw/readback is reconciliationRequired. A recreated owner seeing
/// matching settings cannot infer historical causality from that match alone.
enum SupportMutationFact {
  applied,
  failed,
  reconciliationRequired,
  undone,
  undoConflict,
}

/// Core envelope around bounded, already sanitized native evidence strings.
/// The inner string has its own feature-owned codec; this wrapper neither
/// understands the domain nor mints provenance, model consent or native approval.
abstract final class SupportMutationEvidence {
  static const version = 1;
  static const maxNativeBytes = 8192;
  static const maxEncodedChars = maxNativeBytes * 6 + 64;

  static String encode(String sanitizedNativeEvidence) {
    if (!_native(sanitizedNativeEvidence)) {
      throw const FormatException('Invalid native mutation evidence.');
    }
    return jsonEncode({'v': version, 'native': sanitizedNativeEvidence});
  }

  /// Null means invalid/unsupported, never an empty/default restoration.
  static String? decode(String encoded) {
    if (encoded.length > maxEncodedChars) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value.length != 2 ||
          value['v'] is! int ||
          value['v'] != version ||
          value['native'] is! String) {
        return null;
      }
      final native = value['native'] as String;
      if (!_native(native) || encode(native) != encoded) return null;
      // Canonical comparison also rejects duplicate keys and extra whitespace.
      return native;
    } on FormatException {
      return null;
    }
  }

  static bool _native(String value) =>
      value.trim().isNotEmpty &&
      value.length <= maxNativeBytes &&
      utf8.encode(value).length <= maxNativeBytes;
}

/// Exact committed encrypted expectation. Private construction prevents a model
/// or restored DTO from fabricating ciphertext custody. There is deliberately no
/// copyWith/JSON constructor, executable plan, native approval or auto-replay.
final class SupportMutationReservation {
  const SupportMutationReservation._(
    this.record,
    this._row,
    this._parent,
    this._db,
  );
  final SupportMutationRecord record;
  final SupportMutationJournalRow _row;
  final SupportSessionRow _parent;
  final AppDatabase _db;
  SupportMutationStatus get status =>
      SupportMutationStatus.parse(record.status)!;
}

/// Safe storage failure only, never SQL, evidence or an underlying exception.
final class SupportMutationJournalException implements Exception {
  const SupportMutationJournalException();
  @override
  String toString() => 'SupportMutationJournalException(storageFailed)';
}

final class _SupportMutationRefused implements Exception {
  const _SupportMutationRefused();
}

/// Shared strict metadata/read checkpoints for action journal and its protected
/// deletion. SQLite dynamic types are validated BEFORE Drift maps integers.
final class _SupportMutationChecks {
  _SupportMutationChecks(this.db, this.cipher, this.sessions);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportSessionStore sessions;
  static const maxTime = 9007199254740991;
  static final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
  bool identifier(String value) =>
      value == value.trim() &&
      _id.hasMatch(value) &&
      value.length <= cipher.maxIdentifierBytes;
  bool time(int value) => value >= 0 && value <= maxTime;
  void require(bool value) {
    if (!value) throw const _SupportMutationRefused();
  }

  Future<T> checked<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    require(current());
    final result = await work();
    require(current());
    return result;
  }

  bool record(SupportMutationRecord record) =>
      !record.isLocked &&
      identifier(record.id) &&
      identifier(record.sessionId) &&
      identifier(record.domain) &&
      identifier(record.targetId) &&
      time(record.createdAt) &&
      SupportMutationStatus.parse(record.status) != null &&
      SupportMutationEvidence.decode(record.beforeJson) != null &&
      SupportMutationEvidence.decode(record.afterJson) != null;

  Future<SupportSessionRow> parent(String id, bool Function() current) async {
    final invalid = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 FROM support_sessions WHERE id = ? AND ('
            "typeof(created_at) != 'integer' OR created_at < 0 OR created_at > $maxTime "
            "OR typeof(updated_at) != 'integer' OR updated_at < 0 OR updated_at > $maxTime "
            "OR typeof(title_ciphertext) != 'text' OR typeof(mode) != 'text' "
            "OR typeof(pinned) != 'integer' OR pinned NOT IN (0, 1) "
            "OR (active_api_config_id IS NOT NULL AND typeof(active_api_config_id) != 'text') "
            "OR (active_model_id IS NOT NULL AND typeof(active_model_id) != 'text')) LIMIT 1",
            variables: [Variable<String>(id)],
            readsFrom: {db.supportSessions},
          )
          .get(),
    );
    require(invalid.isEmpty);
    final row = await checked(current, () => sessions.row(id));
    require(row != null);
    await checked(
      current,
      () => cipher.decrypt(
        envelopeText: row!.titleCiphertext,
        table: 'support_sessions',
        rowId: id,
        sessionId: id,
        field: 'title_ciphertext',
      ),
    );
    return row!;
  }

  Future<bool> absent(String id, bool Function() current) async =>
      (await checked(
        current,
        () => db
            .customSelect(
              'SELECT 1 FROM support_mutation_journal WHERE id = ? LIMIT 1',
              variables: [Variable<String>(id)],
              readsFrom: {db.supportMutationJournal},
            )
            .get(),
      )).isEmpty;

  Future<void> metadata(String id, bool Function() current) async {
    final invalid = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 FROM support_mutation_journal WHERE id = ? AND ('
            "typeof(created_at) != 'integer' OR created_at < 0 OR created_at > $maxTime "
            "OR typeof(session_id) != 'text' OR typeof(domain) != 'text' "
            "OR typeof(target_id) != 'text' OR typeof(status) != 'text' "
            "OR typeof(before_ciphertext) != 'text' OR typeof(after_ciphertext) != 'text') LIMIT 1",
            variables: [Variable<String>(id)],
            readsFrom: {db.supportMutationJournal},
          )
          .get(),
    );
    require(invalid.isEmpty);
  }

  Future<SupportMutationRecord> readable(
    SupportMutationJournalRow row,
    bool Function() current,
  ) async {
    require(
      identifier(row.id) &&
          identifier(row.sessionId) &&
          identifier(row.domain) &&
          identifier(row.targetId) &&
          time(row.createdAt) &&
          SupportMutationStatus.parse(row.status) != null,
    );
    Future<String> decrypt(String text, String field) => checked(
      current,
      () => cipher.decrypt(
        envelopeText: text,
        table: 'support_mutation_journal',
        rowId: row.id,
        sessionId: row.sessionId,
        field: field,
      ),
    );
    final before = await decrypt(row.beforeCiphertext, 'before_ciphertext');
    require(current());
    final after = await decrypt(row.afterCiphertext, 'after_ciphertext');
    require(current());
    final result = SupportMutationRecord(
      id: row.id,
      sessionId: row.sessionId,
      domain: row.domain,
      targetId: row.targetId,
      beforeJson: before,
      afterJson: after,
      status: row.status,
      createdAt: row.createdAt,
    );
    require(record(result));
    return result;
  }

  /// Normal metadata updates may proceed between operations. A replacement or
  /// re-encrypted title is not the original parent. Within each transaction the
  /// ENTIRE captured parent row must remain unchanged, including metadata.
  bool originalParent(SupportSessionRow a, SupportSessionRow b) =>
      a.id == b.id &&
      a.createdAt == b.createdAt &&
      a.titleCiphertext == b.titleCiphertext;
}
