import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import '../credentials/fake_credential_storage.dart';

class _SettingsRepo extends SupportRepo {
  _SettingsRepo(super.db, super.cipher);
  bool failRead = false, failWrite = false;
  @override
  Future<SupportContextBlock?> getContextBlockById(String id) {
    if (failRead) throw StateError('synthetic-secret-canary');
    return super.getContextBlockById(id);
  }

  @override
  Future<SupportContextBlock?> mutateContextBlock({
    required String blockId,
    required String sessionId,
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  }) {
    if (failRead || failWrite) throw StateError('synthetic-secret-canary');
    return super.mutateContextBlock(
      blockId: blockId,
      sessionId: sessionId,
      mutate: mutate,
      isCurrent: isCurrent,
    );
  }
}

void main() {
  late AppDatabase db;
  late _SettingsRepo repo;
  late SupportWorkspaceStore store;
  late String id;
  const codec = SupportWorkspaceSettingsCodec();
  final redactor = SecretRedactor();
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _SettingsRepo(
      db,
      SupportPayloadCipher(
        vault: CredentialVault(
          storage: FakeCredentialStorage(),
          buildChannel: 'dev',
        ),
      ),
    );
    store = SupportWorkspaceStore(repo, () => redactor);
    id = await store.create('Synthetic settings recovery');
    await store.appendUser(id, 'History must survive');
  });
  tearDown(() => db.close());

  Future<void> putMalformed(String payload, {String? summary}) =>
      repo.putContextBlock(
        codec
            .encode(id, const SupportAssistantSettings(), 1, redactor)
            .copyWith(protectedFactsJson: payload, summary: summary),
      );
  Future<String> bytes() async =>
      (await (db.select(
            db.supportContextBlocks,
          )..where((t) => t.id.equals(codec.idFor(id)))).getSingle())
          .protectedFactsCiphertext;

  final badPayloads = <String, String>{
    'malformed JSON': 'not-json synthetic-payload-canary',
    'unsupported version': '{"version":2}',
    'invalid enum': jsonEncode({
      'version': 1,
      'mode': 'not-a-mode',
      'temperature': 0.4,
      'maxTokens': 512,
    }),
    'out-of-range tokens': jsonEncode({
      'version': 1,
      'temperature': 0.4,
      'maxTokens': 999999,
    }),
    'out-of-range temperature': jsonEncode({
      'version': 1,
      'temperature': -1,
      'maxTokens': 512,
    }),
  };
  for (final bad in badPayloads.entries) {
    test(
      '${bad.key} stays encrypted/unavailable until confirmed recovery, retaining history',
      () async {
        await putMalformed(bad.value);
        final before = await bytes();
        expect(before, isNot(contains(bad.value)));
        final loaded = await store.load();
        expect(loaded.settings.containsKey(id), isFalse);
        expect(
          loaded.settingsAvailability[id],
          SupportSettingsAvailability.corrupt,
        );
        await expectLater(
          store.changeSettings(id, (s) => s.copyWith(temperature: 0.9)),
          throwsA(isA<SupportSettingsUnavailable>()),
        );
        await expectLater(
          store.recoverSettings(id, confirmed: false),
          throwsStateError,
        );
        expect(await bytes(), before);
        await store.recoverSettings(id, confirmed: true);
        final restored = await SupportWorkspaceStore(
          repo,
          () => redactor,
        ).load();
        expect(
          restored.settingsAvailability[id],
          SupportSettingsAvailability.available,
        );
        expect(restored.settings[id]!.temperature, 0.35);
        expect(restored.messages[id]!.single.body, 'History must survive');
        expect(await bytes(), isNot(before));
      },
    );
  }

  test(
    'read failure is explicitly unavailable, never defaults and never blind recovery',
    () async {
      await putMalformed('invalid-readable-payload');
      final before = await bytes();
      repo.failRead = true;
      final loaded = await store.load();
      expect(
        loaded.settingsAvailability[id],
        SupportSettingsAvailability.unavailable,
      );
      expect(loaded.settings.containsKey(id), isFalse);
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      expect(await bytes(), before);
    },
  );

  test(
    'failed recovery preserves encrypted malformed settings and subsequent successful retry repairs only preferences',
    () async {
      await putMalformed('invalid-readable-payload');
      final before = await bytes();
      repo.failWrite = true;
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      expect(await bytes(), before);
      expect(
        (await store.load()).settingsAvailability[id],
        SupportSettingsAvailability.corrupt,
      );
      repo.failWrite = false;
      await store.recoverSettings(id, confirmed: true);
      expect(
        (await store.load()).messages[id]!.single.body,
        'History must survive',
      );
    },
  );

  test(
    'locked context ciphertext is never overwritten by edits or confirmed recovery',
    () async {
      await putMalformed('invalid-readable-payload');
      await (db.update(
        db.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).write(
        const SupportContextBlocksCompanion(
          protectedFactsCiphertext: Value('synthetic-locked-envelope'),
        ),
      );
      final before = await bytes();
      final loaded = await store.load();
      expect(loaded.sessions.single.isLocked, isFalse);
      expect(
        loaded.settingsAvailability[id],
        SupportSettingsAvailability.locked,
      );
      expect(loaded.settings.containsKey(id), isFalse);
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsA(isA<SupportSettingsUnavailable>()),
      );
      await expectLater(
        store.changeSettings(id, (s) => s),
        throwsA(isA<SupportSettingsUnavailable>()),
      );
      expect(await bytes(), before);
    },
  );

  test(
    'locked parent, healthy preferences and missing preferences cannot be reset',
    () async {
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      await store.changeSettings(id, (s) => s.copyWith(temperature: 0.6));
      final before = await bytes();
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      expect(await bytes(), before);
      await (db.update(
        db.supportSessions,
      )..where((t) => t.id.equals(id))).write(
        const SupportSessionsCompanion(
          titleCiphertext: Value('synthetic-locked-parent'),
        ),
      );
      expect(
        (await store.load()).settingsAvailability[id],
        SupportSettingsAvailability.locked,
      );
      await expectLater(
        store.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      expect(await bytes(), before);
    },
  );

  test(
    'ownership lost during settings read prevents follow-up preference write',
    () async {
      var current = true;
      await store.changeSettings(id, (s) {
        current = false;
        return s.copyWith(temperature: 1);
      }, isCurrent: () => current);
      expect(await repo.getContextBlockById(codec.idFor(id)), isNull);
    },
  );
}
