import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/keyless_api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';
import '../support/helpers/support_mutation_journal_fixture.dart'
    show JournalControlledCipher, JournalControlledSql;

export '../support/helpers/support_mutation_journal_fixture.dart'
    show JournalBarrier;

/// Declared memory schema only. No normal opener, seed/default graph or disk.
final class ProviderMemoryDatabase extends AppDatabase {
  ProviderMemoryDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
  Future<void> Function()? beforeOuterCommit;
  Future<void> Function()? afterOuterCommit;
  static final _transactionZone = Object();
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    if (identical(Zone.current[_transactionZone], this)) {
      return super.transaction(action, requireNew: requireNew);
    }
    final result = await super.transaction(
      () => runZoned(() async {
        final result = await action();
        // Fault here makes the actual enclosing SQLite transaction roll back.
        // Not a claim about power loss or a physical COMMIT engine fault.
        await beforeOuterCommit?.call();
        return result;
      }, zoneValues: {_transactionZone: this}),
      requireNew: requireNew,
    );
    await afterOuterCommit?.call();
    return result;
  }
}

void providerRepoTest(
  String name,
  Future<void> Function(ProviderRepoFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String reason) {
      attempts.add(reason);
      throw StateError('Outside synthetic provider repository fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = ProviderRepoFixture();
            try {
              await f.seed();
              await body(f);
            } finally {
              f.clearHooks();
              await f.db.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

final class ProviderRepoFixture {
  ProviderRepoFixture() {
    db = ProviderMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_provider_repo',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    support = SupportRepo(db, cipher);
    native.event = event;
    api = ApiConfigRepo(
      db,
      keylessMutations: native,
      keylessCreateUndoProof: proof,
      onMutationStarted: observeMutation,
    );
    setup = SupportProviderSetupRepo(
      db: db,
      apiRepo: api,
      supportRepo: support,
    );
    primitive.event = event;
    sql.event = event;
    storage.beforeRead = () => event('vault-read');
    storage.beforeWrite = () => event('vault-write');
  }
  static const sessionId = 'synthetic-provider-session';
  static const nameCanary = 'SYNTHETIC_PRIVATE_NAME_CANARY';
  static const urlCanary = 'synthetic-private-url-canary.invalid';
  static const secretCanary = 'SYNTHETIC_SECRET_NOT_A_REAL_KEY';
  final storage = FakeCredentialStorage();
  final primitive = JournalControlledCipher();
  final sql = ProviderControlledSql();
  // Explicit synthetic positive absence proof; never inferred from null/error.
  final native = ProviderFakeMutationPort(verifiedAbsence: true);
  final proof = ProviderFakeProofPort();
  late final ProviderMemoryDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo support;
  late final ApiConfigRepo api;
  late final SupportProviderSetupRepo setup;
  final events = <String>[];
  Future<void> Function(String)? hook;
  bool current = true;
  int pendingFences = 0;
  void Function() observeMutation() {
    pendingFences++;
    final finish = native.onMutationStarted();
    return () {
      try {
        finish();
      } finally {
        pendingFences--;
      }
    };
  }

  bool isCurrent() => current;
  Future<void> event(String value) async {
    events.add(value);
    await hook?.call(value);
  }

  Future<void> seed() => support.createSession(
    const SupportSession(
      id: sessionId,
      title: 'SYNTHETIC_TITLE',
      createdAt: 1,
      updatedAt: 1,
    ),
  );

  KeylessApiConfigDraft draft({String name = nameCanary}) =>
      KeylessApiConfigDraft(
        nativeId: NativeKeylessConnectionId.generate(),
        displayName: name,
        providerId: 'custom_chat_completion',
        protocol: 'custom_chat_completion',
        endpoint: 'https://$urlCanary/v1/chat/completions',
        model: 'synthetic-model',
        maxTokens: 512,
        contextSize: 4096,
        temperature: 0.7,
      );
  KeylessApiConfigPatch patch({String name = 'SYNTHETIC_RENAMED'}) =>
      KeylessApiConfigPatch(
        displayName: name,
        model: 'synthetic-next-model',
        maxTokens: 1024,
        contextSize: 8192,
        temperature: 0.5,
      );
  SupportMutationRecord evidence({
    required String journalId,
    required SupportProviderSetupAction action,
    KeylessApiConfigView? before,
    required KeylessApiConfigView after,
  }) => SupportMutationRecord(
    id: journalId,
    sessionId: sessionId,
    domain: SupportProviderSetupRepo.domain,
    targetId: after.connectionId,
    status: 'pending',
    createdAt: 2,
    beforeJson: SupportProviderSetupEvidence.encode(
      action: action,
      sessionId: sessionId,
      connectionId: after.connectionId,
      state: before,
    ),
    afterJson: SupportProviderSetupEvidence.encode(
      action: action,
      sessionId: sessionId,
      connectionId: after.connectionId,
      state: after,
    ),
  );
  Future<SupportProviderSetupReceipt?> create(
    KeylessApiConfigDraft draft, {
    String journalId = 'synthetic-create',
  }) => setup.create(
    draft: draft,
    pendingEvidence: evidence(
      journalId: journalId,
      action: SupportProviderSetupAction.create,
      after: draft.view,
    ),
    isCurrent: isCurrent,
  );
  Future<SupportProviderSetupReceipt?> update(
    KeylessApiConfigObservation expected,
    KeylessApiConfigPatch patch, {
    String journalId = 'synthetic-update',
  }) => setup.update(
    expected: expected,
    patch: patch,
    pendingEvidence: evidence(
      journalId: journalId,
      action: SupportProviderSetupAction.update,
      before: expected.view,
      after: patch.applyTo(expected.view),
    ),
    isCurrent: isCurrent,
  );
  Future<ApiConfigRow?> row(String id) => (db.select(
    db.apiConfigs,
  )..where((t) => t.configId.equals(id))).getSingleOrNull();
  Future<SupportMutationJournalRow?> journal(String id) => (db.select(
    db.supportMutationJournal,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> change(String id, ApiConfigsCompanion values) => (db.update(
    db.apiConfigs,
  )..where((t) => t.configId.equals(id))).write(values);
  Future<String> snapshot() async => jsonEncode({
    'api': (await db.select(db.apiConfigs).get())
        .map((r) => r.toJson())
        .toList(),
    'journal': (await db.select(db.supportMutationJournal).get())
        .map((r) => r.toJson())
        .toList(),
    'session': (await db.select(db.supportSessions).get())
        .map((r) => r.toJson())
        .toList(),
  });
  void clearHooks() {
    hook = null;
    db.beforeOuterCommit = null;
    db.afterOuterCommit = null;
    storage.readError = null;
    storage.writeError = null;
    sql.beforeOuterSend = null;
    sql.afterOuterSend = null;
    native.beforeSettlement = null;
  }
}

/// Actual memory SQLite transaction-send interception. Nested journal savepoints
/// are distinguished from the outer send. A before-send fault exercises Drift's
/// real rollback path; it does not establish power-loss or filesystem durability.
final class ProviderControlledSql extends QueryInterceptor {
  final _queries = JournalControlledSql();
  final _outer = <TransactionExecutor, bool>{};
  Future<void> Function()? beforeOuterSend;
  Future<void> Function()? afterOuterSend;
  set event(Future<void> Function(String)? value) => _queries.event = value;
  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final transaction = super.beginTransaction(parent);
    _outer[transaction] = parent is! TransactionExecutor;
    return transaction;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final outer = _outer[inner] == true;
    if (outer) await beforeOuterSend?.call();
    await super.commitTransaction(inner);
    if (outer) await afterOuterSend?.call();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _queries.runSelect(executor, statement, args);
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _queries.runInsert(executor, statement, args);
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _queries.runUpdate(executor, statement, args);
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _queries.runDelete(executor, statement, args);
}

/// Synthetic bridge only; production must connect the real shared native owner.
final class ProviderFakeMutationPort implements KeylessNativeMutationPort {
  ProviderFakeMutationPort({required this.verifiedAbsence});
  final _revisions = <String, Object>{};
  final _held = <String>{};
  final _active = <String, _ProviderFakeMutationLease>{};
  final _zoneKey = Object();
  final protectedConnections = <String>{};
  final observerZones = <bool>[];
  bool credentialStateKnown = true;
  bool verifiedAbsence;
  bool disposed = false;
  int releaseCalls = 0;
  Future<void> Function()? beforeSettlement;
  Future<void> Function(String)? event;
  @override
  Object? revisionFor(String id) =>
      disposed || _held.isNotEmpty ? null : _rawRevision(id);
  Object _rawRevision(String id) => _revisions.putIfAbsent(id, Object.new);
  void _setRevision(String id, Object revision) {
    // The production native owner is conservatively global for this DB.
    for (final known in List.of(_revisions.keys)) {
      _revisions[known] = revision;
    }
    _revisions[id] = revision;
  }

  void ordinaryMutation(String id) {
    _setRevision(id, Object());
    for (final lease in _active.values) {
      lease.invalidated = true;
    }
  }

  void Function() onMutationStarted() {
    final token = Zone.current[_zoneKey];
    final own = token is _ProviderFakeMutationLease && token.isCurrent
        ? token
        : null;
    observerZones.add(own != null);
    void fence() {
      if (own != null && own.isCurrent) {
        own.active = Object();
        _setRevision(own.id, own.active);
      } else {
        for (final lease in _active.values) {
          lease.invalidated = true;
        }
        for (final id in List.of(_revisions.keys)) {
          _revisions[id] = Object();
        }
      }
    }

    fence();
    return () {
      observerZones.add(own != null && own.isCurrent);
      fence();
    };
  }

  @override
  Future<KeylessNativeMutationLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  }) => _acquire(connectionId, isCurrent, true);

  /// Ordinary run labels do not authorize or probe a credential record. Its
  /// beforePut/Delete checks inspect the actual target after the owner is held.
  Future<KeylessNativeMutationLease?> acquireOrdinary(
    String label,
    bool Function() isCurrent,
  ) => _acquire(label, isCurrent, false);

  Future<KeylessNativeMutationLease?> _acquire(
    String connectionId,
    bool Function() isCurrent,
    bool inspectCredentialState,
  ) async {
    final prior = revisionFor(connectionId);
    await event?.call('native-acquire');
    if (!isCurrent() ||
        prior == null ||
        prior != revisionFor(connectionId) ||
        (inspectCredentialState &&
            (!credentialStateKnown ||
                (!protectedConnections.contains(connectionId) &&
                    !verifiedAbsence)))) {
      return null;
    }
    _held.add(connectionId);
    final active = Object();
    _setRevision(connectionId, active);
    final lease = _ProviderFakeMutationLease(
      this,
      connectionId,
      prior,
      active,
      isCurrent,
      inspectCredentialState && protectedConnections.contains(connectionId),
      inspectCredentialState &&
          !protectedConnections.contains(connectionId) &&
          verifiedAbsence,
    );
    _active[connectionId] = lease;
    return lease;
  }
}

final class _ProviderFakeMutationLease implements KeylessNativeMutationLease {
  _ProviderFakeMutationLease(
    this.port,
    this.id,
    this.priorRevision,
    this.active,
    this.current,
    this.nativeOwned,
    this.allowsModelChange,
  );
  final ProviderFakeMutationPort port;
  final String id;
  @override
  final Object priorRevision;
  Object active;
  final bool Function() current;
  @override
  final bool nativeOwned;
  @override
  final bool allowsModelChange;
  bool released = false;
  bool invalidated = false;
  Object? _settlement;
  @override
  bool get isCurrent =>
      !released &&
      !invalidated &&
      !port.disposed &&
      port._rawRevision(id) == active &&
      current() &&
      !invalidated &&
      port._rawRevision(id) == active;
  @override
  Future<T> runObservedMutation<T>(Future<T> Function() operation) async {
    if (!isCurrent) throw StateError('Synthetic stale owner.');
    try {
      // Deliberately no post-result admission check; the repo guards its writes.
      return await runZoned(operation, zoneValues: {port._zoneKey: this});
    } catch (_) {
      throw StateError('Synthetic fixed-safe native wrapper failure.');
    }
  }

  @override
  Object? get settlementRevision =>
      released &&
          _settlement != null &&
          !port.disposed &&
          !invalidated &&
          port._rawRevision(id) == _settlement
      ? _settlement
      : null;
  @override
  Future<void> release() async {
    if (released) throw StateError('Synthetic lease released twice.');
    released = true;
    port.releaseCalls++;
    var completed = false;
    try {
      await port.beforeSettlement?.call();
      completed = true;
    } finally {
      port._held.remove(id);
      port._active.remove(id);
      if (completed &&
          !invalidated &&
          !port.disposed &&
          port._rawRevision(id) == active) {
        _settlement = Object();
        port._setRevision(id, _settlement!);
      }
    }
  }
}

final class ProviderFakeProofPort implements KeylessCreateUndoProofPort {
  bool known = false;
  bool credentialAbsent = false;
  bool referencesAbsent = false;
  bool current = true;
  int held = 0;
  @override
  Future<KeylessCreateUndoProofLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  }) async {
    if (!known || !isCurrent()) return null;
    held++;
    return _ProviderFakeProofLease(this);
  }
}

final class _ProviderFakeProofLease implements KeylessCreateUndoProofLease {
  _ProviderFakeProofLease(this.port);
  final ProviderFakeProofPort port;
  bool released = false;
  @override
  bool get isCurrent => !released && port.current;
  @override
  bool get credentialAbsent => port.credentialAbsent;
  @override
  bool get referencesAbsent => port.referencesAbsent;
  @override
  void release() {
    if (released) throw StateError('Synthetic proof released twice.');
    released = true;
    port.held--;
  }
}
