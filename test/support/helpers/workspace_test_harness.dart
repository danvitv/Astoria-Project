import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import '../../credentials/fake_credential_storage.dart';

class WorkspaceGate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

/// Synthetic ports only; every persisted fake row and awaited stage is visible.
class ControlledWorkspaceStore extends SupportWorkspaceStore {
  ControlledWorkspaceStore(SupportRepo repo) : this._(repo, SecretRedactor());

  ControlledWorkspaceStore._(SupportRepo repo, SecretRedactor snapshot)
    : super(repo, () => snapshot) {
    addSession('a');
    addSession('b');
  }
  final sessions = <String, SupportSessionSummary>{};
  final messages = <String, List<SupportMessageItem>>{};
  final availability = <String, SupportSettingsAvailability>{};
  final gates = <String, WorkspaceGate>{};
  final failures = <String>{};
  final calls = <String>[];
  int nextId = 0;
  void addSession(String id) {
    sessions[id] = SupportSessionSummary(
      id: id,
      title: id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    messages[id] = [];
    availability[id] = SupportSettingsAvailability.available;
  }

  Future<void> stage(String name) async {
    calls.add(name);
    await gates[name]?.wait();
    if (failures.contains(name)) throw StateError('synthetic-secret-canary');
  }

  @override
  Future<SupportWorkspaceSnapshot> load() async {
    final snapshot = SupportWorkspaceSnapshot(
      List.unmodifiable(sessions.values),
      Map.unmodifiable(
        messages.map(
          (id, rows) =>
              MapEntry(id, List<SupportMessageItem>.unmodifiable(rows)),
        ),
      ),
      {
        for (final id in sessions.keys)
          if (availability[id] == SupportSettingsAvailability.available)
            id: const SupportAssistantSettings(),
      },
      Map.unmodifiable(availability),
    );
    await stage('load');
    return snapshot;
  }

  @override
  Future<String> create(String? title) async {
    await stage('create');
    final id = 'created-${++nextId}';
    addSession(id);
    return id;
  }

  @override
  Future<SupportAssistantSettings> settingsFor(String id) async {
    await stage('settings');
    if (!sessions.containsKey(id) ||
        availability[id] != SupportSettingsAvailability.available) {
      throw StateError('Unavailable');
    }
    return const SupportAssistantSettings();
  }

  @override
  Future<SupportMessageItem> appendUser(String id, String text) =>
      _appendControlledUser(id, text);

  @override
  Future<SupportMessageItem> appendNativeLocalUser(
    String id,
    String text, {
    required String runId,
    required bool Function() isCurrent,
  }) => _appendControlledUser(id, text, runId: runId, isCurrent: isCurrent);

  Future<SupportMessageItem> _appendControlledUser(
    String id,
    String text, {
    String? runId,
    bool Function()? isCurrent,
  }) async {
    await stage('user-before');
    if (isCurrent?.call() == false) throw StateError('Stale input');
    final user = SupportMessageItem(
      id: 'user-${++nextId}',
      sessionId: id,
      role: SupportMessageRole.user,
      body: text,
      runId: runId,
      createdAt: DateTime.utc(2026),
    );
    _commit(user);
    await stage('user-after');
    return user;
  }

  void _commit(SupportMessageItem item) {
    if (!sessions.containsKey(item.sessionId)) throw StateError('Deleted');
    messages[item.sessionId]!.add(item);
  }

  @override
  Future<SupportMessageItem> append(SupportMessageItem item) async {
    await stage('reply-before');
    _commit(item);
    await stage('reply-after');
    return item;
  }

  @override
  Future<SupportMessageItem> appendNativeLocalReply(
    SupportMessageItem item, {
    required SupportMessageItem originatingUser,
    required bool Function() isCurrent,
  }) async {
    // This fixture owns its in-memory rows, not actual SQLite parents. Keep the
    // new ports on that same backend; real origin/AAD atomicity is tested by the
    // session-model repository suites, never simulated here as database proof.
    await stage('reply-before');
    if (!isCurrent() ||
        originatingUser.runId == null ||
        originatingUser.role != SupportMessageRole.user ||
        item.role != SupportMessageRole.assistant ||
        item.sessionId != originatingUser.sessionId ||
        !(messages[item.sessionId]?.any(
              (row) =>
                  row.id == originatingUser.id &&
                  row.runId == originatingUser.runId,
            ) ??
            false)) {
      throw StateError('Stale origin');
    }
    final reply = SupportMessageItem(
      id: item.id,
      sessionId: item.sessionId,
      role: item.role,
      body: item.body,
      cards: item.cards,
      createdAt: item.createdAt,
      isLocked: item.isLocked,
      runId: originatingUser.runId,
      status: item.status,
    );
    _commit(reply);
    await stage('reply-after');
    return reply;
  }

  @override
  Future<void> deleteSession(String id) async {
    await stage('delete');
    sessions.remove(id);
    messages.remove(id);
    availability.remove(id);
  }

  @override
  Future<bool> deleteSessionIfMutationsSettled(
    String id, {
    bool Function()? isCurrent,
  }) async {
    // This notifier fixture owns synthetic in-memory parents, not repository
    // parents. Keep the new store admission API on the SAME declared backend;
    // actual SQLite mutation/deletion guards have their own repository suites.
    await stage('delete');
    if (isCurrent?.call() == false || !sessions.containsKey(id)) return false;
    sessions.remove(id);
    messages.remove(id);
    availability.remove(id);
    return true;
  }

  @override
  Future<void> rename(String id, String title) async {
    await stage('rename');
  }

  @override
  Future<void> changeSettings(
    String id,
    SupportAssistantSettings Function(SupportAssistantSettings) change, {
    bool Function()? isCurrent,
  }) async {
    await stage('change-before');
    if (isCurrent?.call() == false) return;
    calls.add('change-commit');
  }

  @override
  Future<void> recoverSettings(
    String id, {
    required bool confirmed,
    bool Function()? isCurrent,
  }) async {
    await stage('recover');
    if (isCurrent?.call() == false) return;
    if (!confirmed || availability[id] != SupportSettingsAvailability.corrupt) {
      throw StateError('Unavailable');
    }
    availability[id] = SupportSettingsAvailability.available;
  }
}

final _storeChoice = NotifierProvider<_StoreChoice, SupportWorkspaceStore>(
  () => throw UnimplementedError(),
);

class _StoreChoice extends Notifier<SupportWorkspaceStore> {
  _StoreChoice(this.initial);
  final SupportWorkspaceStore initial;
  @override
  SupportWorkspaceStore build() => initial;
  void replace(SupportWorkspaceStore value) => state = value;
}

class WorkspaceHarness {
  WorkspaceHarness({
    ControlledWorkspaceStore? store,
    Future<void> Function()? metadata,
    SupportNativeRuntime? native,
    AppDatabase? database,
    SupportRepo? repository,
  }) {
    db = database ?? AppDatabase.forTesting(NativeDatabase.memory());
    _ownsDatabase = database == null;
    repo =
        repository ??
        SupportRepo(
          db,
          SupportPayloadCipher(
            vault: CredentialVault(
              storage: FakeCredentialStorage(),
              buildChannel: 'dev',
            ),
          ),
        );
    this.store = store ?? ControlledWorkspaceStore(repo);
    container = ProviderContainer(
      overrides: [
        _storeChoice.overrideWith(() => _StoreChoice(this.store)),
        supportSessionStoreProvider.overrideWith(
          (ref) => ref.watch(_storeChoice),
        ),
        supportConnectionMetadataProvider.overrideWith((ref) async {
          await metadata?.call();
          return const [];
        }),
        supportNativeRuntimeProvider.overrideWith((ref) {
          ref.watch(_storeChoice); // Keep rebuild/lifetime isolation explicit.
          final runtime =
              native ??
              SupportNativeRuntime(
                permissions: SupportPermissionStore(repo),
                resolveRecipient: (_) async =>
                    const SupportRecipientUnavailable(
                      SupportRecipientUnavailableReason.selectionMissing,
                    ),
                loadSelectedConnection: (_, _) async =>
                    throw StateError('Denied loader invoked'),
                configurationRevision: () => 1,
                configurationStable: () => true,
              );
          ref.onDispose(runtime.dispose);
          return runtime;
        }),
      ],
    );
    subscription = container.listen(supportWorkspaceProvider, (_, _) {});
    notifier = container.read(supportWorkspaceProvider.notifier);
  }
  late final AppDatabase db;
  late final SupportRepo repo;
  late final bool _ownsDatabase;
  late final ProviderContainer container;
  late final ProviderSubscription<SupportWorkspaceState> subscription;
  late final SupportWorkspaceNotifier notifier;
  late final ControlledWorkspaceStore store;
  bool disposed = false;
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
      await container.pump();
    }
  }

  Future<void> replace(ControlledWorkspaceStore replacement) async {
    container.read(_storeChoice.notifier).replace(replacement);
    await settle();
  }

  Future<void> close() async {
    dispose();
    if (_ownsDatabase) await db.close();
  }

  void dispose() {
    if (!disposed) {
      disposed = true;
      container.dispose();
    }
  }
}
