import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/state/native_provider_runtime.dart';

import 'native_provider_fixture.dart';

/// Actual repository/runtime with a single declared memory DB and fake vault.
/// No platform graph, preferences, files, migration or network adapter exists.
final class _OrdinaryFixture {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final storage = NativeProviderFakeStorage();
  final revisions = ConnectionRevisionRegistry();
  final redaction = SecretRedactionCoordinator();
  bool current = true;
  late final vault = CredentialVault(storage: storage, buildChannel: 'dev');
  late final adapter = ApiConfigCredentialAdapter(
    vault: vault,
    redactionCoordinator: redaction,
  );
  late final NativeProviderRuntime runtime = NativeProviderRuntime(
    vault: vault,
    redaction: redaction,
    revisions: revisions,
    readSavedConnection: (id) => api.getById(id),
    adapterFactory: () => throw StateError('SYNTHETIC_NETWORK_FORBIDDEN'),
    isOriginalRoot: () => current,
  );
  late final api = ApiConfigRepo(
    db,
    onConfigObserved: adapter.registerConfigSecrets,
    onMutationStarted: runtime.onApiMutationStarted,
    keylessMutations: runtime.keylessMutations,
    ordinaryMutations: runtime.ordinaryMutations,
  );
  static const row = ApiConfig(
    id: 'ordinary-compatibility',
    name: 'Synthetic ordinary connection',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    model: 'synthetic-model',
  );

  Future<void> close() async {
    current = false;
    runtime.dispose();
    revisions.dispose();
    redaction.dispose();
    await db.close();
  }
}

