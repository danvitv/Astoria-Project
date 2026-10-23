import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import '../../credentials/fake_credential_storage.dart';
import 'support_permission_database_fixture.dart';
import 'support_permission_test_fixtures.dart';

/// Actual native controller/store, declared-schema memory SQLite, real AEAD,
/// fake vault. No App/default database/bootstrap/provider or visual dependency.
final class ExactHistoryConsentFixture {
  ExactHistoryConsentFixture() {
    db = _ConsentMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'native_consent_test',
      ),
      cipher: primitive,
    );
    repo = PermissionPausedRepo(db, cipher);
    permissions = SupportPermissionStore(repo);
    otherPermissions = SupportPermissionStore(PermissionPausedRepo(db, cipher));
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (_) async {
        recipientReads++;
        if (!recipientAvailable) {
          return const SupportRecipientUnavailable(
            SupportRecipientUnavailableReason.selectionMissing,
          );
        }
        return SupportResolvedRecipient(
          context: runtime.recipientContext!,
          recipient: permissionRecipient(),
          connectionLabel: 'Synthetic connection',
          protocolLabel: 'OpenAI',
          routingLabel: 'Direct',
          originLabel: 'https · synthetic.invalid',
          operationLabel: 'Chat completions',
        );
      },
      loadSelectedConnection: (_, _) async {
        connectionLoads++;
        throw StateError('Consent must not load connection data');
      },
      configurationRevision: () => revisions.revision,
      configurationStable: () => revisions.isStable,
    );
    final selector = SupportConsentSelectionRepo(
      db: db,
      supportRepo: repo,
      currentRedactor: SecretRedactor.new,
    );
    controller = SupportNativeConsentController(
      runtime: runtime,
      readMessages: (source, id, offset) {
        metadataReads++;
        return selector.listRoleplayMessages(sessionId: id, offset: offset);
      },
    );
  }

  static const id = 'synthetic-exact-consent';
  static const gameId = 'synthetic-game';
  static const bodyCanary = 'EXACT_CONSENT_BODY_NEVER_LOADED_62da';
  static const codec = SupportPermissionCodec();
  final sql = ConsentSqlProbe();
  final storage = FakeCredentialStorage();
  final primitive = PermissionControlledCipher();
  final revisions = ConnectionRevisionRegistry();
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final PermissionPausedRepo repo;
  late final SupportPermissionStore permissions, otherPermissions;
  late final SupportNativeRuntime runtime;
  late final SupportNativeConsentController controller;
  int recipientReads = 0, metadataReads = 0, connectionLoads = 0;
  bool recipientAvailable = false;

  static SupportPermissionScope exactScope({
    int revision = 1,
    bool companions = false,
    Map<SupportDataCategory, Iterable<String>> selectedData = const {},
  }) => SupportPermissionScope(
    selectionRevision: revision,
    gameSessionId: gameId,
    gameHistory: SupportMessageSelection(['game-a', 'game-c']),
    supportHistory: companions ? SupportMessageSelection(['support-a']) : null,
    safeCategories: companions ? [SupportSafeCategory.connections] : const [],
    selectedData: selectedData,
  );

  Future<void> seed({SupportPermissionScope? scope}) async {
    await repo.createSession(
      const SupportSession(
        id: id,
        title: 'Synthetic',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await repo.appendMessage(
      const SupportMessage(
        id: 'support-a',
        sessionId: id,
        role: 'user',
        body: bodyCanary,
        cardsJson: '[]',
        createdAt: 2,
      ),
    );
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-character',
            name: 'Synthetic',
          ),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: gameId,
            characterId: 'synthetic-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              for (final message in ['game-a', 'game-b', 'game-c'])
                {'id': message, 'role': 'user', 'content': bodyCanary},
            ]),
          ),
        );
    await replacePolicy(scope: scope);
    runtime.selectSession(id);
    await runtime.refresh();
    sql.observe();
  }

  Future<void> replacePolicy({
    SupportPermissionScope? scope,
    String identity = 'synthetic-exact-policy',
    SupportPermissionRecipient? recipient,
  }) => repo.putContextBlock(
    codec.encode(
      SupportPermissionPreferences(
        supportSessionId: id,
        policyIdentity: identity,
        revision: 1,
        scope: scope,
        recipient: recipient,
      ),
      1,
    ),
  );

  Future<SupportPermissionPreferences> policy() async =>
      (await otherPermissions.readForNative(id)).preferences!;

  Future<SupportContextBlockRow?> row() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(codec.idFor(id)))).getSingleOrNull();

  Future<void> close() async {
    runtime.dispose();
    revisions.dispose();
    await db.close();
  }
}

/// A flat onCreate is deliberate: never run the default app's startup seeding.
final class _ConsentMemoryDatabase extends AppDatabase {
  _ConsentMemoryDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

/// Observes the real SQLite boundary across review/toggle/selection/cleanup.
/// Attempts remain recorded even if a production caller swallows an exception.
final class ConsentSqlProbe extends QueryInterceptor {
  bool observing = false;
  final gameReads = <String>[];
  final forbiddenReads = <String>[];
  void observe() {
    gameReads.clear();
    forbiddenReads.clear();
    observing = true;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (!observing) return rows;
    if (statement.toLowerCase().contains('chat_sessions')) {
      gameReads.add(statement);
    }
    const bodyColumns = {
      'messages_json',
      'body',
      'body_ciphertext',
      'cards_json',
      'cards_ciphertext',
      'description',
      'extensions_json',
      'session_vars_json',
      'authors_note_json',
    };
    final lower = statement.toLowerCase();
    if (lower.contains('support_messages') ||
        lower.contains('api_configs') ||
        rows.any((r) => r.keys.any(bodyColumns.contains))) {
      forbiddenReads.add(statement);
      throw StateError(
        'Consent attempted to load history or world-data bodies',
      );
    }
    return rows;
  }
}
