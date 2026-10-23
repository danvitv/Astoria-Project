import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'native_provider_fixture.dart';

void main() {
  test(
    'preparation is one bounded canonical ID denial marker, never actual-key metadata',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      final canonical = f.storage.values[f.preparationStorageKey]!;
      expect(
        canonical,
        '{"v":1,"kind":"keyless-native-preparation","connectionId":"native-test"}',
      );
      expect(jsonDecode(canonical), {
        'v': 1,
        'kind': 'keyless-native-preparation',
        'connectionId': f.row.id,
      });
      expect(canonical.length, lessThanOrEqualTo(256));
      expect(utf8.encode(canonical).length, lessThanOrEqualTo(256));
      expect(f.storage.values.keys, [f.preparationStorageKey]);
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(f.storage.readKeys.toSet(), {
        f.nativeStorageKey,
        f.preparationStorageKey,
      });
      final reader = NativeProviderCredentialMetadataReader(
        credentials: f.credentials,
      );
      f.storage.readKeys.clear();
      for (final purpose in NativeProviderPurpose.values) {
        final observation = await reader.inspectSavedConnection(
          connection: f.reference(purpose),
          isCurrent: () => true,
        );
        expect(observation.state, NativeProviderCredentialState.absent);
        expect(observation.metadata.configured, false);
        expect(observation.metadata.characterCount, 0);
        expect(observation.metadata, CredentialMetadata.absent);
      }
      expect(f.storage.readKeys, everyElement(f.nativeStorageKey));
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.prepared,
      );
      expect(
        f.savedReads,
        0,
      ); // No repo hydration, entry review or create happens here.
      expect(f.storage.deleteKeys, isEmpty);
      await f
          .markPrepared(); // Valid exact marker is idempotent and not overwritten.
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(f.storage.values[f.preparationStorageKey], canonical);
    },
  );

  test(
    'preparation supports the maximum canonical ID but refuses unsafe or known-secret IDs',
    () async {
      final maximum = List.filled(128, 'a').join();
      final f = NativeProviderFixture();
      f.row = f.row.copyWith(id: maximum);
      await f.markPrepared();
      expect(
        utf8.encode(f.storage.values[f.preparationStorageKey]!).length,
        lessThanOrEqualTo(256),
      );
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: maximum,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.prepared,
      );
      for (final id in [
        '',
        List.filled(129, 'a').join(),
        'native/id',
        'native id',
        '.native',
        'native\n',
        'native\u0000',
        'кириллица',
        'KNOWN_SECRET_ID_TEST_ONLY',
      ]) {
        final invalid = NativeProviderFixture();
        invalid.redaction.registerSecret('KNOWN_SECRET_ID_TEST_ONLY');
        await expectLater(
          invalid.owned(
            (lease) => invalid.credentials.markPreparedForNativeCreate(
              lease: lease,
              connectionId: id,
            ),
          ),
          throwsNative(NativeProviderFailure.denied),
        );
        expect(invalid.storage.operations, isEmpty);
        expect(invalid.storage.values, isEmpty);
      }
    },
  );

  test(
    'missing preparation is absent; empty and every noncanonical marker are corrupt without overwrite',
    () async {
      final f = NativeProviderFixture();
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.absent,
      );
      await f.markPrepared();
      final canonical = f.storage.values[f.preparationStorageKey]!;
      final fields = jsonDecode(canonical) as Map<String, dynamic>;
      final malformedMarkers = [
        '',
        '{}',
        'null',
        '[]',
        '{',
        ' $canonical',
        '$canonical\n',
        canonical.replaceFirst('"v":1', '"v":1,"v":1'),
        canonical.replaceFirst('"v":1', '"v":1.0'),
        canonical.replaceFirst('"v":1', '"v":2'),
        canonical.replaceFirst('native-test', r'native\u002dtest'),
        jsonEncode({...fields, 'connectionId': 'other-native-id'}),
        jsonEncode({...fields, 'connectionId': null}),
        jsonEncode({...fields, 'kind': 'native-key'}),
        jsonEncode({...fields, 'extra': true}),
        jsonEncode({...fields, 'secret': nativeCanary}),
        jsonEncode({...fields, 'hash': 'TEST_ONLY_NOT_A_HASH'}),
        jsonEncode({...fields, 'route': f.row.endpoint}),
        jsonEncode({
          ...fields,
          'purposes': ['roleplay'],
        }),
        jsonEncode({'connectionId': f.row.id, 'kind': fields['kind'], 'v': 1}),
        List.filled(257, 'x').join(),
        List.filled(100, '🔐').join(),
        '${List.filled(200, '[').join()}0${List.filled(200, ']').join()}',
      ];
      f.storage.writeKeys.clear();
      for (final malformed in malformedMarkers) {
        f.storage.values[f.preparationStorageKey] = malformed;
        expect(
          await f.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          NativeProviderCredentialPresence.corrupt,
        );
        await expectLater(
          f.markPrepared(),
          throwsNative(NativeProviderFailure.corrupt),
        );
        await expectLater(
          f.owned(
            (lease) =>
                f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
          ),
          throwsNative(NativeProviderFailure.corrupt),
        );
        expect((await f.inspect()).metadata, CredentialMetadata.absent);
        expect(f.storage.values[f.preparationStorageKey], malformed);
      }
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'either preparation presence or value read failure stays unavailable, never absence',
    () async {
      for (final failingRead in [1, 2]) {
        final f = NativeProviderFixture();
        await f.markPrepared();
        final snapshot = Map.of(f.storage.values);
        f.storage.writeKeys.clear();
        var preparationReads = 0;
        f.storage.beforeRead = () async {
          if (f.storage.readKeys.last == f.preparationStorageKey &&
              ++preparationReads == failingRead) {
            f.storage.readError = StateError(nativeCanary);
          }
        };
        expect(
          await f.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          NativeProviderCredentialPresence.unavailable,
        );
        f.storage.readError = null;
        preparationReads = 0;
        await expectLater(
          f.markPrepared(),
          throwsNative(NativeProviderFailure.unavailable),
        );
        f.storage.readError = null;
        preparationReads = 0;
        await expectLater(
          f.owned(
            (lease) =>
                f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
          ),
          throwsNative(NativeProviderFailure.unavailable),
        );
        expect(f.storage.values, snapshot);
        expect(f.storage.writeKeys, isEmpty);
        expect(f.storage.deleteKeys, isEmpty);
      }
    },
  );

  test(
    'preparation disappearing after physical presence is corrupt, never fallback absence',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      var preparationReads = 0;
      f.storage.beforeRead = () async {
        if (f.storage.readKeys.last == f.preparationStorageKey &&
            ++preparationReads == 2) {
          // Synthetic out-of-owner storage loss, not a native deletion operation.
          f.storage.values.remove(f.preparationStorageKey);
        }
      };
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.corrupt,
      );
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'preparation presence refuses retired callers before and after marker reads',
    () async {
      final initial = NativeProviderFixture();
      await expectLater(
        initial.credentials.inspectNativePresence(
          connectionId: initial.row.id,
          isCurrent: () => false,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(initial.storage.readKeys, isEmpty);
      for (final revokedRead in [3, 4]) {
        final f = NativeProviderFixture();
        await f.markPrepared();
        f.storage.readKeys.clear();
        f.storage.beforeRead = () async {
          if (f.storage.readKeys.length == revokedRead) f.mutations.dispose();
        };
        await expectLater(
          f.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        expect(f.storage.readKeys.length, revokedRead);
        expect(f.storage.writeKeys, [f.preparationStorageKey]);
      }
    },
  );

  test(
    'restart preparation denies every legacy branch and every native purpose without a key',
    () async {
      final original = NativeProviderFixture();
      await original.markPrepared();
      original.storage.values[original.storageKey('api_config.llm')] =
          'LEGACY_TEST_ONLY';
      final restart = NativeProviderFixture(
        storage: original.storage,
        row: original.row,
      );
      final snapshot = Map.of(restart.storage.values);
      restart.storage.readKeys.clear();
      var legacyCalls = 0;
      var nativeCalls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: restart.credentials,
        transport: (_, _) async {
          nativeCalls++;
        },
      );
      for (final purpose in NativeProviderPurpose.values) {
        final presence = await restart.credentials.inspectNativePresence(
          connectionId: restart.row.id,
          isCurrent: () => true,
        );
        // The existing source-helper/factory legacy branch is exactly absence-only.
        // This is a core contract regression, not an invocation of those consumers.
        if (presence == NativeProviderCredentialPresence.absent) legacyCalls++;
        expect(presence, NativeProviderCredentialPresence.prepared);
        final observation = await restart.inspect(purpose);
        expect(observation.state, NativeProviderCredentialState.absent);
        expect(observation.metadata, CredentialMetadata.absent);
        await expectLater(
          broker.dispatch(
            observation,
            route: restart.route(purpose),
            isCurrent: () => true,
          ),
          throwsNative(NativeProviderFailure.stale),
        );
      }
      expect(legacyCalls, 0);
      expect(nativeCalls, 0);
      expect(restart.storage.values, snapshot);
      expect(restart.storage.readKeys.toSet(), {
        restart.nativeStorageKey,
        restart.preparationStorageKey,
      });
      expect(restart.savedReads, 0);
      expect(restart.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'actual LLM state always precedes preparation without changing the private record codec',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      final marker = f.storage.values[f.preparationStorageKey];
      await f.store(purposes: {NativeProviderPurpose.studio});
      final originalRecord = f.storage.values[f.nativeStorageKey]!;
      final record = jsonDecode(originalRecord) as Map<String, dynamic>;
      expect(record.keys.toSet(), {
        'v',
        'secret',
        'connection',
        'routes',
        'purposes',
        'revision',
        'active',
      });
      expect(record['v'], 1);
      expect(record['secret'], nativeCanary);
      expect(record['connection'], [
        f.row.id,
        f.row.providerId,
        f.row.protocol,
        f.row.endpoint,
        f.row.model,
        f.row.stream,
        f.row.useResponsesApi,
      ]);
      expect(record['purposes'], ['studio']);
      expect(record['revision'], matches(r'^[0-9a-f]{48}$'));
      expect(f.storage.values[f.preparationStorageKey], marker);
      for (final actual in [originalRecord, '', '{"v":1}']) {
        f.storage.values[f.nativeStorageKey] = actual;
        f.storage.values[f.preparationStorageKey] =
            'MALFORMED_MARKER_TEST_ONLY';
        f.storage.readKeys.clear();
        f.storage.beforeRead = () async {
          if (f.storage.readKeys.last == f.preparationStorageKey) {
            f.storage.readError = StateError('Preparation must not be read');
          }
        };
        expect(
          await f.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          actual == originalRecord
              ? NativeProviderCredentialPresence.present
              : NativeProviderCredentialPresence.corrupt,
        );
        expect(
          await f.owned(
            (lease) =>
                f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
          ),
          false,
        ); // Any physical LLM value refuses pre-key ownership.
        await expectLater(
          f.markPrepared(),
          throwsNative(NativeProviderFailure.conflicting),
        );
        expect(f.storage.readKeys, everyElement(f.nativeStorageKey));
        expect(f.storage.values[f.nativeStorageKey], actual);
      }
      f.storage.beforeRead = null;
      f.storage.values[f.nativeStorageKey] = originalRecord;
      f.storage.values[f.preparationStorageKey] = marker!;
      expect(
        (await f.inspect(NativeProviderPurpose.studio)).state,
        NativeProviderCredentialState.ready,
      );
      final wrongPurpose = await f.inspect();
      expect(wrongPurpose.state, NativeProviderCredentialState.conflicting);
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, _) async {
          calls++;
        },
      );
      await expectLater(
        broker.dispatch(wrongPurpose, route: f.route(), isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(
        calls,
        0,
      ); // Neither the retained marker nor a Studio key approves roleplay.
      expect(f.storage.values[f.nativeStorageKey], originalRecord);
      await f.credentials.disableNativeConnectionForOrdinaryMutation(
        connectionId: f.row.id,
      );
      expect(
        (await f.inspect(NativeProviderPurpose.studio)).state,
        NativeProviderCredentialState.disabled,
      );
      f.storage.readKeys.clear();
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.present,
      );
      expect(f.storage.readKeys, everyElement(f.nativeStorageKey));
      f.storage.readError = StateError(nativeCanary);
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.unavailable,
      );
      expect(f.storage.readKeys, everyElement(f.nativeStorageKey));
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'one canonical protected record, key rune metadata only, no legacy writes',
    () async {
      final f = NativeProviderFixture();
      final before = f.reference();
      final saved = await f.store();
      expect(saved, CredentialMetadata.fromSecret(nativeCanary));
      expect(saved.characterCount, nativeCanary.runes.length);
      expect(saved.characterCount, lessThan(nativeCanary.length));
      expect(f.storage.values.keys.single, f.nativeStorageKey);
      final encoded = f.storage.values.values.single;
      final privateRecord = jsonDecode(encoded) as Map<String, dynamic>;
      expect(privateRecord['secret'], nativeCanary);
      expect(privateRecord['v'], 1);
      expect(privateRecord['active'], true);
      expect(privateRecord['revision'], matches(r'^[0-9a-f]{48}$'));
      expect(privateRecord['connection'], [
        f.row.id,
        f.row.providerId,
        f.row.protocol,
        f.row.endpoint,
        f.row.model,
        f.row.stream,
        f.row.useResponsesApi,
      ]);
      final current = await f.inspect();
      expect(current.state, NativeProviderCredentialState.ready);
      expect(current.metadata, saved);
      expect(encoded.length, greaterThan(saved.characterCount));
      for (final safe in [
        current,
        current.connection,
        before,
        f.credentials,
        f.auth,
        f.policy,
        f.entry,
        current.metadata,
        f.mutations,
      ]) {
        expect(safe.toString(), isNot(contains(nativeCanary)));
        expect(safe.toString(), isNot(contains(privateRecord['revision'])));
      }
      expect(jsonEncode(saved.toJson()), isNot(contains(nativeCanary)));
      expect(f.row.apiKey, isEmpty);
      expect(f.row.embeddingApiKey, isEmpty);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'legacy same-ID secret is not seed/fallback for missing native record',
    () async {
      final f = NativeProviderFixture();
      f.storage.values[f.storageKey('api_config.llm')] = 'LEGACY_TEST_ONLY';
      final snapshot = Map.of(f.storage.values);
      final observation = await f.inspect();
      expect(observation.state, NativeProviderCredentialState.absent);
      expect(observation.metadata, CredentialMetadata.absent);
      expect(f.storage.values, snapshot);
      expect(f.storage.operations, everyElement('read'));
    },
  );

  test(
    'physically stored empty record is corrupt, never absent/seed/fallback permission',
    () async {
      final f = NativeProviderFixture();
      f.storage.values[f.nativeStorageKey] = '';
      f.storage.values[f.storageKey('api_config.llm')] = 'LEGACY_TEST_ONLY';
      final original = Map.of(f.storage.values);
      final observation = await f.inspect();
      expect(observation.state, NativeProviderCredentialState.corrupt);
      expect(observation.metadata, CredentialMetadata.absent);
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.corrupt,
      );
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, _) async {
          calls++;
        },
      );
      await expectLater(
        broker.dispatch(observation, route: f.route(), isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(f.store(), throwsNative(NativeProviderFailure.corrupt));
      expect(calls, 0);
      expect(f.storage.values, original);
      expect(f.storage.operations, everyElement('read'));
    },
  );

  test(
    'failed empty-or-missing presence read is unavailable, not inferred absence',
    () async {
      final f = NativeProviderFixture();
      f.storage.beforeRead = () async {
        if (f.storage.operations.length == 2) {
          f.storage.readError = StateError(nativeCanary);
        }
      };
      final observation = await f.inspect();
      expect(observation.state, NativeProviderCredentialState.unavailable);
      expect(observation.metadata, CredentialMetadata.absent);
      await expectLater(
        f.store(),
        throwsNative(NativeProviderFailure.unavailable),
      );
      expect(f.storage.operations, isNot(contains('write')));
      expect(f.storage.values, isEmpty);
    },
  );

  test(
    'unavailable differs from absence and cannot overwrite a record by entry',
    () async {
      final f = NativeProviderFixture();
      final permit = await f.permit();
      f.storage.readError = StateError(nativeCanary);
      expect(
        (await f.inspect()).state,
        NativeProviderCredentialState.unavailable,
      );
      await expectLater(
        f.credentials.storeFromNativeEntry(
          permit: permit,
          secret: nativeCanary,
        ),
        throwsNative(NativeProviderFailure.unavailable),
      );
      expect(f.storage.operations, isNot(contains('write')));
      expect(f.storage.values, isEmpty);
    },
  );

  test(
    'native presence guards even a malformed row without granting auth or envelope metadata',
    () async {
      final f = NativeProviderFixture();
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.absent,
      );
      await f.store();
      f.row = f.row.copyWith(
        model: '',
        endpoint: '',
        apiKey: 'CONFLICT_TEST_ONLY',
      );
      expect(
        f.auth.referenceFor(f.row, NativeProviderPurpose.roleplay),
        isNull,
      );
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.present,
      );
      await f.credentials.disableNativeConnectionForOrdinaryMutation(
        connectionId: f.row.id,
      );
      final record = jsonDecode(f.storage.values[f.nativeStorageKey]!) as Map;
      expect(record['active'], false);
      expect(record['secret'], nativeCanary);
    },
  );

  test(
    'native metadata facade has only observation/metadata, no writer surface',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final reader = NativeProviderCredentialMetadataReader(
        credentials: f.credentials,
      );
      final before = f.storage.operations.where((op) => op == 'write').length;
      final observation = await reader.inspectSavedConnection(
        connection: f.reference(),
        isCurrent: () => true,
      );
      expect(observation.metadata, CredentialMetadata.fromSecret(nativeCanary));
      expect(f.storage.operations.where((op) => op == 'write').length, before);
      expect(reader, isNot(isA<NativeProviderCredentialVault>()));
      expect(reader.toString(), isNot(contains(nativeCanary)));
    },
  );

  test(
    'nonempty row key, embedding/extras and route/model/purpose conflicts refuse',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final snapshot = Map.of(f.storage.values);
      for (final row in [
        f.row.copyWith(apiKey: 'ROW_KEY_TEST_ONLY'),
        f.row.copyWith(embeddingApiKey: 'EMBEDDING_TEST_ONLY'),
        f.row.copyWith(embeddingEnabled: true),
        f.row.copyWith(model: 'different-model'),
        f.row.copyWith(endpoint: 'https://api.openai.com/v1/responses'),
        f.row.copyWith(
          protocol: 'openai_responses',
          useResponsesApi: true,
          endpoint: 'https://api.openai.com/v1/responses',
        ),
      ]) {
        f.row = row;
        final observation = await f.inspect();
        expect(observation.state, NativeProviderCredentialState.conflicting);
        expect(observation.metadata.configured, false);
      }
      f.row = const ApiConfig(
        id: 'native-test',
        model: 'test-model',
        endpoint: 'https://api.openai.com/v1/chat/completions',
      );
      expect(
        (await f.inspect(NativeProviderPurpose.studio)).state,
        NativeProviderCredentialState.conflicting,
      );
      expect(f.storage.values, snapshot);
    },
  );

  test(
    'strict bounded decoder rejects duplicates/unknown/noncanonical records',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final canonical = f.storage.values[f.nativeStorageKey]!;
      final record = jsonDecode(canonical) as Map<String, dynamic>;
      final mutations = <String>[
        ' $canonical',
        canonical.replaceFirst('"v":1', '"v":1,"v":1'),
        canonical.replaceFirst('"v":1', '"v":1.0'),
        canonical.replaceFirst('"v":1', '"v":2'),
        jsonEncode({...record, 'extra': true}),
        jsonEncode({...record, 'secret': ''}),
        jsonEncode({...record, 'secret': 'key\n$nativeCanary'}),
        jsonEncode({...record, 'revision': 'not-a-native-revision'}),
        jsonEncode({...record, 'active': 'true'}),
        jsonEncode({
          ...record,
          'purposes': ['roleplay', 'roleplay'],
        }),
        jsonEncode({
          ...record,
          'purposes': ['modelDiscovery'],
        }),
        jsonEncode({...record, 'routes': <Object?>[]}),
        jsonEncode({...record, 'secret': List.filled(4097, 'x').join()}),
        List.filled(32769, 'x').join(),
        '${List.filled(100, '[').join()}0${List.filled(100, ']').join()}',
        '{"v":1}',
      ];
      for (final malformed in mutations) {
        f.storage.values[f.nativeStorageKey] = malformed;
        final observation = await f.inspect();
        expect(observation.state, NativeProviderCredentialState.corrupt);
        expect(observation.metadata, CredentialMetadata.absent);
        expect(observation.toString(), isNot(contains(nativeCanary)));
      }
      f.storage.values[f.nativeStorageKey] = canonical;
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'entry rejects empty/whitespace/control/oversize without trim or secret errors',
    () async {
      for (final secret in [
        '',
        ' $nativeCanary',
        '$nativeCanary ',
        '$nativeCanary\r\n',
        '$nativeCanary\u0000',
        List.filled(4097, 'x').join(),
      ]) {
        final f = NativeProviderFixture();
        final permit = await f.permit();
        await expectLater(
          f.credentials.storeFromNativeEntry(permit: permit, secret: secret),
          throwsNative(NativeProviderFailure.denied),
        );
        expect(f.storage.values, isEmpty);
        expect(f.storage.operations, isEmpty);
      }
    },
  );

  test(
    'write/readback failures retain original outcome and never rollback/delete/retry',
    () async {
      for (final mode in [
        'throw-after-write',
        'readback-unavailable',
        'drop-write',
      ]) {
        final f = NativeProviderFixture();
        final permit = await f.permit();
        f.storage.writeThenThrow = mode == 'throw-after-write';
        f.storage.dropWrite = mode == 'drop-write';
        if (mode == 'readback-unavailable') {
          f.storage.beforeWrite = () async {
            f.storage.readError = StateError(nativeCanary);
          };
        }
        await expectLater(
          f.credentials.storeFromNativeEntry(
            permit: permit,
            secret: nativeCanary,
          ),
          throwsNative(NativeProviderFailure.unavailable),
        );
        expect(f.storage.operations.where((op) => op == 'write').length, 1);
        expect(f.storage.operations, isNot(contains('delete')));
        f.storage.readError = null;
        f.storage.beforeWrite = null;
        final observed = await f.inspect();
        expect(
          observed.state,
          mode == 'drop-write'
              ? NativeProviderCredentialState.absent
              : NativeProviderCredentialState.ready,
        );
      }
    },
  );
}
