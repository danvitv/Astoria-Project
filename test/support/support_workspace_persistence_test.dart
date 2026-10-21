import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';

import '../credentials/fake_credential_storage.dart';

void main() {
  test(
    'fresh workspace adapter restores encrypted history and settings',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final vault = CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      );
      final repo = SupportRepo(db, SupportPayloadCipher(vault: vault));
      final redactor = SecretRedactor();
      final store = SupportWorkspaceStore(repo, () => redactor);
      final id = await store.create('Private workspace title');
      await store.appendUser(id, 'Private workspace message');
      await store.changeSettings(
        id,
        (s) => s.copyWith(
          apiConfigId: 'connection-1',
          modelId: 'model-1',
          temperature: 0.7,
        ),
      );
      await store.togglePin(id);

      final restored = await SupportWorkspaceStore(repo, () => redactor).load();
      expect(restored.sessions.single.title, 'Private workspace title');
      expect(restored.sessions.single.pinned, isTrue);
      expect(restored.messages[id]!.single.body, 'Private workspace message');
      expect(restored.settings[id]!.apiConfigId, 'connection-1');
      expect(restored.settings[id]!.temperature, 0.7);
      final rows = await db
          .customSelect('SELECT * FROM support_messages')
          .get();
      expect(
        rows.single.data.toString(),
        isNot(contains('Private workspace message')),
      );

      await store.changeSettings(
        id,
        (s) => s.copyWith(clearApiConfigId: true, clearModelId: true),
      );
      expect((await store.settingsFor(id)).apiConfigId, isNull);
      await repo.deleteSession(id);
      expect((await store.load()).sessions, isEmpty);
      expect(await repo.getMessagesForSession(id), isEmpty);
    },
  );
}
