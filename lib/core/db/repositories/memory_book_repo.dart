import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_db.dart';
import '../database_transaction_guard.dart';
import '../tables.dart';
import '../../models/memory_book.dart';
import '../../models/memory_entry_revisions.dart';
import '../../models/memory_source_manifest.dart';
import '../../services/memory_prompt_presets.dart';
import '../../state/memory_settings_provider.dart';
import '../../utils/time_helpers.dart';
import '../../application/sync_repo_interfaces.dart';
import 'chat_repo.dart';
import 'memory_catalog_repo.dart';
import 'support_repo.dart';
import '../../models/support_models.dart';

part 'memory_book_repo.g.dart';
part 'memory_book_setup_store.dart';
part 'memory_book_setup_fence.dart';
part 'memory_book_native_entry_store.dart';
part 'memory_book_native_draft_store.dart';
part 'memory_book_native_draft_span.dart';
part 'memory_book_native_draft_removal_store.dart';

/// Native-only exact row observation. Never serialize this into tool metadata.
final class MemoryBookControlObservation {
  MemoryBookControlObservation._(this._row, this.book);
  final MemoryBookRow _row;
  final MemoryBook book;
}

final class _MemoryBookControlRetired implements Exception {
  const _MemoryBookControlRetired();
}

final class _MemoryBookCustomDraftRetired implements Exception {
  const _MemoryBookCustomDraftRetired();
}