void main() {
  late _OrdinaryFixture f;
  setUp(() => f = _OrdinaryFixture());
  tearDown(() => f.close());

  test(
    'raw put/map secrets register synchronously, including denied input',
    () async {
      const direct = 'plainordinarydirect998877';
      const nested = 'plainordinarynested776655';
      const embedding = 'plainordinaryembedding554433';
      const extra = 'plainordinaryextra332211';
      final row = _OrdinaryFixture.row.copyWith(
        apiKey: direct,
        embeddingApiKey: embedding,
        extraRequestParameters: const [
          ExtraRequestParameter(key: 'x_custom_secret', value: extra),
          ExtraRequestParameter(
            key: 'provider_options',
            value: '{"nested":{"api_key":"$nested"}}',
          ),
        ],
      );
      final put = f.api.put(row);
      for (final secret in [direct, nested, embedding, extra]) {
        expect(
          f.redaction.redactor.redactText(secret),
          isNot(contains(secret)),
        );
      }
      await put;
      expect((await f.api.getById(row.id))!.apiKey, direct);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);

      const mapCanary = 'plainordinarymap221100';
      final mapped = row.copyWith(id: 'ordinary-map', apiKey: mapCanary);
      final mapPut = f.api.putFromMap(
        jsonDecode(jsonEncode(mapped.toJson())) as Map<String, dynamic>,
      );
      expect(
        f.redaction.redactor.redactText(mapCanary),
        isNot(contains(mapCanary)),
      );
      await mapPut;

      f.current = false;
      f.runtime.dispose();
      const deniedCanary = 'plainordinarydenied110099';
      final denied = f.api.put(row.copyWith(apiKey: deniedCanary));
      expect(
        f.redaction.redactor.redactText(deniedCanary),
        isNot(contains(deniedCanary)),
      );
      await expectLater(denied, throwsA(isA<KeylessApiConfigException>()));
      expect((await f.api.getById(row.id))!.apiKey, direct);
    },
  );

  test(
    'fresh and observed ordinary puts own exactly one synchronous registry fence',
    () async {
      for (final model in ['synthetic-model', 'changed-model']) {
        final revision = f.revisions.revision;
        final edit = f.api.put(_OrdinaryFixture.row.copyWith(model: model));
        expect(f.revisions.revision, revision + 1);
        expect(f.revisions.isStable, isFalse);
        await edit;
        expect(f.revisions.revision, revision + 2);
        expect(f.revisions.isStable, isTrue);
      }
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'observed ordinary write finishes on original DB after native retirement without credential reads',
    () async {
      final original = _OrdinaryFixture.row.copyWith(
        apiKey: 'LEGACY_SYNTHETIC_KEY',
      );
      await f.api.put(original);
      final reads = f.storage.readKeys.length;
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = f.db.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final importFence = f.runtime.onApiMutationStarted();
      final edit = f.api.put(original.copyWith(model: 'after-retirement'));
      f.current = false;
      f.runtime.dispose();
      f.revisions.dispose();
      expect(f.runtime.mutations.observe(), isNull);
      expect(f.runtime.keylessMutations.revisionFor(original.id), isNull);
      release.complete();
      await blocker;
      importFence();
      await edit;
      expect((await f.api.getById(original.id))!.model, 'after-retirement');
      expect(f.storage.readKeys.length, reads);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
      expect(f.revisions.isStable, isFalse);
    },
  );

  test(
    'unknown IDs never inherit observed ordinary absence during an import fence',
    () async {
      await f.api.put(_OrdinaryFixture.row);
      final reads = f.storage.readKeys.length;
      final finish = f.runtime.onApiMutationStarted();
      final denied = f.api.put(_OrdinaryFixture.row.copyWith(id: 'unknown-id'));
      await expectLater(denied, throwsA(isA<KeylessApiConfigException>()));
      finish();
      expect(await f.api.getById('unknown-id'), isNull);
      expect(f.storage.readKeys.length, reads);
      expect(f.storage.writeKeys, isEmpty);
    },
  );

  test(
    'even a rejected native preparation attempt revokes queued ordinary custody synchronously',
    () async {
      await f.api.put(_OrdinaryFixture.row);
      late NativeConnectionOperationLease closed;
      final admission = f.runtime.mutations.admit(
        expected: f.runtime.mutations.observe()!,
        isOriginalOwner: () => true,
      )!;
      await f.runtime.mutations.runOwned<void>(
        admission: admission,
        operation: (lease) async {
          closed = lease;
        },
      );
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = f.db.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final edit = f.api.put(
        _OrdinaryFixture.row.copyWith(model: 'must-not-save'),
      );
      final rejected = expectLater(
        edit,
        throwsA(isA<KeylessApiConfigException>()),
      );
      final attempt = f.runtime.credentials.markPreparedForNativeCreate(
        lease: closed,
        connectionId: _OrdinaryFixture.row.id,
      );
      expect(
        f.runtime.credentials.observedOrdinaryAbsence(_OrdinaryFixture.row.id),
        isNull,
      );
      await expectLater(attempt, throwsNative(NativeProviderFailure.stale));
      release.complete();
      await blocker;
      await rejected;
      expect(
        (await f.api.getById(_OrdinaryFixture.row.id))!.model,
        'synthetic-model',
      );
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
      expect(f.revisions.isStable, isTrue);
    },
  );

  test(
    'native entry revokes absence before admission and still protects the actual saved row',
    () async {
      await f.api.put(_OrdinaryFixture.row);
      final lifetime = NativeProviderViewLifetime(isCurrent: () => f.current);
      final review = await f.runtime.secretEntry.review(
        connection: f.runtime.auth.referenceFor(
          _OrdinaryFixture.row,
          NativeProviderPurpose.roleplay,
        )!,
        purposes: const {NativeProviderPurpose.roleplay},
        lifetime: lifetime,
      );
      final permit = f.runtime.secretEntry.confirmNativeEntry(review);
      final store = f.runtime.credentials.storeFromNativeEntry(
        permit: permit,
        secret: nativeCanary,
      );
      expect(
        f.runtime.credentials.observedOrdinaryAbsence(_OrdinaryFixture.row.id),
        isNull,
      );
      await store;
      final reads = f.storage.readKeys.length;
      final forbidden = _OrdinaryFixture.row.copyWith(
        apiKey: 'ROW_KEY_FORBIDDEN',
      );
      await expectLater(
        f.api.put(forbidden),
        throwsA(isA<KeylessApiConfigException>()),
      );
      expect((await f.api.getById(_OrdinaryFixture.row.id))!.apiKey, isEmpty);
      expect(f.storage.readKeys.length, greaterThan(reads));
      expect(f.storage.writeKeys.length, 1);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'fresh presence read failure revokes old ordinary fact, never guesses absence',
    () async {
      await f.api.put(_OrdinaryFixture.row);
      f.storage.readError = StateError('SYNTHETIC_UNAVAILABLE');
      expect(
        await f.runtime.credentials.inspectNativePresence(
          connectionId: _OrdinaryFixture.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.unavailable,
      );
      expect(
        f.runtime.credentials.observedOrdinaryAbsence(_OrdinaryFixture.row.id),
        isNull,
      );
      await expectLater(
        f.api.put(_OrdinaryFixture.row.copyWith(model: 'must-not-save')),
        throwsA(isA<KeylessApiConfigException>()),
      );
      expect(
        (await f.api.getById(_OrdinaryFixture.row.id))!.model,
        'synthetic-model',
      );
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'replacement native wrapper shares invalidation, never another owners ordinary fact',
    () async {
      await f.api.put(_OrdinaryFixture.row);
      final original = f.runtime.credentials.observedOrdinaryAbsence(
        _OrdinaryFixture.row.id,
      );
      expect(original, isNotNull);
      final mutations = NativeConnectionMutationOwner(redaction: f.redaction);
      final credentials = NativeProviderCredentialVault(
        vault: f.vault,
        redaction: f.redaction,
        mutations: mutations,
        routePolicy: NativeProviderRoutePolicy(redaction: f.redaction),
      );
      expect(
        credentials.observedOrdinaryAbsence(_OrdinaryFixture.row.id),
        isNull,
      );
      late NativeConnectionOperationLease closed;
      await mutations.runOwned<void>(
        admission: mutations.admit(
          expected: mutations.observe()!,
          isOriginalOwner: () => true,
        )!,
        operation: (lease) async {
          closed = lease;
        },
      );
      final reads = f.storage.readKeys.length;
      final attempt = credentials.markPreparedForNativeCreate(
        lease: closed,
        connectionId: _OrdinaryFixture.row.id,
      );
      expect(
        f.runtime.credentials.isObservedOrdinaryAbsence(
          original,
          _OrdinaryFixture.row.id,
        ),
        isFalse,
      );
      await expectLater(attempt, throwsNative(NativeProviderFailure.stale));
      mutations.dispose();
      expect(f.storage.readKeys.length, reads);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'competing outer observer settles both fences when it outlives a native operation',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final revision = f.revisions.revision;
      final native = f.runtime.mutations.runOwned<void>(
        admission: f.runtime.mutations.admit(
          expected: f.runtime.mutations.observe()!,
          isOriginalOwner: () => true,
        )!,
        operation: (_) async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      expect(f.revisions.revision, revision + 1);
      final finish = f.runtime.onApiMutationStarted();
      expect(f.revisions.revision, revision + 2);
      release.complete();
      await native;
      expect(f.revisions.isStable, isFalse);
      finish();
      finish();
      expect(f.revisions.revision, revision + 4);
      expect(f.revisions.isStable, isTrue);
      expect(f.storage.readKeys, isEmpty);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );
}
