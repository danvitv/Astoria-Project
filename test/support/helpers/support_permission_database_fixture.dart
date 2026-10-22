import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';
import '../../credentials/fake_credential_storage.dart';
import 'support_permission_test_fixtures.dart';

// Real AEAD, fake key storage and only explicitly synthetic DB rows. No App,
// default database, environment, real credentials, catalog, HTTP or startup.
final class PermissionControlledCipher implements Cipher {
  final Cipher delegate = Xchacha20.poly1305Aead();
  Future<void> Function(String aad)? afterEncrypt, beforeDecrypt;
  @override
  List<int> newNonce() => delegate.newNonce();
  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final result = await delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await afterEncrypt?.call(utf8.decode(aad));
    return result;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    await beforeDecrypt?.call(utf8.decode(aad));
    return delegate.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class PermissionPausedRepo extends SupportRepo {
  PermissionPausedRepo(super.db, super.cipher);
  Completer<void>? entered, release;
  void pauseAdmission() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<SupportContextBlock?> mutateContextBlock({
    required String blockId,
    required String sessionId,
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  }) async {
    if (entered != null && !entered!.isCompleted) {
      entered!.complete();
      await release!.future;
    }
    return super.mutateContextBlock(
      blockId: blockId,
      sessionId: sessionId,
      mutate: mutate,
      isCurrent: isCurrent,
    );
  }
}

final class PermissionDatabaseFixture {
  PermissionDatabaseFixture() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      ),
      cipher: primitive,
    );
    repoA = PermissionPausedRepo(db, cipher);
    repoB = SupportRepo(db, cipher);
    a = SupportPermissionStore(repoA);
    b = SupportPermissionStore(repoB);
  }
  static const id = 'synthetic-support';
  static const codec = SupportPermissionCodec();
  final primitive = PermissionControlledCipher();
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final PermissionPausedRepo repoA;
  late final SupportRepo repoB;
  late final SupportPermissionStore a, b;
  static bool current() => true;
  Future<void> seed() async {
    await repoB.createSession(
      const SupportSession(
        id: id,
        title: 'SYNTHETIC_PERMISSION_CANARY title',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await repoB.appendMessage(
      const SupportMessage(
        id: 'synthetic-message',
        sessionId: id,
        role: 'user',
        body: 'SYNTHETIC_PERMISSION_CANARY history',
        cardsJson: '[]',
        createdAt: 2,
      ),
    );
    await repoB.putContextBlock(
      const SupportContextBlock(
        id: 'synthetic-unrelated-context',
        sessionId: id,
        startMessageId: 'synthetic-message',
        endMessageId: 'synthetic-message',
        summary: 'SYNTHETIC_PERMISSION_CANARY unrelated context',
        protectedFactsJson: '[]',
        createdAt: 3,
      ),
    );
    await repoB.putContextBlock(
      const SupportWorkspaceSettingsCodec().encode(
        id,
        const SupportAssistantSettings(
          temperature: 0.9,
          maxTokens: 4096,
          modelId: 'synthetic-generation-model',
        ),
        4,
        SecretRedactor(),
      ),
    );
    await b.selectScopeFromNative(id, permissionScope(), isCurrent: current);
    await b.selectRecipientFromNative(
      id,
      permissionRecipient(),
      isCurrent: current,
    );
  }

  Future<SupportContextBlockRow?> row() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(codec.idFor(id)))).getSingleOrNull();
  Future<Map<String, List<Object>>> preserved() async => {
    'history': await db.select(db.supportMessages).get(),
    'others': await (db.select(
      db.supportContextBlocks,
    )..where((t) => t.id.equals(codec.idFor(id)).not())).get(),
    'sessions': await db.select(db.supportSessions).get(),
  };
  Future<void> corrupt({bool unknownVersion = false}) async {
    final block = (await repoB.getContextBlockById(codec.idFor(id)))!;
    final m = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
    m['version'] = 999;
    await repoB.putContextBlock(
      block.copyWith(
        protectedFactsJson: unknownVersion
            ? jsonEncode(m)
            : 'synthetic-readable-corrupt',
      ),
    );
  }

  Future<void> close() => db.close();
}
