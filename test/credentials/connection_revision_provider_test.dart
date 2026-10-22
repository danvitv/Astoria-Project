import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'fake_credential_storage.dart';

void main() {
  test(
    'production API repo composition uses the same stable native registry',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final storage = FakeCredentialStorage();
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          credentialStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final registry = container.read(connectionRevisionRegistryProvider);
      final repo = container.read(apiConfigRepoProvider);
      final before = registry.revision;
      final write = repo.put(
        const ApiConfig(
          id: 'synthetic-provider',
          endpoint: 'https://recipient.example/v1',
          apiKey: 'STATIC_PROVIDER_CANARY_986542',
        ),
      );
      expect(registry.revision, before + 1);
      expect(registry.isStable, isFalse);
      expect(
        container
            .read(secretRedactorProvider)
            .redactText('STATIC_PROVIDER_CANARY_986542'),
        '[REDACTED]',
      );
      await write;
      await repo.getById('synthetic-provider');
      await repo.getAll();
      expect(registry.revision, before + 2);
      expect(
        container.read(connectionRevisionRegistryProvider),
        same(registry),
      );
      final deletion = repo.delete('synthetic-provider');
      expect(registry.revision, before + 3);
      await deletion;
      expect(registry.isStable, isTrue);
      expect(storage.operations, isEmpty);
    },
  );
}
