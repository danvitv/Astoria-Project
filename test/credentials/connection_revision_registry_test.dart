import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

void main() {
  test(
    'native lifetime baselines positive, safe integer, independent; reads stable',
    () {
      final a = ConnectionRevisionRegistry();
      final b = ConnectionRevisionRegistry();
      expect(a.revision, inInclusiveRange(1, 9007199254740991));
      expect(b.revision, inInclusiveRange(1, 9007199254740991));
      expect(a.revision, isNot(b.revision));
      final version = a.revision;
      expect(a.isStable, isTrue);
      expect(a.revision, version);
    },
  );

  test('nested fences monotonic and settlement idempotent', () {
    final registry = ConnectionRevisionRegistry();
    final initial = registry.revision;
    final first = registry.beginMutation();
    final second = registry.beginMutation();
    expect(registry.revision, initial + 2);
    first();
    expect(registry.isStable, isFalse);
    first();
    expect(registry.revision, initial + 3);
    second();
    expect(registry.isStable, isTrue);
    expect(registry.revision, initial + 4);
  });

  test(
    'real repo put/delete/fromMap invalidate synchronously, get/getAll do not',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final registry = ConnectionRevisionRegistry();
      final observed = <String>[];
      final repo = ApiConfigRepo(
        db,
        onMutationStarted: registry.beginMutation,
        onConfigObserved: (config) => observed.add(config.id),
      );
      final initial = registry.revision;
      final write = repo.put(
        const ApiConfig(id: 'test', endpoint: 'example.com'),
      );
      expect(registry.revision, initial + 1);
      expect(registry.isStable, isFalse);
      expect(observed, ['test', 'test']);
      await write;
      expect(registry.revision, initial + 2);
      expect(registry.isStable, isTrue);
      await repo.getById('test');
      await repo.getAll();
      expect(registry.revision, initial + 2);
      final mapped = repo.putFromMap(const {
        'id': 'mapped',
        'providerId': 'openai',
        'protocol': 'openai',
      });
      expect(registry.revision, initial + 3);
      expect(registry.isStable, isFalse);
      await mapped;
      expect((await repo.getById('mapped'))?.id, 'mapped');
      final deletion = repo.delete('test');
      expect(registry.revision, initial + 5);
      expect(registry.isStable, isFalse);
      await deletion;
      expect(await repo.getById('test'), isNull);
      expect(registry.revision, initial + 6);
    },
  );

  test(
    'map decoding failure revokes before conversion; later writes still usable',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final registry = ConnectionRevisionRegistry();
      final repo = ApiConfigRepo(db, onMutationStarted: registry.beginMutation);
      final initial = registry.revision;
      final failed = repo.putFromMap(const {'id': 123});
      expect(registry.revision, greaterThan(initial));
      await expectLater(failed, throwsA(anything));
      expect(registry.isStable, isTrue);
      await repo.put(const ApiConfig(id: 'recovered'));
      expect(registry.isStable, isTrue);
    },
  );

  test(
    'failed native DB put/delete conservatively revoke and settle fences',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final registry = ConnectionRevisionRegistry();
      final repo = ApiConfigRepo(db, onMutationStarted: registry.beginMutation);
      await repo.put(const ApiConfig(id: 'seeded'));
      await db.close();
      final initial = registry.revision;
      final write = repo.put(const ApiConfig(id: 'failed'));
      expect(registry.revision, initial + 1);
      await expectLater(write, throwsA(anything));
      expect(registry.revision, initial + 2);
      expect(registry.isStable, isTrue);
      final deletion = repo.delete('seeded');
      expect(registry.revision, initial + 3);
      await expectLater(deletion, throwsA(anything));
      expect(registry.revision, initial + 4);
      expect(registry.isStable, isTrue);
    },
  );
}
