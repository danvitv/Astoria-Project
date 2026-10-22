import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import '../credentials/fake_credential_storage.dart';
import 'helpers/support_permission_test_fixtures.dart';

void main() {
  test(
    'synthetic permission ciphertext/identity/revision/grants survive focused file close/reopen',
    () async {
      // Owned unique synthetic directory in the workspace, never app data or env.
      final sandbox = await Directory(
        '.slim/deepwork/astoria-assistant',
      ).createTemp('synthetic-permission-reopen-');
      final file = File('${sandbox.path}/synthetic.sqlite');
      AppDatabase? current;
      addTearDown(() async {
        await current?.close();
        await sandbox.delete(recursive: true);
      });
      Future<SupportPermissionStore> reopen(
        FakeCredentialStorage storage,
      ) async {
        await current?.close();
        current = AppDatabase.forTesting(NativeDatabase(file));
        return SupportPermissionStore(
          SupportRepo(
            current!,
            SupportPayloadCipher(
              vault: CredentialVault(storage: storage, buildChannel: 'dev'),
            ),
          ),
        );
      }

      const id = 'synthetic-support';
      const codec = SupportPermissionCodec();
      final storage = FakeCredentialStorage();
      final first = await reopen(storage);
      await first.repo.createSession(
        const SupportSession(
          id: id,
          title: 'synthetic disk permissions',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await first.selectScopeFromNative(
        id,
        permissionScope(),
        isCurrent: () => true,
      );
      await first.selectRecipientFromNative(
        id,
        permissionRecipient(),
        isCurrent: () => true,
      );
      await first.setGrantFromNative(
        id,
        SupportPermission.modelGameHistory,
        true,
        isCurrent: () => true,
      );
      final expected = (await first.readForNative(id)).preferences!;
      final raw = await (current!.select(
        current!.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).getSingle();
      // Copy only fake backing values; no owner or cache survives reopen.
      final retained = FakeCredentialStorage()..values.addAll(storage.values);
      final second = await reopen(retained);
      final actual = (await second.readForNative(id)).preferences!;
      expect(actual.policyIdentity, expected.policyIdentity);
      expect(actual.revision, expected.revision);
      expect(actual.grants, expected.grants);
      expect(actual.scope!.sameAs(expected.scope), isTrue);
      expect(actual.recipient!.sameAs(expected.recipient), isTrue);
      final reopenedRaw = await (current!.select(
        current!.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).getSingle();
      expect(reopenedRaw, raw);
      expect(retained.operations, isNot(contains('write')));
      final sourceStorage = FakeCredentialStorage();
      final secondSetup = await reopen(sourceStorage);
      // Missing fake key is denied without rewriting any ciphertext.
      expect(
        (await secondSetup.readForNative(id)).availability,
        SupportPermissionAvailability.locked,
      );
      final lockedRaw = await (current!.select(
        current!.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).getSingle();
      expect(lockedRaw, raw);
      expect(sourceStorage.operations, isNot(contains('write')));
      expect(expected.allows(SupportPermission.modelGameHistory), isTrue);
    },
  );
}
