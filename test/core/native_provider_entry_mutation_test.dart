import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

import 'native_provider_fixture.dart';

void main() {
  test(
    'prepared ownership permits safe pre-key route/model edits, never native key or custom approval',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      final marker = f.storage.values[f.preparationStorageKey];
      final base = f.row;
      final restart = NativeProviderFixture(storage: f.storage, row: base);
      for (final proposed in [
        base.copyWith(
          name: 'New keyless name',
          model: 'different-model',
          maxTokens: 2048,
        ),
        base.copyWith(
          endpoint: 'https://proxy.example/tenant/v7/chat/completions',
        ),
        base.copyWith(
          protocol: 'openai_responses',
          useResponsesApi: true,
          endpoint: 'https://proxy.example/tenant/v7/responses',
        ),
        base.copyWith(
          protocol: 'anthropic',
          endpoint: 'https://proxy.example/tenant/v7/messages',
        ),
        base.copyWith(
          protocol: 'openrouter',
          endpoint: 'https://proxy.example/tenant/v7/chat/completions',
        ),
        base.copyWith(
          protocol: 'custom_chat_completion',
          endpoint: 'https://proxy.example/tenant/v7/chat/completions',
        ),
        base.copyWith(
          protocol: 'gemini',
          model: 'other-model',
          stream: false,
          endpoint:
              'https://proxy.example/tenant/v7/models/other-model:generateContent',
        ),
      ]) {
        expect(
          await restart.owned(
            (lease) => restart.credentials.isPreparedNativeOwned(
              lease: lease,
              saved: proposed,
            ),
          ),
          true,
        );
      }
      expect(
        restart.savedReads,
        0,
      ); // Pure ownership never hydrates/reviews the DB row.
      restart.row = base.copyWith(
        endpoint: 'https://proxy.example/tenant/v7/chat/completions',
      );
      await expectLater(
        restart.permit(),
        throwsNative(NativeProviderFailure.denied),
      );
      expect((await restart.inspect()).metadata, CredentialMetadata.absent);
      expect(restart.storage.values, {restart.preparationStorageKey: marker});
      expect(restart.storage.writeKeys, [restart.preparationStorageKey]);
      expect(
        restart.savedReads,
        1,
      ); // Only the explicitly attempted entry reads its saved row.
      expect(restart.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'a familiar ID/name prefix or another ID marker never proves native preparation',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      f.row = f.row.copyWith(
        id: 'native-created-studio',
        name: 'Native Studio connection',
      );
      f.storage.readKeys.clear();
      expect(
        await f.owned(
          (lease) =>
              f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
        ),
        false,
      );
      expect(
        await f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.absent,
      );
      expect(f.storage.readKeys.toSet(), {
        f.nativeStorageKey,
        f.preparationStorageKey,
      });
      expect(
        f.storage.values.length,
        1,
      ); // The other ID is neither read nor copied.
      expect(f.storage.writeKeys.length, 1);
    },
  );

  test(
    'prepared marker refuses plaintext, embedding, extras, unsafe and known-secret shapes',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      final base = f.row;
      f.redaction.registerSecret('KNOWN_SECRET_TEST_ONLY');
      f.redaction.registerSecret('known_secret_test_only');
      final snapshot = Map.of(f.storage.values);
      for (final proposed in [
        base.copyWith(apiKey: 'RAW_ROW_KEY_TEST_ONLY'),
        base.copyWith(embeddingApiKey: 'EMBED_KEY_TEST_ONLY'),
        base.copyWith(embeddingEnabled: true),
        base.copyWith(
          embeddingEndpoint: 'https://api.openai.com/v1/embeddings',
        ),
        base.copyWith(embeddingModel: 'embedding-model'),
        base.copyWith(embeddingLlmPresetId: 'another-preset'),
        base.copyWith(
          extraRequestParameters: [
            const ExtraRequestParameter(key: 'test', value: 'value'),
          ],
        ),
        base.copyWith(
          extraRequestParameters: [const ExtraRequestParameter(enabled: false)],
        ),
        base.copyWith(mode: 'embedding'),
        base.copyWith(id: 'unsafe/id'),
        base.copyWith(id: 'KNOWN_SECRET_TEST_ONLY'),
        base.copyWith(providerId: 'invalid-provider'),
        base.copyWith(providerId: 'known_secret_test_only'),
        base.copyWith(protocol: 'unknown'),
        base.copyWith(model: ''),
        base.copyWith(model: 'KNOWN_SECRET_TEST_ONLY'),
        base.copyWith(useResponsesApi: true),
        base.copyWith(endpoint: 'https://api.openai.com/v1/models'),
        base.copyWith(
          endpoint:
              'https://proxy.example/KNOWN_SECRET_TEST_ONLY/chat/completions',
        ),
        base.copyWith(endpoint: 'http://proxy.example/v1/chat/completions'),
        base.copyWith(endpoint: 'https://localhost/v1/chat/completions'),
        base.copyWith(endpoint: 'https://127.0.0.1/v1/chat/completions'),
        base.copyWith(endpoint: 'https://[::1]/v1/chat/completions'),
      ]) {
        f.storage.readKeys.clear();
        expect(
          await f.owned(
            (lease) => f.credentials.isPreparedNativeOwned(
              lease: lease,
              saved: proposed,
            ),
          ),
          false,
        );
        expect(
          f.storage.readKeys,
          isEmpty,
        ); // Invalid shapes fail before any protected read.
        expect(
          await f.credentials.inspectNativePresence(
            connectionId: base.id,
            isCurrent: () => true,
          ),
          NativeProviderCredentialPresence.prepared,
        );
      }
      expect(
        f.storage.values,
        snapshot,
      ); // Conflicting row never removes the denial marker.
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'preparation rejects foreign, closed and disposed leases before any storage invocation',
    () async {
      final f = NativeProviderFixture();
      final foreign = NativeProviderFixture();
      late NativeConnectionOperationLease closed;
      await f.owned((lease) async {
        closed = lease;
        await expectLater(
          foreign.credentials.markPreparedForNativeCreate(
            lease: lease,
            connectionId: foreign.row.id,
          ),
          throwsNative(NativeProviderFailure.denied),
        );
        await expectLater(
          foreign.credentials.isPreparedNativeOwned(
            lease: lease,
            saved: foreign.row,
          ),
          throwsNative(NativeProviderFailure.denied),
        );
      });
      await expectLater(
        f.credentials.markPreparedForNativeCreate(
          lease: closed,
          connectionId: f.row.id,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.credentials.isPreparedNativeOwned(lease: closed, saved: f.row),
        throwsNative(NativeProviderFailure.stale),
      );
      await f.owned((lease) async {
        f.mutations.dispose();
        await expectLater(
          f.credentials.markPreparedForNativeCreate(
            lease: lease,
            connectionId: f.row.id,
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        await expectLater(
          f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
          throwsNative(NativeProviderFailure.stale),
        );
      });
      expect(f.storage.operations, isEmpty);
      expect(foreign.storage.operations, isEmpty);
    },
  );

  test(
    'preparation rechecks original callback failures and reentrant retirement even if it returns true',
    () async {
      for (final retirement in ['false', 'throw', 'dispose', 'mutation']) {
        final f = NativeProviderFixture();
        var armed = false;
        await f.owned(
          (lease) async {
            armed = true;
            await expectLater(
              f.credentials.markPreparedForNativeCreate(
                lease: lease,
                connectionId: f.row.id,
              ),
              throwsNative(NativeProviderFailure.stale),
            );
            await expectLater(
              f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
              throwsNative(NativeProviderFailure.stale),
            );
          },
          isOriginalOwner: () {
            if (!armed) return true;
            if (retirement == 'false') return false;
            if (retirement == 'throw') throw StateError(nativeCanary);
            if (retirement == 'dispose') f.mutations.dispose();
            if (retirement == 'mutation') f.ordinaryMutation();
            return true;
          },
        );
        expect(f.storage.operations, isEmpty);
      }
    },
  );

  test(
    'preparation final admission happens at the real prep-slot FIFO head with zero revoked writes',
    () async {
      for (final retirement in [
        'view',
        'mutation',
        'container',
        'callback-container',
      ]) {
        final f = NativeProviderFixture();
        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        late Future<bool> blocker;
        var queued = false;
        var current = true;
        var disposeInCallback = false;
        f.storage.beforeRead = () async {
          if (queued &&
              f.storage.readKeys.last == f.preparationStorageKey &&
              !blockerStarted.isCompleted) {
            blockerStarted.complete();
            await releaseBlocker.future;
          }
        };
        final write = f.markPrepared(
          isOriginalOwner: () {
            if (disposeInCallback) {
              disposeInCallback = false;
              f.mutations
                  .dispose(); // Return true; the lease must still reject AFTER the callback.
            }
            // Queue a generic-vault read AFTER absence/marker preflight, but before
            // storeGuarded. It occupies the exact prep slot, not the LLM slot.
            if (!queued &&
                f.storage.readKeys
                        .where((key) => key == f.nativeStorageKey)
                        .length ==
                    2) {
              queued = true;
              blocker = f.genericVault.hasStoredValue(f.preparationSlot);
            }
            return current;
          },
        );
        final refusal = expectLater(
          write,
          throwsNative(NativeProviderFailure.stale),
        );
        await blockerStarted.future;
        if (retirement == 'container') {
          f.mutations.dispose();
        } else if (retirement == 'callback-container') {
          disposeInCallback = true;
        } else if (retirement == 'mutation') {
          f.ordinaryMutation();
        } else {
          current = false;
        }
        releaseBlocker.complete();
        expect(await blocker, false);
        await refusal;
        expect(f.storage.readKeys, [
          f.nativeStorageKey,
          f.preparationStorageKey,
          f.nativeStorageKey,
          f.preparationStorageKey,
        ]);
        expect(f.storage.writeKeys, isEmpty);
        expect(f.storage.deleteKeys, isEmpty);
        expect(f.storage.values, isEmpty);
      }
    },
  );

  test(
    'preparation refuses retirement during preflight before queuing any backend write',
    () async {
      final f = NativeProviderFixture();
      f.storage.beforeRead = () async {
        f.ordinaryMutation();
      };
      await expectLater(
        f.markPrepared(),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(f.storage.readKeys, [f.nativeStorageKey]);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.values, isEmpty);
    },
  );

  test(
    'prepared ownership checks currentness after every LLM/marker await, including final absence',
    () async {
      for (final revokedRead in [1, 2, 3, 4]) {
        final f = NativeProviderFixture();
        await f.markPrepared();
        f.storage.readKeys.clear();
        f.storage.beforeRead = () async {
          if (f.storage.readKeys.length == revokedRead) f.ordinaryMutation();
        };
        await expectLater(
          f.owned(
            (lease) =>
                f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        expect(f.storage.readKeys.length, revokedRead);
        expect(f.storage.writeKeys, [f.preparationStorageKey]);
        expect(f.storage.deleteKeys, isEmpty);
      }
    },
  );

  test(
    'a key record appearing during marker inspection refuses prepared ownership without decoding it',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      f.storage.readKeys.clear();
      f.storage.beforeRead = () async {
        if (f.storage.readKeys.length == 3) {
          f.storage.values[f.nativeStorageKey] =
              'PHYSICAL_LLM_CONFLICT_TEST_ONLY';
        }
      };
      expect(
        await f.owned(
          (lease) =>
              f.credentials.isPreparedNativeOwned(lease: lease, saved: f.row),
        ),
        false,
      );
      expect(f.storage.readKeys, [
        f.nativeStorageKey,
        f.preparationStorageKey,
        f.preparationStorageKey,
        f.nativeStorageKey,
      ]);
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(
        f.storage.values[f.nativeStorageKey],
        'PHYSICAL_LLM_CONFLICT_TEST_ONLY',
      );
    },
  );

  test(
    'marking rechecks physical LLM absence even for an existing idempotent marker',
    () async {
      final f = NativeProviderFixture();
      await f.markPrepared();
      final marker = f.storage.values[f.preparationStorageKey];
      f.storage.readKeys.clear();
      f.storage.writeKeys.clear();
      f.storage.beforeRead = () async {
        if (f.storage.readKeys.length == 3) {
          f.storage.values[f.nativeStorageKey] = '';
        }
      };
      await expectLater(
        f.markPrepared(),
        throwsNative(NativeProviderFailure.conflicting),
      );
      expect(f.storage.readKeys, [
        f.nativeStorageKey,
        f.preparationStorageKey,
        f.preparationStorageKey,
        f.nativeStorageKey,
      ]);
      expect(f.storage.writeKeys, isEmpty);
      expect(f.storage.values[f.preparationStorageKey], marker);
      expect(f.storage.values[f.nativeStorageKey], '');
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test(
    'a started preparation preserves its original verified fact but cannot admit DB work after retirement',
    () async {
      for (final retirement in ['view', 'mutation', 'container']) {
        final f = NativeProviderFixture();
        var current = true;
        var syntheticDbCalls = 0;
        final started = Completer<void>();
        final release = Completer<void>();
        f.storage.beforeWrite = () async {
          started.complete();
          await release.future;
        };
        final original = f.owned((lease) async {
          await f.credentials.markPreparedForNativeCreate(
            lease: lease,
            connectionId: f.row.id,
          );
          expect(lease.isCurrent, false);
          await expectLater(
            lease.runObservedMutation(() async {
              syntheticDbCalls++;
            }),
            throwsNative(NativeProviderFailure.stale),
          );
          return 'original marker verified';
        }, isOriginalOwner: () => current);
        await started.future;
        if (retirement == 'container') {
          f.mutations.dispose();
        } else if (retirement == 'mutation') {
          f.ordinaryMutation();
        } else {
          current = false;
        }
        release.complete();
        expect(await original, 'original marker verified');
        expect(syntheticDbCalls, 0);
        expect(f.storage.writeKeys, [f.preparationStorageKey]);
        expect(f.storage.values.keys, [f.preparationStorageKey]);
        expect(f.savedReads, 0);
        final restart = NativeProviderFixture(storage: f.storage, row: f.row);
        expect(
          await restart.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          NativeProviderCredentialPresence.prepared,
        );
        expect(
          (await restart.inspect(NativeProviderPurpose.studio)).metadata,
          CredentialMetadata.absent,
        );
        expect(f.storage.deleteKeys, isEmpty);
      }
    },
  );

  test(
    'preparation write failures preserve uncertain orphan facts without DB, key, deletion or retry',
    () async {
      for (final mode in [
        'write-failure',
        'throw-after-write',
        'readback-unavailable',
        'drop-write',
      ]) {
        final f = NativeProviderFixture();
        f.storage.writeError = mode == 'write-failure'
            ? StateError(nativeCanary)
            : null;
        f.storage.writeThenThrow = mode == 'throw-after-write';
        f.storage.dropWrite = mode == 'drop-write';
        if (mode == 'readback-unavailable') {
          f.storage.beforeWrite = () async {
            f.storage.readError = StateError(nativeCanary);
          };
        }
        var syntheticDbCalls = 0;
        await expectLater(
          f.owned((lease) async {
            await f.credentials.markPreparedForNativeCreate(
              lease: lease,
              connectionId: f.row.id,
            );
            await lease.runObservedMutation(() async {
              syntheticDbCalls++;
            });
          }),
          throwsNative(NativeProviderFailure.unavailable),
        );
        expect(syntheticDbCalls, 0);
        expect(f.storage.writeKeys, [f.preparationStorageKey]);
        expect(f.storage.deleteKeys, isEmpty);
        f.storage.readError = null;
        f.storage.beforeWrite = null;
        final restart = NativeProviderFixture(storage: f.storage, row: f.row);
        expect(
          await restart.credentials.inspectNativePresence(
            connectionId: f.row.id,
            isCurrent: () => true,
          ),
          mode == 'write-failure' || mode == 'drop-write'
              ? NativeProviderCredentialPresence.absent
              : NativeProviderCredentialPresence.prepared,
        );
        expect((await restart.inspect()).metadata, CredentialMetadata.absent);
        expect(f.storage.writeKeys, [
          f.preparationStorageKey,
        ]); // Inspection never retries.
      }
    },
  );

  test(
    'marker before synthetic DB rollback is a safe durable orphan and leaves other slots untouched',
    () async {
      final f = NativeProviderFixture();
      final otherRow = f.row.copyWith(id: 'unrelated-native');
      final other = NativeProviderFixture(storage: f.storage, row: otherRow);
      await other.store(secret: 'OTHER_NATIVE_KEY_TEST_ONLY');
      f.storage.values[f.storageKey('api_config.llm')] = 'LEGACY_TEST_ONLY';
      final existing = Map.of(f.storage.values);
      f.storage.readKeys.clear();
      f.storage.writeKeys.clear();
      var syntheticDbCalls = 0;
      await expectLater(
        f.owned((lease) async {
          await f.credentials.markPreparedForNativeCreate(
            lease: lease,
            connectionId: f.row.id,
          );
          await lease.runObservedMutation(() async {
            // This counter stands for parent DB admission, not a real transaction.
            expect(f.storage.values.containsKey(f.preparationStorageKey), true);
            expect(lease.isCurrent, true);
            syntheticDbCalls++;
            throw StateError('SYNTHETIC_DB_ROLLBACK_TEST_ONLY');
          });
        }),
        throwsNative(NativeProviderFailure.unavailable),
      );
      expect(syntheticDbCalls, 1);
      expect(f.storage.values, {
        ...existing,
        f.preparationStorageKey:
            '{"v":1,"kind":"keyless-native-preparation","connectionId":"native-test"}',
      });
      f.ordinaryMutation();
      await f.credentials.settleOrdinaryInvalidations();
      expect(f.storage.readKeys.toSet(), {
        f.nativeStorageKey,
        f.preparationStorageKey,
      });
      expect(f.storage.writeKeys, [f.preparationStorageKey]);
      expect(f.storage.deleteKeys, isEmpty);
      expect(f.savedReads, 0);
      final restart = NativeProviderFixture(storage: f.storage, row: f.row);
      expect(
        await restart.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.prepared,
      );
      expect(
        (await restart.inspect()).state,
        NativeProviderCredentialState.absent,
      );
    },
  );

  test(
    'native entry reobserves exact saved keyless row, one gesture and one permit',
    () async {
      final f = NativeProviderFixture();
      final displayed = await f.entry.review(
        connection: f.reference(),
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: f.lifetime,
      );
      expect(f.savedReads, 1);
      final permit = f.entry.confirmNativeEntry(displayed);
      expect(
        () => f.entry.confirmNativeEntry(displayed),
        throwsNative(NativeProviderFailure.denied),
      );
      await f.credentials.storeFromNativeEntry(
        permit: permit,
        secret: nativeCanary,
      );
      await expectLater(
        f.credentials.storeFromNativeEntry(
          permit: permit,
          secret: nativeCanary,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.storage.operations.where((op) => op == 'write').length, 1);
      expect(permit.toString(), isNot(contains(nativeCanary)));
    },
  );

  test(
    'row/currentness checked after latest-row await before native gesture',
    () async {
      final f = NativeProviderFixture();
      final start = Completer<void>();
      final release = Completer<void>();
      f.beforeSavedRead = () async {
        start.complete();
        await release.future;
      };
      final review = f.entry.review(
        connection: f.reference(),
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: f.lifetime,
      );
      final refusal = expectLater(
        review,
        throwsNative(NativeProviderFailure.stale),
      );
      await start.future;
      f.ordinaryMutation();
      release.complete();
      await refusal;
      expect(f.storage.operations, isEmpty);
      expect(f.storage.values, isEmpty);
    },
  );

  test(
    'entry cannot reinterpret a changed/nonempty saved row as keyless',
    () async {
      final f = NativeProviderFixture();
      final reference = f.reference();
      f.row = f.row.copyWith(apiKey: 'ROW_TEST_ONLY');
      await expectLater(
        f.entry.review(
          connection: reference,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        ),
        throwsNative(NativeProviderFailure.conflicting),
      );
      f.row = f.row.copyWith(apiKey: '', model: 'different-model');
      await expectLater(
        f.entry.review(
          connection: reference,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        ),
        throwsNative(NativeProviderFailure.conflicting),
      );
      expect(f.storage.operations, isEmpty);
    },
  );

  test(
    'redaction registration is synchronous and pre-invocation retirement refuses',
    () async {
      final f = NativeProviderFixture();
      final permit = await f.permit();
      var registered = false;
      f.redaction.addListener((redactor) {
        registered = !redactor.redactText(nativeCanary).contains(nativeCanary);
        f.uiCurrent = false;
      });
      final write = f.credentials.storeFromNativeEntry(
        permit: permit,
        secret: nativeCanary,
      );
      expect(registered, true); // No await has happened in the caller yet.
      await expectLater(write, throwsNative(NativeProviderFailure.stale));
      expect(f.storage.operations, isEmpty);
    },
  );

  test(
    'late original verified readback survives view or container retirement',
    () async {
      for (final retirement in ['view', 'container']) {
        final f = NativeProviderFixture();
        final permit = await f.permit();
        final oldReference = f.reference();
        final started = Completer<void>();
        final release = Completer<void>();
        f.storage.beforeWrite = () async {
          started.complete();
          await release.future;
        };
        final write = f.credentials.storeFromNativeEntry(
          permit: permit,
          secret: nativeCanary,
        );
        expect(
          f.auth.isCurrent(oldReference),
          false,
        ); // Before ANY await in this caller.
        await started.future;
        if (retirement == 'container') {
          f.mutations.dispose();
        } else {
          f.uiCurrent = false;
          f.lifetime.retire();
        }
        release.complete();
        expect(await write, CredentialMetadata.fromSecret(nativeCanary));
        expect(f.storage.operations, ['read', 'read', 'write', 'read']);
        expect(
          (jsonDecode(f.storage.values[f.nativeStorageKey]!) as Map)['secret'],
          nativeCanary,
        );
        // Original factual custody can reconcile using a NEW native container.
        final restart = NativeProviderFixture(storage: f.storage, row: f.row);
        expect(
          (await restart.inspect()).state,
          NativeProviderCredentialState.ready,
        );
        if (retirement == 'container') expect(f.mutations.observe(), isNull);
      }
    },
  );

  test(
    'entry admission rechecks after intervening actual backend-slot FIFO wait',
    () async {
      for (final retirement in [
        'view',
        'mutation',
        'container',
        'callback-container',
      ]) {
        final f = NativeProviderFixture();
        final permit = await f.permit();
        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        late Future<bool> blocker;
        var queued = false;
        var disposeInCallback = false;
        f.entryIsCurrent = () {
          if (disposeInCallback) {
            disposeInCallback = false;
            f.mutations
                .dispose(); // Still returns true: owner must recheck AFTER it.
          }
          // Queue a generic-vault operation at the native owner's AFTER-read
          // precheck. It will occupy the SAME actual slot before storeGuarded.
          if (!queued &&
              f.storage.operations.where((op) => op == 'read').length == 2) {
            queued = true;
            blocker = f.genericVault.hasStoredValue(f.nativeSlot);
          }
          return f.uiCurrent;
        };
        f.storage.beforeRead = () async {
          if (queued && !blockerStarted.isCompleted) {
            blockerStarted.complete();
            await releaseBlocker.future;
          }
        };
        final write = f.credentials.storeFromNativeEntry(
          permit: permit,
          secret: nativeCanary,
        );
        final refusal = expectLater(
          write,
          throwsNative(NativeProviderFailure.stale),
        );
        await blockerStarted.future;
        if (retirement == 'container') {
          f.mutations.dispose();
        } else if (retirement == 'callback-container') {
          disposeInCallback = true;
        } else if (retirement == 'mutation') {
          f.ordinaryMutation();
        } else {
          f.uiCurrent = false;
        }
        releaseBlocker.complete();
        expect(await blocker, false);
        await refusal;
        expect(f.storage.operations, ['read', 'read', 'read']);
        expect(
          f.storage.values,
          isEmpty,
        ); // Denied, not an uncertain started write.
      }
    },
  );

  test('stale queued credential permit cannot start a second write', () async {
    final f = NativeProviderFixture();
    final first = await f.permit();
    final second = await f.permit();
    final started = Completer<void>();
    final release = Completer<void>();
    f.storage.beforeWrite = () async {
      started.complete();
      await release.future;
    };
    final original = f.credentials.storeFromNativeEntry(
      permit: first,
      secret: nativeCanary,
    );
    // The first entry fences synchronously; the competing old permit is stale.
    final competing = f.credentials.storeFromNativeEntry(
      permit: second,
      secret: 'SECOND_TEST_ONLY',
    );
    final refusal = expectLater(
      competing,
      throwsNative(NativeProviderFailure.stale),
    );
    await started.future;
    release.complete();
    await original;
    await refusal;
    expect(f.storage.operations.where((op) => op == 'write').length, 1);
  });

  test(
    'owned no-ID start+finish fence does not selfrevoke; old stamps remain revoked',
    () async {
      final f = NativeProviderFixture();
      final stamp = f.mutations.observe()!;
      var acceptedTextRetirements = 0;
      f.mutations.addFenceListener(() {
        acceptedTextRetirements++;
      });
      final admission = f.mutations.admit(
        expected: stamp,
        isOriginalOwner: () => true,
      )!;
      late NativeConnectionOperationLease originalLease;
      final result = await f.mutations.runOwned(
        admission: admission,
        operation: (lease) async {
          originalLease = lease;
          expect(lease.isCurrent, true);
          return lease.runObservedMutation(() async {
            final finish = f.mutations.onMutationStarted();
            expect(lease.isCurrent, true);
            await Future<void>.value();
            expect(lease.isCurrent, true);
            finish();
            expect(lease.isCurrent, true);
            return 'original durable result';
          });
        },
      );
      expect(result, 'original durable result');
      expect(
        acceptedTextRetirements,
        4,
      ); // Outer start/end plus observed repo start/end.
      expect(f.mutations.isCurrent(stamp), false);
      expect(originalLease.isCurrent, false);
      expect(f.mutations.isCurrent(originalLease.settlementStamp!), true);
      await expectLater(
        f.mutations.runOwned(
          admission: admission,
          operation: (_) async => fail('already claimed'),
        ),
        throwsNative(NativeProviderFailure.stale),
      );
    },
  );

  test(
    'competing mutation and ABA invalidate lease and its settlement stamp',
    () async {
      final f = NativeProviderFixture();
      final admission = f.mutations.admit(
        expected: f.mutations.observe()!,
        isOriginalOwner: () => true,
      )!;
      final started = Completer<NativeConnectionOperationLease>();
      final release = Completer<void>();
      final operation = f.mutations.runOwned(
        admission: admission,
        operation: (lease) async {
          started.complete(lease);
          await release.future;
          return lease.runObservedMutation(
            () async => fail('competing edit invalidates'),
          );
        },
      );
      final refusal = expectLater(
        operation,
        throwsNative(NativeProviderFailure.stale),
      );
      final lease = await started.future;
      f.ordinaryMutation();
      f.row = f.row.copyWith(model: 'changed');
      f.ordinaryMutation();
      f.row = f.row.copyWith(model: 'test-model');
      expect(lease.isCurrent, false);
      release.complete();
      await refusal;
      expect(lease.settlementStamp, isNull);
    },
  );

  test(
    'committed synthetic operation returns its original receipt after owner retirement',
    () async {
      for (final retirement in ['view', 'container']) {
        final f = NativeProviderFixture();
        var originalCurrent = true;
        final admission = f.mutations.admit(
          expected: f.mutations.observe()!,
          isOriginalOwner: () => originalCurrent,
        )!;
        final committed = Completer<void>();
        final deliverReceipt = Completer<void>();
        const receipt = ('synthetic-native-row', 'COMMITTED_TEST_ONLY');
        late NativeConnectionOperationLease originalLease;
        final result = f.mutations.runOwned(
          admission: admission,
          operation: (lease) {
            originalLease = lease;
            return lease.runObservedMutation(() async {
              final finish = f.mutations.onMutationStarted();
              try {
                expect(
                  lease.isCurrent,
                  true,
                ); // Actual effect's pre-operation guard.
                await f.storage.write(receipt.$1, receipt.$2);
                expect(await f.storage.read(receipt.$1), receipt.$2);
                committed
                    .complete(); // The actual synthetic write/readback is done.
                await deliverReceipt
                    .future; // Only original result delivery remains.
                return receipt;
              } finally {
                finish();
              }
            });
          },
        );
        await committed.future;
        if (retirement == 'container') {
          f.mutations.dispose();
        } else {
          originalCurrent = false;
        }
        expect(originalLease.isCurrent, false);
        deliverReceipt.complete();
        expect(await result, receipt); // Fact custody is NOT a new admission.
        expect(f.storage.values[receipt.$1], receipt.$2);
        expect(
          originalLease.isCurrent,
          false,
        ); // No replacement-view publication.
        expect(originalLease.settlementStamp, isNull);
      }
    },
  );

  test(
    'container dispose is permanent and denies refs, permits, admissions and dispatch',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final reference = f.reference();
      final observation = await f.inspect();
      final route = f.route();
      final review = await f.entry.review(
        connection: reference,
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: f.lifetime,
      );
      final permit = await f.permit();
      final stamp = f.mutations.observe()!;
      final admission = f.mutations.admit(
        expected: stamp,
        isOriginalOwner: () => true,
      )!;
      var fences = 0;
      f.mutations.addFenceListener(() {
        fences++;
      });
      final originalValues = Map.of(f.storage.values);
      f.storage.operations.clear();
      f.mutations.dispose();
      f.mutations.dispose();
      expect(fences, 1);
      expect(f.mutations.isStable, false);
      expect(f.mutations.observe(), isNull);
      expect(f.mutations.isCurrent(stamp), false);
      expect(
        f.mutations.admit(expected: stamp, isOriginalOwner: () => true),
        isNull,
      );
      expect(
        f.auth.referenceFor(f.row, NativeProviderPurpose.roleplay),
        isNull,
      );
      expect(f.auth.isCurrent(reference), false);
      expect(
        () => f.entry.confirmNativeEntry(review),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.entry.review(
          connection: reference,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.credentials.storeFromNativeEntry(
          permit: permit,
          secret: nativeCanary,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.mutations.runOwned(
          admission: admission,
          operation: (_) async =>
              fail('disposed owner must not invoke a new operation'),
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.credentials.disableNativeConnectionForOrdinaryMutation(
          connectionId: f.row.id,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        f.credentials.inspectNativePresence(
          connectionId: f.row.id,
          isCurrent: () => true,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        Future.sync(
          () => f.credentials.inspectSavedConnection(
            connection: reference,
            isCurrent: () => true,
          ),
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, _) async {
          calls++;
        },
      );
      await expectLater(
        broker.dispatch(observation, route: route, isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
      await expectLater(
        broker.metadata(observation, isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
      f.mutations.addFenceListener(() {
        fences++;
      });
      f.mutations.onMutationStarted()();
      expect(fences, 1);
      expect(f.mutations.isStable, false);
      expect(calls, 0);
      expect(f.storage.operations, isEmpty);
      expect(
        f.storage.values,
        originalValues,
      ); // Dispose is NOT credential deletion.
    },
  );

  test(
    'dispose invalidates an already-invoked transport binding through its final callback',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final observation = await f.inspect();
      final route = f.route();
      final started = Completer<NativeProviderDispatchBinding>();
      final finishTransport = Completer<void>();
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (binding, key) async {
          expect(key, nativeCanary);
          started.complete(binding);
          await finishTransport.future;
        },
      );
      final request = broker.dispatch(
        observation,
        route: route,
        isCurrent: () => true,
      );
      final refusal = expectLater(
        request,
        throwsNative(NativeProviderFailure.stale),
      );
      final binding = await started.future;
      f.mutations.dispose();
      expect(binding.isCurrent, false);
      expect(
        () => binding.requireFinalRequest(
          uri: route.endpoint,
          method: 'POST',
          protocol: route.protocol,
          purpose: observation.purpose,
          model: observation.connection.model,
          stream: true,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      finishTransport.complete();
      await refusal;
      expect(f.mutations.observe(), isNull);
    },
  );

  test(
    'disposal in admission or fence callbacks cannot invoke a newly claimed operation',
    () async {
      final admissionOwner = NativeProviderFixture();
      final admission = admissionOwner.mutations.admit(
        expected: admissionOwner.mutations.observe()!,
        isOriginalOwner: () {
          admissionOwner.mutations.dispose();
          return true;
        },
      );
      expect(admission, isNull);
      for (final retirement in ['owner-callback', 'fence-callback']) {
        final f = NativeProviderFixture();
        var armed = false;
        final claim = f.mutations.admit(
          expected: f.mutations.observe()!,
          isOriginalOwner: () {
            if (armed && retirement == 'owner-callback') f.mutations.dispose();
            return true;
          },
        )!;
        f.mutations.addFenceListener(() {
          if (armed && retirement == 'fence-callback') f.mutations.dispose();
        });
        armed = true;
        var invoked = false;
        await expectLater(
          f.mutations.runOwned(
            admission: claim,
            operation: (_) async {
              invoked = true;
            },
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        expect(invoked, false);
        expect(f.mutations.observe(), isNull);
        expect(f.storage.operations, isEmpty);
      }
    },
  );

  test(
    'unrelated legacy edit or ordinary name change fences authority without disabling keys',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final oldReference = f.reference();
      final oldObservation = await f.inspect();
      final route = f.route();
      final record = f.storage.values[f.nativeStorageKey];
      var legacy = const ApiConfig(
        id: 'legacy-test',
        model: 'legacy-model',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: 'LEGACY_TEST_ONLY',
      );
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, key) async {
          expect(key, nativeCanary);
          calls++;
        },
      );
      for (final edit in ['legacy-name', 'native-name']) {
        f.storage.operations.clear();
        f.ordinaryMutation();
        if (edit == 'legacy-name') {
          legacy = legacy.copyWith(name: 'Renamed legacy connection');
        } else {
          f.row = f.row.copyWith(name: 'Renamed native connection');
        }
        await f.credentials.settleOrdinaryInvalidations();
        expect(
          f.storage.operations,
          isEmpty,
        ); // No-ID observation performs NO IO.
        expect(
          f.storage.values[f.nativeStorageKey],
          record,
        ); // Revision/active unchanged.
        expect(f.auth.isCurrent(oldReference), false);
        await expectLater(
          broker.dispatch(oldObservation, route: route, isCurrent: () => true),
          throwsNative(NativeProviderFailure.stale),
        );
        final fresh = await f.inspect();
        expect(fresh.state, NativeProviderCredentialState.ready);
        await broker.dispatch(fresh, route: f.route(), isCurrent: () => true);
      }
      expect(calls, 2);
      expect(legacy.apiKey, 'LEGACY_TEST_ONLY');
      expect((jsonDecode(record!) as Map)['active'], true);
    },
  );

  test(
    'explicit affected-ID disable preserves secret/legacy and leaves other native keys active',
    () async {
      final f = NativeProviderFixture();
      final originalRow = f.row;
      await f.store();
      final originalStorageKey = f.nativeStorageKey;
      f.row = f.row.copyWith(id: 'native-other');
      await f.store(secret: 'SECOND_NATIVE_TEST_ONLY');
      final otherStorageKey = f.nativeStorageKey;
      final otherRecord = f.storage.values[otherStorageKey];
      f.row = originalRow;
      f.storage.values[f.storageKey('api_config.llm')] = 'LEGACY_TEST_ONLY';
      await f.credentials.disableForOrdinaryMutation(
        connection: f.reference().connection,
      );
      f.ordinaryMutation();
      await f.credentials.settleOrdinaryInvalidations();
      expect((await f.inspect()).state, NativeProviderCredentialState.disabled);
      final privateRecord =
          jsonDecode(f.storage.values[originalStorageKey]!) as Map;
      expect(privateRecord['secret'], nativeCanary);
      expect(privateRecord['active'], false);
      expect(
        f.storage.values[f.storageKey('api_config.llm')],
        'LEGACY_TEST_ONLY',
      );
      expect(f.storage.values[otherStorageKey], otherRecord);
      f.row = f.row.copyWith(id: 'native-other');
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
      f.row = originalRow;
      final restart = NativeProviderFixture(storage: f.storage, row: f.row);
      expect(
        (await restart.inspect()).state,
        NativeProviderCredentialState.disabled,
      );
      await expectLater(
        restart.store(),
        throwsNative(NativeProviderFailure.conflicting),
      );
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'competing global fence during started write preserves facts without guessing key disable',
    () async {
      final f = NativeProviderFixture();
      final permit = await f.permit();
      final started = Completer<void>();
      final release = Completer<void>();
      var first = true;
      f.storage.beforeWrite = () async {
        if (first) {
          first = false;
          started.complete();
          await release.future;
        }
      };
      final write = f.credentials.storeFromNativeEntry(
        permit: permit,
        secret: nativeCanary,
      );
      await started.future;
      f.ordinaryMutation();
      release.complete();
      expect(await write, CredentialMetadata.fromSecret(nativeCanary));
      await f.credentials.settleOrdinaryInvalidations();
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
      final record = jsonDecode(f.storage.values[f.nativeStorageKey]!) as Map;
      expect(record['secret'], nativeCanary);
      expect(record['active'], true);
    },
  );

  test(
    'first ordinary mutation after restart uses explicit native presence/disable hook',
    () async {
      final original = NativeProviderFixture();
      await original.store();
      final restart = NativeProviderFixture(
        storage: original.storage,
        row: original.row,
      );
      expect(
        await restart.credentials.inspectNativePresence(
          connectionId: restart.row.id,
          isCurrent: () => true,
        ),
        NativeProviderCredentialPresence.present,
      );
      await restart.credentials.disableNativeConnectionForOrdinaryMutation(
        connectionId: restart.row.id,
      );
      restart.ordinaryMutation();
      restart.row = restart.row.copyWith(
        endpoint: 'https://other.example/v1/chat/completions',
      );
      await restart.credentials.settleOrdinaryInvalidations();
      final record =
          jsonDecode(restart.storage.values[restart.nativeStorageKey]!) as Map;
      expect(record['active'], false);
      expect(record['secret'], nativeCanary);
      expect((record['connection'] as List)[3], original.row.endpoint);
      restart.row = restart.row.copyWith(
        protocol: 'custom_chat_completion',
        providerId: 'custom_chat_completion',
      );
      final changed = restart.policy.reviewCustomDestination(
        connection: restart.reference().connection,
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: restart.lifetime,
      );
      await expectLater(
        restart.store(
          destinationApproval: restart.policy.confirmCustomDestination(changed),
        ),
        throwsNative(NativeProviderFailure.conflicting),
      );
      final observation = await restart.inspect();
      expect(observation.state, NativeProviderCredentialState.conflicting);
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: restart.credentials,
        transport: (_, _) async {
          calls++;
        },
      );
      await expectLater(
        broker.dispatch(
          observation,
          route: restart.route(),
          isCurrent: () => true,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      final reopened = NativeProviderFixture(
        storage: restart.storage,
        row: restart.row,
      );
      expect(
        (await reopened.inspect()).state,
        NativeProviderCredentialState.conflicting,
      );
      expect(
        restart.storage.values[restart.nativeStorageKey],
        jsonEncode(record),
      );
      expect(
        calls,
        0,
      ); // Fresh approval never moves/reactivates the old disabled key.
    },
  );
}
