import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';

import '../credentials/fake_credential_storage.dart';
import 'helpers/support_native_input_fixture.dart' show NativeInputCipher;
import 'support_theme_consent_isolation.dart';

/// Actual native controller/runtime/reviewed store, owned declared-schema memory
/// SQLite, FakeVault and real AEAD. No theme owner, App, prefs, model or defaults.
final class ThemeConsentFixture {
  ThemeConsentFixture(this.isolation) {
    db = _ThemeConsentDatabase(NativeDatabase.memory().interceptWith(sql));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'theme_consent_test',
      ),
      cipher: primitive,
    );
    repo = SupportRepo(db, cipher);
    permissions = SupportPermissionStore(
      repo,
      newIdentity: () => 'local-policy',
    );
    otherPermissions = SupportPermissionStore(SupportRepo(db, cipher));
    final api = _ThemeConsentApi(db, this);
    final resolver = SupportRecipientResolver(
      apiRepo: api,
      readSettings: (_) async {
        settingsReads++;
        if (!allowResolver) isolation.block('recipient settings read');
        return recipientSettings;
      },
      currentContext: () => runtime.recipientContext,
      revisions: revisions,
      redactor: SecretRedactor.new,
    );
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (id) {
        resolverReads++;
        if (!allowResolver) isolation.block('recipient resolver');
        return resolver.resolve(id);
      },
      loadSelectedConnection: (_, _) async =>
          isolation.block('connection metadata read'),
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
        if (!allowMetadata) {
          isolation.block('unrequested selection metadata read');
        }
        return source == SupportConsentSelectionSource.support
            ? selector.listSupportMessages(sessionId: id, offset: offset)
            : selector.listRoleplayMessages(sessionId: id, offset: offset);
      },
    );
    primitive.beforeDecrypt = (aad) async {
      if (observing &&
          !aad.contains('support_sessions|$id|') &&
          !aad.contains('support_context_blocks|${codec.idFor(id)}|')) {
        isolation.block('unselected/body/settings decrypt');
      }
      await beforeDecrypt?.call(aad);
    };
    sql.metadataAllowed = () => allowMetadata;
  }

  static const id = 'synthetic-theme-consent';
  static const bodyCanary = 'SYNTHETIC_THEME_CONSENT_UNSELECTED_BODY_8aa1';
  static const codec = SupportPermissionCodec();
  final ThemeConsentIsolation isolation;
  final sql = ThemeConsentSql();
  final primitive = NativeInputCipher();
  final storage = FakeCredentialStorage();
  final revisions = ConnectionRevisionRegistry();
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final SupportPermissionStore permissions, otherPermissions;
  late final SupportNativeRuntime runtime;
  late final SupportNativeConsentController controller;
  bool observing = false, allowResolver = false, allowMetadata = false;
  int resolverReads = 0, settingsReads = 0, apiReads = 0, metadataReads = 0;
  SupportAssistantSettings recipientSettings = const SupportAssistantSettings(
    apiConfigId: 'synthetic-connection',
    modelId: 'synthetic-model',
  );
  Future<void> Function(String aad)? beforeDecrypt;

  static SupportPermissionScope scope({
    int revision = 1,
    Iterable<SupportSafeCategory> categories = const [
      SupportSafeCategory.theme,
    ],
    bool histories = false,
    Map<SupportDataCategory, Iterable<String>> selectedData = const {},
  }) => SupportPermissionScope(
    selectionRevision: revision,
    safeCategories: categories,
    gameSessionId: histories || selectedData.isNotEmpty
        ? 'synthetic-game'
        : null,
    gameHistory: histories
        ? SupportMessageSelection(['game-a', 'game-c'])
        : null,
    supportHistory: histories ? SupportMessageSelection(['support-a']) : null,
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
    for (var index = 0; index < 3; index++) {
      await repo.appendMessage(
        SupportMessage(
          id: 'support-${['a', 'b', 'c'][index]}',
          sessionId: id,
          role: 'user',
          body: bodyCanary,
          cardsJson: '[]',
          createdAt: index + 2,
        ),
      );
    }
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
            sessionId: 'synthetic-game',
            characterId: 'synthetic-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              for (final letter in ['a', 'b', 'c'])
                {'id': 'game-$letter', 'role': 'user', 'content': bodyCanary},
            ]),
          ),
        );
    await replacePolicy(scope: scope);
    runtime.selectSession(id);
    await runtime.refresh();
    observing = true;
    sql.observe(isolation.block);
    primitive.decryptAads.clear();
    primitive.encryptAads.clear();
  }

  Future<void> replacePolicy({
    SupportPermissionScope? scope,
    String identity = 'synthetic-theme-policy',
    SupportPermissionRecipient? recipient,
    Iterable<SupportPermission> grants = const [],
  }) => repo.putContextBlock(
    codec.encode(
      SupportPermissionPreferences(
        supportSessionId: id,
        policyIdentity: identity,
        revision: 1,
        scope: scope,
        recipient: recipient,
        grants: grants,
      ),
      1,
    ),
  );

  Future<SupportNativeReview> review() async => (await controller.prepareReview(
    displayedIntent: controller.view.displayedIntent,
    resolveRecipient: false,
  ))!;

  Future<SupportPermissionPreferences> policy() async =>
      (await otherPermissions.readForNative(id)).preferences!;

  Future<SupportContextBlockRow?> row() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(codec.idFor(id)))).getSingleOrNull();

  Future<void> close() async {
    controller.invalidateDisplayedIntents();
    runtime.dispose();
    revisions.dispose();
    await db.close();
  }
}