@DriftAccessor(tables: [MemoryBookRows])
class MemoryBookRepo extends DatabaseAccessor<AppDatabase>
    with _$MemoryBookRepoMixin
    implements SyncMemoryBookStore {
  MemoryBookRepo(super.db, this._ref);

  final Ref _ref;

  /// Strict observation for conditional control; corrupt blobs are unavailable,
  /// not silently repaired through the ordinary compatibility reader.
  Future<MemoryBookControlObservation?> observeForControl(
    String sessionId,
  ) async {
    final row = await (select(
      memoryBookRows,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    try {
      final entries = (jsonDecode(row.entriesJson) as List)
          .map((e) => MemoryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false);
      final drafts = (jsonDecode(row.pendingDraftsJson) as List)
          .map((d) => MemoryDraft.fromJson(Map<String, dynamic>.from(d as Map)))
          .toList(growable: false);
      final settings = MemoryBookSettings.fromJson(
        jsonDecode(row.settingsJson) as Map<String, dynamic>,
      );
      return MemoryBookControlObservation._(
        row,
        MemoryBook(
          id: 'memorybook_$sessionId',
          sessionId: sessionId,
          entries: entries,
          pendingDrafts: drafts,
          settings: settings,
          lastProcessedMessageCount: row.lastProcessedMessageCount,
          updatedAt: row.updatedAt,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Creates an empty local book without importing global automation/network
  /// defaults. The session existence check and insert share one transaction.
  Future<bool> createEmptyForControl({
    required String sessionId,
    required bool enabled,
    required bool Function() isCurrent,
  }) => _trackSetupBookWrite(
    () => transaction(() async {
      if (!isCurrent()) return false;
      final session = await ChatRepo(attachedDatabase).getById(sessionId);
      if (session == null || !isCurrent()) return false;
      final settings = MemoryBookSettings(
        enabled: enabled,
        autoCreateEnabled: false,
        autoGenerateEnabled: false,
        vectorSearchEnabled: false,
        consolidationEnabled: false,
      );
      final inserted = await into(memoryBookRows).insertReturningOrNull(
        MemoryBookRowsCompanion.insert(
          sessionId: sessionId,
          settingsJson: Value(jsonEncode(settings.toJson())),
          updatedAt: Value(currentTimestampSeconds()),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      return inserted != null;
    }),
  );

  /// Scalar settings patch only. Raw unknown settings and all body/history blobs
  /// are preserved; an exact SQL row predicate is the final compare-and-swap.
  Future<bool> patchSettingsForControl({
    required MemoryBookControlObservation expected,
    required Map<String, Object?> fields,
    required bool Function() isCurrent,
  }) => _trackSetupBookWrite(
    () => transaction(() async {
      const allowed = {
        'enabled',
        'maxInjectedEntries',
        'maxInjectedTokens',
        'memoryExcerptingEnabled',
        'memoryPackingMode',
        'injectionTarget',
        'sourceWindowExclusion',
        'factualContinuityGuardEnabled',
      };
      if (fields.isEmpty ||
          fields.keys.any((k) => !allowed.contains(k)) ||
          !isCurrent()) {
        return false;
      }
      final settings = Map<String, dynamic>.from(
        jsonDecode(expected._row.settingsJson) as Map,
      )..addAll(fields);
      // Enforce model types without replacing unrelated/unknown serialized fields.
      MemoryBookSettings.fromJson(settings);
      return await (update(
            memoryBookRows,
          )..where((t) => _controlPredicate(t, expected._row))).write(
            MemoryBookRowsCompanion(
              settingsJson: Value(jsonEncode(settings)),
              updatedAt: Value(currentTimestampSeconds()),
            ),
          ) ==
          1;
    }),
  );

  /// Local draft flag only; content, source manifest and error are unchanged.
  Future<bool> setDraftVectorForControl({
    required MemoryBookControlObservation expected,
    required String draftId,
    required bool vectorSearch,
    required bool Function() isCurrent,
  }) => _trackSetupBookWrite(
    () => transaction(() async {
      if (!isCurrent()) return false;
      final drafts = (jsonDecode(expected._row.pendingDraftsJson) as List)
          .map((d) => Map<String, dynamic>.from(d as Map))
          .toList();
      final matches = drafts.where((d) => d['id'] == draftId).toList();
      if (matches.length != 1 ||
          !const {
            'pending_generation',
            'pending_approval',
            'error',
            'needs_regeneration',
          }.contains(matches.single['status'])) {
        return false;
      }
      matches.single['vectorSearch'] = vectorSearch;
      return await (update(
            memoryBookRows,
          )..where((t) => _controlPredicate(t, expected._row))).write(
            MemoryBookRowsCompanion(
              pendingDraftsJson: Value(jsonEncode(drafts)),
              updatedAt: Value(currentTimestampSeconds()),
            ),
          ) ==
          1;
    }),
  );

  /// Rebuilds only the disposable local catalog from the exact durable book.
  /// No embeddings, graph purge, generation or paid network work is dispatched.
  Future<bool> rebuildCatalogForControl({
    required MemoryBookControlObservation expected,
    required MemoryCatalogRepo catalog,
    required bool Function() isCurrent,
  }) async {
    try {
      return await transaction(() async {
        if (!identical(catalog.db, attachedDatabase) || !isCurrent()) {
          return false;
        }
        final row = await (select(
          memoryBookRows,
        )..where((t) => _controlPredicate(t, expected._row))).getSingleOrNull();
        if (row == null || !isCurrent()) return false;
        final session = await ChatRepo(
          attachedDatabase,
        ).getById(expected.book.sessionId);
        if (session == null ||
            !isCurrent() ||
            expected.book.entries.any(
              (entry) =>
                  entry.source == 'agentic' ||
                  entry.sourceManifest != null &&
                      entry.sourceManifest!.validate(
                            entry.messageIds,
                            session.messages,
                          ) !=
                          MemorySourceValidity.verified,
            )) {
          return false;
        }
        await catalog.rebuildForMemoryBook(expected.book);
        // The nested rebuild belongs to this transaction; a lost native lease
        // rolls the derived replacement back, never unauthorized publication.
        if (!isCurrent()) throw const _MemoryBookControlRetired();
        return true;
      });
    } on _MemoryBookControlRetired {
      return false;
    }
  }

  Expression<bool> _controlPredicate(
    $MemoryBookRowsTable table,
    MemoryBookRow row,
  ) =>
      table.sessionId.equals(row.sessionId) &
      table.settingsJson.equals(row.settingsJson) &
      table.entriesJson.equals(row.entriesJson) &
      table.pendingDraftsJson.equals(row.pendingDraftsJson) &
      table.lastProcessedMessageCount.equals(row.lastProcessedMessageCount) &
      table.updatedAt.equals(row.updatedAt);

  Future<MemoryBook> ensureForSession(String sessionId) =>
      _trackSetupBookWrite(() async {
        final existing = await getBySessionId(sessionId);
        if (existing != null) return existing;
        final global = _ref.read(memoryGlobalSettingsProvider);
        final book = MemoryBook(
          id: 'memorybook_$sessionId',
          sessionId: sessionId,
          settings: MemoryBookSettings(
            enabled: global.enabled,
            memoryMode: global.memoryMode,
            autoCreateEnabled: global.autoCreateEnabled,
            autoGenerateEnabled: global.autoGenerateEnabled,
            maxInjectedEntries: global.maxInjectedEntries,
            memoryExcerptingEnabled: global.memoryExcerptingEnabled,
            memoryPackingMode: global.memoryPackingMode,
            memoryExcerptTokensPerChunk: global.memoryExcerptTokensPerChunk,
            memoryExcerptChunksPerEntry: global.memoryExcerptChunksPerEntry,
            chunkFirstTopEntries: global.chunkFirstTopEntries,
            chunkFirstTopChunks: global.chunkFirstTopChunks,
            maxInjectedTokens: global.maxInjectedTokens,
            memoryBudgetPreset: global.memoryBudgetPreset,
            autoCreateInterval: global.autoCreateInterval,
            autoCreateLagMessages: global.autoCreateLagMessages,
            useDelayedAutomation: global.useDelayedAutomation,
            injectionTarget: global.injectionTarget,
            batchSize: global.batchSize,
            vectorSearchEnabled: global.vectorSearchEnabled,
            keyMatchMode: global.keyMatchMode,
            promptPreset: global.promptPreset,
            diversityAware: global.diversityAware,
            diversityPenalty: global.diversityPenalty,
            recencyBoost: global.recencyBoost,
            recencyHalfLifeDays: global.recencyHalfLifeDays,
            importanceBoost: global.importanceBoost,
            importanceWeight: global.importanceWeight,
            sourceWindowExclusion: global.sourceWindowExclusion,
            factualContinuityGuardEnabled: global.factualContinuityGuardEnabled,
            queryIncludeAssistant: global.queryIncludeAssistant,
            queryRecentTurns: global.queryRecentTurns,
            queryMaxChars: global.queryMaxChars,
            cadenceInterval: global.cadenceInterval,
          ),
        );
        await put(book);
        return book;
      });

  @override
  Future<List<MemoryBook>> getAll() async {
    final rows = await select(memoryBookRows).get();
    return rows.map(_rowToModel).toList();
  }

  @override
  Future<void> put(MemoryBook book) =>
      _trackSetupBookWrite(() => transaction(() => _put(book)));

  Future<void> _put(
    MemoryBook book, {
    ({
      String draftId,
      MemoryDraft Function(MemoryDraft) mutate,
      bool Function() isCurrent,
      MemoryDraft Function(MemoryDraft) sanitize,
    })?
    customDraftPublication,
  }) async {
    final existing = await getBySessionId(book.sessionId);
    if (customDraftPublication != null) {
      final publication = customDraftPublication;
      void check() {
        if (!publication.isCurrent()) {
          throw const _MemoryBookCustomDraftRetired();
        }
      }

      // This is the final read, not the caller's earlier transaction snapshot.
      // Preserve current book/history columns and every sibling draft's data.
      check();
      final index =
          existing?.pendingDrafts.indexWhere(
            (draft) => draft.id == publication.draftId,
          ) ??
          -1;
      if (existing == null || index < 0) {
        throw const _MemoryBookCustomDraftRetired();
      }
      final drafts = [...existing.pendingDrafts];
      drafts[index] = publication.sanitize(publication.mutate(drafts[index]));
      if (drafts[index].id != publication.draftId) {
        throw const _MemoryBookCustomDraftRetired();
      }
      final submittedDraft = drafts[index];
      final submittedDraftJson = jsonEncode(submittedDraft.toJson());
      // No await between CURRENT + original sanitization and serialization.
      check();
      await (update(
        memoryBookRows,
      )..where((table) => table.sessionId.equals(book.sessionId))).write(
        MemoryBookRowsCompanion(
          pendingDraftsJson: Value(
            jsonEncode(drafts.map((draft) => draft.toJson()).toList()),
          ),
          updatedAt: Value(currentTimestampSeconds()),
        ),
      );
      // Ownership and redaction coverage are separate: registering a new alias
      // does not retire the invocation. Reject its now-unsafe submitted value
      // inside the transaction, without replaying the mutation or rewriting it.
      check();
      if (jsonEncode(publication.sanitize(submittedDraft).toJson()) !=
          submittedDraftJson) {
        throw const _MemoryBookCustomDraftRetired();
      }
      check();
      return;
    }
    final priorEntries = {
      for (final entry in existing?.entries ?? const <MemoryEntry>[])
        entry.id: entry,
    };
    book = book.copyWith(
      entries: book.entries
          .map(
            (entry) =>
                MemoryEntryRevisions.prepare(entry, priorEntries[entry.id]),
          )
          .toList(),
    );
    final retiredEntryIds = <String>{
      ...?existing?.entries
          .where((entry) => entry.source == 'agentic')
          .map((entry) => entry.id),
      ...book.entries
          .where((entry) => entry.source == 'agentic')
          .map((entry) => entry.id),
    };
    final sanitized = book.copyWith(
      entries: book.entries
          .where((entry) => entry.source != 'agentic')
          .toList(),
      pendingDrafts: book.pendingDrafts
          .where((draft) => draft.source != 'agentic')
          .toList(),
    );

    await into(memoryBookRows).insertOnConflictUpdate(
      MemoryBookRowsCompanion.insert(
        sessionId: sanitized.sessionId,
        entriesJson: Value(
          jsonEncode(sanitized.entries.map((e) => e.toJson()).toList()),
        ),
        pendingDraftsJson: Value(
          jsonEncode(sanitized.pendingDrafts.map((d) => d.toJson()).toList()),
        ),
        settingsJson: Value(jsonEncode(sanitized.settings.toJson())),
        lastProcessedMessageCount: Value(sanitized.lastProcessedMessageCount),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
    for (final entryId in retiredEntryIds) {
      await customStatement('DELETE FROM embeddings WHERE entry_id = ?', [
        entryId,
      ]);
      await customStatement(
        'DELETE FROM memory_catalog_rows WHERE memory_entry_id = ?',
        [entryId],
      );
      await customStatement(
        'DELETE FROM memory_entity_rows WHERE memory_entry_id = ?',
        [entryId],
      );
      await customStatement(
        'DELETE FROM memory_salience_rows WHERE memory_entry_id = ?',
        [entryId],
      );
    }
  }

  Future<void> updateSettings(String sessionId, MemoryBookSettings settings) {
    return _trackSetupBookWrite(
      () =>
          (update(
            memoryBookRows,
          )..where((t) => t.sessionId.equals(sessionId))).write(
            MemoryBookRowsCompanion(
              settingsJson: Value(jsonEncode(settings.toJson())),
              updatedAt: Value(currentTimestampSeconds()),
            ),
          ),
    );
  }

  /// Checks that the exact entries selected for a prepared request are still
  /// active and unchanged. Historical source validation belongs to the
  /// historical-request path; ordinary sends do not rescan old chat text.
  Future<bool> areEntriesCurrent(
    String sessionId,
    Iterable<MemoryEntry> used,
  ) => transaction(() async {
    final book = await getBySessionId(sessionId);
    for (final entry in used) {
      final current = book?.entries.where((e) => e.id == entry.id).firstOrNull;
      if (current == null || current != entry || current.status != 'active') {
        return false;
      }
    }
    return true;
  });

  /// Approval and source validation share a transaction with the durable chat.
  Future<MemoryBook?> approveDraft(
    String sessionId,
    String draftId,
    MemoryDraft expected,
  ) => _trackSetupBookWrite(
    () => transaction(() async {
      final book = await getBySessionId(sessionId);
      if (book == null) return null;
      final draft = book.pendingDrafts
          .where((d) => d.id == draftId)
          .firstOrNull;
      if (draft == null) return null;
      if (jsonEncode(draft.toJson()) != jsonEncode(expected.toJson())) {
        throw StateError('Memory draft changed. Reload it before approval.');
      }
      if (draft.content.trim().isEmpty) return null;
      final entry = MemoryEntryRevisions.initialize(
        MemoryEntry(
          id: draft.id.replaceAll('draft_', 'mem_'),
          title: draft.title,
          content: draft.content,
          keys: draft.keys,
          keyParagraphs: draft.keyParagraphs,
          ledgerRange: draft.ledgerRange,
          vectorSearch: draft.vectorSearch,
          messageIds: draft.messageIds,
          messageRange: draft.messageRange,
          sourceManifest: draft.sourceManifest,
          sourceSwipeId: draft.sourceSwipeId,
          sourceAgentSwipeId: draft.sourceAgentSwipeId,
          source: draft.source,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
        reason: 'approved_generation',
        reviewer: 'user',
      );
      final updated = book.copyWith(
        entries: [...book.entries, entry],
        pendingDrafts: book.pendingDrafts
            .where((d) => d.id != draftId)
            .toList(),
      );
      await put(updated);
      return getBySessionId(sessionId);
    }),
  );

  /// Repairs prompt selections after the complete set of available presets
  /// changes. Only the settings JSON of affected existing books is updated.
  /// Entries, drafts, cursors, and all unrelated settings remain untouched.
  Future<int> repairPromptPresetSelections(Iterable<String> customPresetKeys) =>
      _trackSetupBookWrite(() async {
        final safeKeys = {
          ...MemoryPromptPresets.builtIn.map((preset) => preset.key),
          ...customPresetKeys,
        };
        var repaired = 0;
        await transaction(() async {
          final rows = await select(memoryBookRows).get();
          for (final row in rows) {
            final Map<String, dynamic> rawSettings;
            try {
              final decoded = jsonDecode(row.settingsJson);
              if (decoded is! Map<String, dynamic>) continue;
              rawSettings = decoded;
            } catch (_) {
              continue;
            }
            final normalized = MemoryPromptPresets.normalizeSerializedSelection(
              rawSettings,
              safeKeys,
            );
            if (identical(normalized, rawSettings)) continue;
            await (update(
              memoryBookRows,
            )..where((table) => table.sessionId.equals(row.sessionId))).write(
              MemoryBookRowsCompanion(
                settingsJson: Value(jsonEncode(normalized)),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
            repaired++;
          }
        });
        return repaired;
      });

  /// Atomically appends [drafts] to the pending drafts of the memory book
  /// for [sessionId]. Wraps the read-modify-write in a transaction so
  /// concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// Used by user-directed MemoryBook draft workflows without racing with
  /// other MemoryBook writes.
  Future<void> appendDrafts(String sessionId, List<MemoryDraft> drafts) =>
      _trackSetupBookWrite(() async {
        if (drafts.isEmpty) return;
        await transaction(() async {
          final existing = await getBySessionId(sessionId);
          final book =
              existing ??
              MemoryBook(id: 'memorybook_$sessionId', sessionId: sessionId);
          await put(
            book.copyWith(pendingDrafts: [...book.pendingDrafts, ...drafts]),
          );
        });
      });

  /// Applies a narrow mutation to one draft using the latest durable book.
  /// Returns false when the book or draft was removed while work was in flight.
  /// Custom publication alone supplies the original guard and final sanitizer;
  /// ordinary callers retain their existing put/compatibility behavior.
  Future<bool> mutateDraft({
    required String sessionId,
    required String draftId,
    required MemoryDraft Function(MemoryDraft current) mutate,
    bool Function()? customPublicationIsCurrent,
    MemoryDraft Function(MemoryDraft)? sanitizeCustomPublication,
  }) => _trackSetupBookWrite(() async {
    if ((customPublicationIsCurrent == null) !=
        (sanitizeCustomPublication == null)) {
      throw ArgumentError(
        'Custom draft publication needs both guard and sanitizer.',
      );
    }
    var updated = false;
    try {
      await transaction(() async {
        if (customPublicationIsCurrent?.call() == false) return;
        final existing = await getBySessionId(sessionId);
        if (existing == null || customPublicationIsCurrent?.call() == false)
          return;
        final index = existing.pendingDrafts.indexWhere((d) => d.id == draftId);
        if (index < 0) return;
        if (customPublicationIsCurrent != null) {
          await _put(
            existing,
            customDraftPublication: (
              draftId: draftId,
              mutate: mutate,
              isCurrent: customPublicationIsCurrent,
              sanitize: sanitizeCustomPublication!,
            ),
          );
          if (!customPublicationIsCurrent()) {
            throw const _MemoryBookCustomDraftRetired();
          }
        } else {
          final drafts = [...existing.pendingDrafts];
          drafts[index] = mutate(drafts[index]);
          await put(existing.copyWith(pendingDrafts: drafts));
        }
        updated = true;
      });
    } on _MemoryBookCustomDraftRetired {
      return false;
    }
    return updated;
  });

  /// Atomically appends [entries] to the approved entries of the memory book
  /// for [sessionId]. Wraps the read-modify-write in a transaction so
  /// concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// Callers must validate [entries] before appending them.
  Future<void> appendApprovedEntries(
    String sessionId,
    List<MemoryEntry> entries,
  ) => _trackSetupBookWrite(() async {
    if (entries.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      final book =
          existing ??
          MemoryBook(id: 'memorybook_$sessionId', sessionId: sessionId);
      await put(book.copyWith(entries: [...book.entries, ...entries]));
    });
  });

  /// Atomically replaces the entry with [entryId] in the memory book for
  /// [sessionId] with [updated]. Wraps the read-modify-write in a transaction
  /// (database.md Rule 3). Used by the memory dedup service to merge
  /// near-duplicate entries.
  ///
  /// Returns true if the entry was found and updated, false otherwise.
  Future<bool> updateEntry({
    required String sessionId,
    required String entryId,
    required MemoryEntry updated,
  }) => _trackSetupBookWrite(() async {
    var didUpdate = false;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final idx = existing.entries.indexWhere((e) => e.id == entryId);
      if (idx < 0) return;
      didUpdate = true;
      final updatedEntries = List<MemoryEntry>.from(existing.entries);
      updatedEntries[idx] = updated;
      await put(existing.copyWith(entries: updatedEntries));
    });
    return didUpdate;
  });

  /// Applies an editor result only if [expected] is still the durable entry.
  /// Text changes append a revision; the previous active snapshot is never
  /// replaced or deleted.
  Future<MemoryEntry?> reviseEntry({
    required String sessionId,
    required MemoryEntry expected,
    required MemoryEntry proposed,
    String reason = 'manual_edit',
  }) => _trackSetupBookWrite(
    () => transaction(() async {
      final book = await getBySessionId(sessionId);
      final current = book?.entries
          .where((entry) => entry.id == expected.id)
          .firstOrNull;
      if (book == null || current == null) return null;
      final normalizedExpected = MemoryEntryRevisions.initialize(expected);
      final normalizedCurrent = MemoryEntryRevisions.initialize(current);
      if (normalizedCurrent != normalizedExpected ||
          proposed.id != current.id) {
        throw StateError('Memory changed while editing. Reload before saving.');
      }
      final edited = current.copyWith(
        title: proposed.title,
        content: proposed.content,
        keys: proposed.keys,
        keyParagraphs: proposed.keyParagraphs,
        ledgerRange: proposed.ledgerRange,
      );
      final revised = MemoryEntryRevisions.prepare(
        edited,
        current,
        author: 'user',
        reason: reason,
        reviewer: 'user',
      );
      await put(
        book.copyWith(
          entries: book.entries
              .map((entry) => entry.id == current.id ? revised : entry)
              .toList(),
        ),
      );
      return revised;
    }),
  );

  /// Restores the text from [revisionId] by appending a new active revision.
  /// The historical revision remains untouched and the active pointer never
  /// moves backwards.
  Future<MemoryEntry?> restoreEntryRevision({
    required String sessionId,
    required MemoryEntry expected,
    required String revisionId,
  }) => _trackSetupBookWrite(() async {
    final current = await getBySessionId(sessionId).then(
      (book) =>
          book?.entries.where((entry) => entry.id == expected.id).firstOrNull,
    );
    if (current == null) return null;
    final restored = MemoryEntryRevisions.restoreRevision(current, revisionId);
    return reviseEntry(
      sessionId: sessionId,
      expected: expected,
      proposed: restored,
      reason: 'restore_revision',
    );
  });

  /// Atomically removes the entry with [entryId] from the memory book for
  /// [sessionId]. Wraps the read-modify-write in a transaction (database.md
  /// Rule 3). Used by the memory dedup service to drop redundant entries.
  ///
  /// Returns true if the entry was found and deleted, false otherwise.
  Future<bool> deleteEntry({
    required String sessionId,
    required String entryId,
  }) => _trackSetupBookWrite(() async {
    var didDelete = false;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final kept = existing.entries.where((e) => e.id != entryId).toList();
      if (kept.length == existing.entries.length) return;
      didDelete = true;
      await put(existing.copyWith(entries: kept));
    });
    return didDelete;
  });

  /// Retains manifested history as invalid evidence when its source is deleted.
  /// Legacy records retain their existing deletion behavior.
  Future<void> deleteForMessage(String sessionId, String messageId) async {
    await deleteForMessages(sessionId, {messageId});
  }

  /// Atomically invalidates manifested records and removes legacy dependants.
  Future<void> deleteForMessages(
    String sessionId,
    Set<String> messageIds,
  ) => _trackSetupBookWrite(() async {
    if (messageIds.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final keptEntries = existing.entries
          .where(
            (e) =>
                e.sourceManifest != null ||
                !e.messageIds.any(messageIds.contains),
          )
          .map(
            (e) =>
                e.sourceManifest != null &&
                    e.messageIds.any(messageIds.contains)
                ? e.copyWith(sourceManifest: e.sourceManifest!.invalidate())
                : e,
          )
          .toList();
      final keptDrafts = existing.pendingDrafts
          .where(
            (d) =>
                d.sourceManifest != null ||
                !d.messageIds.any(messageIds.contains),
          )
          .map(
            (d) =>
                d.sourceManifest != null &&
                    d.messageIds.any(messageIds.contains)
                ? d.copyWith(
                    sourceManifest: d.sourceManifest!.invalidate(),
                    status: 'needs_regeneration',
                  )
                : d,
          )
          .toList();
      if (!existing.entries.any((e) => e.messageIds.any(messageIds.contains)) &&
          !existing.pendingDrafts.any(
            (d) => d.messageIds.any(messageIds.contains),
          ) &&
          keptEntries.length == existing.entries.length &&
          keptDrafts.length == existing.pendingDrafts.length) {
        return;
      }
      await put(
        existing.copyWith(entries: keptEntries, pendingDrafts: keptDrafts),
      );
    });
  });

  Future<void> deleteSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
  }) => _deleteVariationAndShift(
    sessionId: sessionId,
    messageId: messageId,
    removedSwipeId: removedSwipeId,
  );

  Future<void> deleteAgentSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int removedAgentSwipeId,
  }) => _deleteVariationAndShift(
    sessionId: sessionId,
    messageId: messageId,
    removedSwipeId: swipeId,
    removedAgentSwipeId: removedAgentSwipeId,
  );

  Future<void> _deleteVariationAndShift({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
    int? removedAgentSwipeId,
  }) => _trackSetupBookWrite(
    () => transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;

      bool belongsToMessage(List<String> ids) => ids.contains(messageId);
      bool removeAnchor(int swipeId, int agentSwipeId) =>
          swipeId == removedSwipeId &&
          (removedAgentSwipeId == null || agentSwipeId == removedAgentSwipeId);
      int shiftedSwipe(int value) =>
          removedAgentSwipeId == null && value > removedSwipeId
          ? value - 1
          : value;
      int shiftedAgent(int swipeId, int value) =>
          removedAgentSwipeId != null &&
              swipeId == removedSwipeId &&
              value > removedAgentSwipeId
          ? value - 1
          : value;

      final entries = existing.entries
          .where(
            (entry) =>
                entry.sourceManifest != null ||
                !belongsToMessage(entry.messageIds) ||
                !removeAnchor(entry.sourceSwipeId, entry.sourceAgentSwipeId),
          )
          .map(
            (entry) => entry.sourceManifest != null
                ? entry.copyWith(
                    sourceManifest: entry.sourceManifest!.removeVariation(
                      messageId,
                      removedSwipeId,
                      removedAgentSwipeId,
                    ),
                  )
                : !belongsToMessage(entry.messageIds)
                ? entry
                : entry.copyWith(
                    sourceSwipeId: shiftedSwipe(entry.sourceSwipeId),
                    sourceAgentSwipeId: shiftedAgent(
                      entry.sourceSwipeId,
                      entry.sourceAgentSwipeId,
                    ),
                  ),
          )
          .toList();
      final drafts = existing.pendingDrafts
          .where(
            (draft) =>
                draft.sourceManifest != null ||
                !belongsToMessage(draft.messageIds) ||
                !removeAnchor(draft.sourceSwipeId, draft.sourceAgentSwipeId),
          )
          .map(
            (draft) => draft.sourceManifest != null
                ? draft.copyWith(
                    sourceManifest: draft.sourceManifest!.removeVariation(
                      messageId,
                      removedSwipeId,
                      removedAgentSwipeId,
                    ),
                  )
                : !belongsToMessage(draft.messageIds)
                ? draft
                : draft.copyWith(
                    sourceSwipeId: shiftedSwipe(draft.sourceSwipeId),
                    sourceAgentSwipeId: shiftedAgent(
                      draft.sourceSwipeId,
                      draft.sourceAgentSwipeId,
                    ),
                  ),
          )
          .toList();
      await put(existing.copyWith(entries: entries, pendingDrafts: drafts));
    }),
  );

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) => _trackSetupBookWrite(() async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    bool isRetained(List<String> sourceIds) =>
        sourceIds.isNotEmpty && sourceIds.every(messageIds.contains);
    await put(
      source.copyWith(
        id: 'memorybook_$toSessionId',
        sessionId: toSessionId,
        entries: source.entries
            .where((entry) => isRetained(entry.messageIds))
            .map((entry) => entry.copyWith(id: '${entry.id}@$toSessionId'))
            .toList(),
        pendingDrafts: source.pendingDrafts
            .where((draft) => isRetained(draft.messageIds))
            .map((draft) => draft.copyWith(id: '${draft.id}@$toSessionId'))
            .toList(),
        // Derived indexes are intentionally not copied. Reprocessing the
        // retained history is safer than inheriting an opaque source cursor.
        lastProcessedMessageCount: 0,
      ),
    );
  });

  @override
  Future<void> deleteBySessionId(String sessionId) {
    return _trackSetupBookWrite(
      () => (delete(
        memoryBookRows,
      )..where((t) => t.sessionId.equals(sessionId))).go(),
    );
  }

  @override
  Future<MemoryBook?> getBySessionId(String sessionId) async {
    final row = await (select(
      memoryBookRows,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    return _rowToModel(row);
  }

  MemoryBook _rowToModel(MemoryBookRow row) {
    List<MemoryEntry> entries;
    try {
      final list = jsonDecode(row.entriesJson) as List<dynamic>;
      entries = list
          .map((e) => MemoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      entries = [];
    }

    List<MemoryDraft> pendingDrafts;
    try {
      final list = jsonDecode(row.pendingDraftsJson) as List<dynamic>;
      pendingDrafts = list
          .map((e) => MemoryDraft.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      pendingDrafts = [];
    }

    MemoryBookSettings settings;
    try {
      settings = MemoryBookSettings.fromJson(
        jsonDecode(row.settingsJson) as Map<String, dynamic>,
      );
    } catch (_) {
      settings = const MemoryBookSettings();
    }

    return MemoryBook(
      id: 'memorybook_${row.sessionId}',
      sessionId: row.sessionId,
      entries: entries,
      pendingDrafts: pendingDrafts,
      settings: settings,
      lastProcessedMessageCount: row.lastProcessedMessageCount,
      updatedAt: row.updatedAt,
    );
  }
}
