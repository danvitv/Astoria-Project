import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/backup/backup_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';
import 'package:path/path.dart' as p;

import '../credentials/fake_credential_storage.dart';
import 'import_fence_fixture.dart';
import 'import_fence_support_fixture.dart';

void main() {
  late ImportFenceFixture f;
  late FakeCredentialStorage storage;
  late SecretRedactionCoordinator redaction;
  late Completer<ImportFenceImages> imageReady;
  late ProviderContainer container;

  setUp(() async {
    f = await ImportFenceFixture.create();
    storage = FakeCredentialStorage();
    redaction = SecretRedactionCoordinator();
    imageReady = Completer<ImportFenceImages>();
    // All native DB/image/credential/source ports replaced BEFORE evaluation.
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(f.db),
        imageStorageProvider.overrideWith((ref) => imageReady.future),
        credentialStorageProvider.overrideWithValue(storage),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    redaction.dispose();
    await f.close();
  });

  test(
    'production backup captures registry before image await; API repo shares it',
    () async {
      expect(container.exists(connectionRevisionRegistryProvider), isFalse);
      final ready = container.read(backupServiceProvider.future);
      expect(container.exists(connectionRevisionRegistryProvider), isTrue);
      final revisions = container.read(connectionRevisionRegistryProvider);
      final initial = revisions.revision;
      expect(revisions.isStable, isTrue);
      imageReady.complete(f.images);
      final service = await ready;
      final path = await f.zip();
      final import = service.importBackupFromFile(path);
      expect(revisions.revision, initial + 1);
      expect(revisions.isStable, isFalse);
      final repo = container.read(apiConfigRepoProvider);
      final write = repo.put(const ApiConfig(id: 'nested-config'));
      expect(revisions.revision, initial + 2);
      await Future.wait([import, write]);
      expect(revisions.revision, initial + 4);
      expect(revisions.isStable, isTrue);
      await repo.getById('nested-config');
      await repo.getAll();
      expect(revisions.revision, initial + 4);
      expect(
        container.read(connectionRevisionRegistryProvider),
        same(revisions),
      );
      expect(storage.operations, isEmpty);
    },
  );

  test(
    'normal exporter ZIP original-changed-original never recreates old native binding',
    () async {
      imageReady.complete(f.images);
      final service = await container.read(backupServiceProvider.future);
      final revisions = container.read(connectionRevisionRegistryProvider);
      final repo = container.read(apiConfigRepoProvider);
      const original = ApiConfig(
        id: 'synthetic-api',
        name: 'Synthetic connection',
        endpoint: 'https://original.example/v1/chat/completions',
        apiKey: 'STATIC_IMPORT_CANARY_598431',
        model: 'selected-model',
      );
      final changed = original.copyWith(
        endpoint: 'https://changed.example/v1/chat/completions',
      );
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      final sourceRepo = ApiConfigRepo(source);
      await source.customStatement(
        'INSERT INTO characters (char_id, name) VALUES (?, ?)',
        ['imported-character', 'Synthetic imported character'],
      );
      final exporter = BackupExporter(source, f.images);
      Future<File> archive(String name, ApiConfig config) async {
        await sourceRepo.put(config);
        final directory = await Directory(
          p.join(f.directory.path, name),
        ).create();
        return exporter.buildArchive(directory, includeApiKeys: true);
      }

      final originalZip = await archive('original', original);
      final changedZip = await archive('changed', changed);
      final support = await seedImportFenceSupport(f.db);
      final localBefore = await importFenceSupportSnapshot(f.db);
      await repo.put(original);
      var settingsReads = 0;
      final resolver = SupportRecipientResolver(
        apiRepo: repo,
        readSettings: (id) async {
          settingsReads++;
          return id == 'local-support'
              ? const SupportAssistantSettings(
                  apiConfigId: 'synthetic-api',
                  modelId: 'selected-model',
                )
              : null;
        },
        currentContext: () => const SupportRecipientContext(
          supportSessionId: 'local-support',
          epoch: 1,
        ),
        revisions: revisions,
        redactor: () => redaction.redactor,
      );
      final before =
          await resolver.resolve('local-support') as SupportResolvedRecipient;
      final initial = revisions.revision;
      for (final zip in [changedZip, originalZip]) {
        final reads = settingsReads;
        final pending = service.importBackupFromFile(zip.path);
        expect(revisions.isStable, isFalse);
        final denied =
            await resolver.resolve('local-support')
                as SupportRecipientUnavailable;
        expect(
          denied.reason,
          SupportRecipientUnavailableReason.mutationPending,
        );
        expect(settingsReads, reads);
        await pending;
        expect(revisions.isStable, isTrue);
        final current =
            await resolver.resolve('local-support') as SupportResolvedRecipient;
        expect(current.recipient.sameAs(before.recipient), isFalse);
        expect(
          current.recipient.configurationRevision,
          greaterThan(before.recipient.configurationRevision),
        );
      }
      final after =
          await resolver.resolve('local-support') as SupportResolvedRecipient;
      expect(after.recipient.nativeRoute, before.recipient.nativeRoute);
      expect(revisions.revision, initial + 4);
      expect((await repo.getById(original.id))?.apiKey, original.apiKey);
      expect(
        (await f.db.select(f.db.characters).get()).single.name,
        'Synthetic imported character',
      );
      expect(await importFenceSupportSnapshot(f.db), localBefore);
      expect(
        (await support.getMessageById('local-message'))?.body,
        'STATIC_LOCAL_ENCRYPTED_BODY_318549',
      );
      expect(storage.operations, isEmpty);
    },
  );

  test(
    'container disposal during admitted import permanently closes old native registry',
    () async {
      imageReady.complete(f.images);
      final service = await container.read(backupServiceProvider.future);
      final revisions = container.read(connectionRevisionRegistryProvider);
      final path = await f.zip();
      final entered = Completer<void>();
      final release = Completer<void>();
      f.db.beforePurge = () {
        entered.complete();
        return release.future;
      };
      var notifications = 0;
      revisions.subscribe(() => notifications++);
      final pending = service.importBackupFromFile(path);
      await entered.future;
      final pendingRevision = revisions.revision;
      container.dispose();
      expect(revisions.isStable, isFalse);
      expect(notifications, 2);
      release.complete();
      await pending;
      expect(revisions.isStable, isFalse);
      expect(revisions.revision, pendingRevision + 2);
      expect(notifications, 2);
    },
  );

  test(
    'crafted support table entries remain ignored under outer import fence',
    () async {
      imageReady.complete(f.images);
      final service = await container.read(backupServiceProvider.future);
      await seedImportFenceSupport(f.db);
      final before = await importFenceSupportSnapshot(f.db);
      final path = await f.zip(
        tables: {
          for (final table in importFenceSupportTables)
            table: [
              {'malicious': 'overwrite'},
            ],
          'characters': [
            {'char_id': 'ordinary', 'name': 'Ordinary import'},
          ],
          'api_configs': [
            {
              'config_id': 'ordinary-api',
              'name': 'Ordinary connection',
              'endpoint': 'https://ordinary.example/v1',
              'model': 'synthetic-model',
            },
          ],
        },
      );
      final revisions = container.read(connectionRevisionRegistryProvider);
      final initial = revisions.revision;
      await service.importBackupFromFile(path);
      expect(revisions.revision, initial + 2);
      expect(revisions.isStable, isTrue);
      expect(await importFenceSupportSnapshot(f.db), before);
      expect(
        (await f.db.select(f.db.characters).get()).single.name,
        'Ordinary import',
      );
      final config = await container
          .read(apiConfigRepoProvider)
          .getById('ordinary-api');
      expect(config?.endpoint, 'https://ordinary.example/v1/chat/completions');
      expect(config?.model, 'synthetic-model');
      expect(storage.operations, isEmpty);
    },
  );
}
