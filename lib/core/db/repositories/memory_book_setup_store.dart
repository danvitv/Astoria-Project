part of 'memory_book_repo.dart';

/// Opaque native settings receipt. Contains no whole-book restoration command.
final class MemoryBookSetupCommit {
  MemoryBookSetupCommit._(
    this.journal,
    this.observation,
    this.before,
    this.after,
    this.created,
  );
  final SupportMutationReservation journal;
  final MemoryBookControlObservation observation;
  final Map<String, Object?> before, after;
  final bool created;
  MemoryBookSetupTicket? _ticket;
  MemoryBookSetupTicket? get ticket => _ticket;
}

extension MemoryBookSetupStore on MemoryBookRepo {
  static const setupFields = {
    'enabled',
    'memoryMode',
    'maxInjectedEntries',
    'maxInjectedTokens',
    'memoryPackingMode',
    'memoryExcerptingEnabled',
    'keyMatchMode',
    'vectorSearchEnabled',
  };

  Future<bool> existsForSetup(String sessionId) async =>
      await (select(
        memoryBookRows,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull() !=
      null;

  /// Presence-aware changed-field evidence only; raw unknown fields stay private.
  Map<String, Object?> setupFieldSnapshot(
    MemoryBookControlObservation? observation,
    Iterable<String> keys,
  ) {
    if (keys.any((k) => !setupFields.contains(k))) {
      throw const FormatException('Invalid setup fields');
    }
    final raw = observation == null
        ? <String, dynamic>{}
        : jsonDecode(observation._row.settingsJson) as Map<String, dynamic>;
    return Map.unmodifiable({
      for (final k in keys)
        k: Map<String, Object?>.unmodifiable({
          'present': raw.containsKey(k),
          if (raw.containsKey(k)) 'value': raw[k],
        }),
    });
  }

  /// Settings and encrypted journal share this actual database transaction.
  /// Exact absence is admitted only while the real target chat still exists.
  Future<MemoryBookSetupCommit?> applySetup({
    required String sessionId,
    required MemoryBookControlObservation? expected,
    required Map<String, Object?> fields,
    required SupportRepo journal,
    required SupportMutationRecord record,
    required bool Function() isCurrent,
    required MemoryBookSetupTicket ticket,
  }) async {
    final admission = _beginSetupBookWrite(ticket);
    if (admission == null) return null;
    bool owned() => isCurrent() && admission.current;
    MemoryBookSetupCommit? committed;
    try {
      committed = await transaction(() async {
        void check(bool value) {
          if (!value || !owned()) throw const _MemoryBookControlRetired();
        }

        check(
          journal.usesDatabase(attachedDatabase) &&
              fields.isNotEmpty &&
              fields.keys.every(setupFields.contains),
        );
        final session = await ChatRepo(attachedDatabase).getById(sessionId);
        check(
          session != null &&
              (expected == null || expected.book.sessionId == sessionId),
        );
        final row = await (select(
          memoryBookRows,
        )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
        check(expected == null ? row == null : row == expected._row);
        final before = setupFieldSnapshot(expected, fields.keys);
        final raw = row == null
            ? const MemoryBookSettings(
                autoCreateEnabled: false,
                autoGenerateEnabled: false,
                vectorSearchEnabled: false,
                consolidationEnabled: false,
              ).toJson()
            : Map<String, dynamic>.from(jsonDecode(row.settingsJson) as Map);
        raw.addAll(fields);
        MemoryBookSettings.fromJson(raw);
        final reserved = await journal.reserveMutation(
          record: record,
          isCurrent: owned,
        );
        check(reserved != null);
        if (row == null) {
          await into(memoryBookRows).insert(
            MemoryBookRowsCompanion.insert(
              sessionId: sessionId,
              settingsJson: Value(jsonEncode(raw)),
              updatedAt: Value(currentTimestampSeconds()),
            ),
          );
        } else {
          final count =
              await (update(
                memoryBookRows,
              )..where((t) => _controlPredicate(t, row))).write(
                MemoryBookRowsCompanion(
                  settingsJson: Value(jsonEncode(raw)),
                  updatedAt: Value(currentTimestampSeconds()),
                ),
              );
          check(count == 1);
        }
        check(true);
        final applied = await observeForControl(sessionId);
        check(applied != null);
        final settled = await journal.settleMutation(
          expected: reserved!,
          fact: SupportMutationFact.applied,
          hasOriginalDbCustody: owned,
        );
        check(settled != null);
        return MemoryBookSetupCommit._(
          settled!,
          applied!,
          before,
          setupFieldSnapshot(applied, fields.keys),
          row == null,
        );
      });
      return committed;
    } on _MemoryBookControlRetired {
      return null;
    } finally {
      final post = admission.finish();
      committed?._ticket = post;
    }
  }

  /// Fresh observed row + only receipt-owned settings comparison. Later bodies,
  /// drafts, vectors and unrelated raw settings are NEVER restored from receipt.
  Future<SupportMutationReservation?> undoSetup({
    required MemoryBookSetupCommit receipt,
    required MemoryBookControlObservation expected,
    required SupportRepo journal,
    required bool Function() isCurrent,
    required MemoryBookSetupTicket ticket,
  }) async {
    if (!identical(receipt._ticket, ticket)) return null;
    final admission = _beginSetupBookWrite(ticket);
    if (admission == null) return null;
    bool owned() => isCurrent() && admission.current;
    try {
      return await transaction(() async {
        void check(bool value) {
          if (!value || !owned()) throw const _MemoryBookControlRetired();
        }

        check(
          journal.usesDatabase(attachedDatabase) &&
              expected.book.sessionId == receipt.observation.book.sessionId,
        );
        final row = await (select(
          memoryBookRows,
        )..where((t) => _controlPredicate(t, expected._row))).getSingleOrNull();
        check(
          row != null &&
              jsonEncode(setupFieldSnapshot(expected, receipt.after.keys)) ==
                  jsonEncode(receipt.after),
        );
        // Creating a book cannot be undone by deleting later user content.
        check(!receipt.created || row == receipt.observation._row);
        final reserved = await journal.reserveMutationUndo(
          expected: receipt.journal,
          isCurrent: owned,
        );
        check(reserved != null);
        if (receipt.created) {
          final n = await (delete(
            memoryBookRows,
          )..where((t) => _controlPredicate(t, row!))).go();
          check(n == 1);
        } else {
          final raw = Map<String, dynamic>.from(
            jsonDecode(row!.settingsJson) as Map,
          );
          for (final e in receipt.before.entries) {
            final old = e.value! as Map;
            if (old['present'] == true) {
              raw[e.key] = old['value'];
            } else {
              raw.remove(e.key);
            }
          }
          final n =
              await (update(
                memoryBookRows,
              )..where((t) => _controlPredicate(t, row))).write(
                MemoryBookRowsCompanion(
                  settingsJson: Value(jsonEncode(raw)),
                  updatedAt: Value(currentTimestampSeconds()),
                ),
              );
          check(n == 1);
        }
        check(true);
        final result = await journal.settleMutation(
          expected: reserved!,
          fact: SupportMutationFact.undone,
          hasOriginalDbCustody: owned,
        );
        check(result != null);
        return result;
      });
    } on _MemoryBookControlRetired {
      return null;
    } finally {
      admission.finish();
    }
  }
}