final class _ThemeConsentDatabase extends AppDatabase {
  _ThemeConsentDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

/// The real resolver receives synthetic data ONLY when a test explicitly opts in.
final class _ThemeConsentApi extends ApiConfigRepo {
  _ThemeConsentApi(super.db, this.fixture);
  final ThemeConsentFixture fixture;
  @override
  Future<ApiConfig?> getById(String id) async {
    fixture.apiReads++;
    if (!fixture.allowResolver) fixture.isolation.block('API read');
    return const ApiConfig(
      id: 'synthetic-connection',
      name: 'Synthetic connection',
      endpoint: 'https://synthetic.invalid/v1/chat/completions',
      model: 'synthetic-model',
    );
  }
}

/// Records attempts BEFORE query evaluation; explicit metadata-only paging is
/// allowed, but no body/card/connection/whole-world data may enter the runtime.
final class ThemeConsentSql extends QueryInterceptor {
  Never Function(String)? _block;
  final reads = <String>[];
  final writes = <String>[];
  Future<void> Function(String statement, List<Object?> args)? afterSelect;
  bool Function()? metadataAllowed;

  void observe(Never Function(String) block) => _block = block;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_block != null) {
      reads.add(statement);
      final lower = statement.toLowerCase();
      final history =
          lower.contains('chat_sessions') || lower.contains('support_messages');
      if (lower.contains('api_configs') ||
          (history && metadataAllowed?.call() != true) ||
          (history &&
              (RegExp(r'\bselect\s+(?:\w+\.)?\*').hasMatch(lower) ||
                  RegExp(
                    r'\b(body|body_ciphertext|cards_json|cards_ciphertext|description|extensions_json|session_vars_json|authors_note_json)\b',
                  ).hasMatch(lower)))) {
        _block!('body/world/API SQL read');
      }
      if (lower.contains('support_context_blocks') &&
          !args.contains(
            ThemeConsentFixture.codec.idFor(ThemeConsentFixture.id),
          )) {
        _block!('unselected/settings context SQL read');
      }
    }
    final result = await super.runSelect(executor, statement, args);
    if (_block != null &&
        result.any(
          (row) => row.keys.any(
            {
              'body',
              'body_ciphertext',
              'cards_json',
              'cards_ciphertext',
              'messages_json',
              'description',
              'extensions_json',
              'session_vars_json',
              'authors_note_json',
            }.contains,
          ),
        )) {
      _block!('body/world SQL mapped return');
    }
    await afterSelect?.call(statement, args);
    return result;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_block != null) writes.add(statement);
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_block != null) writes.add(statement);
    return super.runUpdate(executor, statement, args);
  }
}

void themeConsentTest(
  String name,
  Future<void> Function(ThemeConsentFixture) body, {
  SupportPermissionScope? scope,
}) {
  test(name, () async {
    final isolation = ThemeConsentIsolation();
    await isolation.run(() async {
      final fixture = ThemeConsentFixture(isolation);
      Object? failure;
      StackTrace? trace;
      try {
        await fixture.seed(scope: scope);
        await body(fixture);
      } catch (error, stack) {
        failure = error;
        trace = stack;
      } finally {
        try {
          await fixture.close();
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
      expect(
        fixture.sql.writes.where(
          (sql) =>
              sql.contains('support_mutation') ||
              sql.contains('support_report'),
        ),
        isEmpty,
      );
    });
  });
}
