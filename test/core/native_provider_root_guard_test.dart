import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

import 'native_provider_fixture.dart';

Future<T> _held<T>(
  NativeProviderFixture f,
  Future<T> Function(NativeConnectionOperationLease) operation, {
  bool Function()? isCurrent,
}) {
  final admission = f.mutations.admit(
    expected: f.mutations.observe()!,
    isOriginalOwner: isCurrent ?? () => true,
  )!;
  return f.mutations.runOwned(
    admission: admission,
    operation: (lease) => lease.runObservedMutation(() => operation(lease)),
  );
}

Map<String, dynamic> _record(NativeProviderFixture f) =>
    jsonDecode(f.storage.values[f.nativeStorageKey]!) as Map<String, dynamic>;

void main() {
  test('native view retirement is rechecked after its callback', () {
    late NativeProviderViewLifetime lifetime;
    lifetime = NativeProviderViewLifetime(
      isCurrent: () {
        lifetime.retire();
        return true;
      },
    );
    expect(lifetime.isCurrent, isFalse);
    expect(lifetime.isCurrent, isFalse);
  });

  test(
    'entry review rechecks the original epoch after native view callback',
    () async {
      final f = NativeProviderFixture();
      final review = await f.entry.review(
        connection: f.reference(),
        purposes: const {NativeProviderPurpose.roleplay},
        lifetime: f.lifetime,
      );
      f.entryIsCurrent = () {
        f.ordinaryMutation();
        return true;
      };
      expect(review.isCurrent, isFalse);
      expect(
        () => f.entry.confirmNativeEntry(review),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(f.storage.operations.where((op) => op == 'write'), isEmpty);
    },
  );

  test(
    'reentrant competing final fence cannot mint an original settlement stamp',
    () async {
      final f = NativeProviderFixture();
      var fences = 0;
      NativeConnectionOperationLease? original;
      f.mutations.addFenceListener(() {
        fences++;
        if (fences == 2) f.ordinaryMutation();
      });
      final result = await _held(f, (lease) async {
        original = lease;
        return 'original synthetic fact';
      });
      expect(result, 'original synthetic fact');
      expect(original!.settlementStamp, isNull);
      expect(f.mutations.isStable, isTrue);
      expect(f.storage.operations, isEmpty);
    },
  );

  test(
    'ordinary name and limit changes preserve protected record with zero writes',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final original = f.storage.values[f.nativeStorageKey];
      f.storage.operations.clear();
      await _held(
        f,
        (lease) => f.credentials.guardOrdinaryPut(
          lease: lease,
          existing: f.row,
          proposed: f.row.copyWith(name: 'Native renamed', maxTokens: 512),
        ),
      );
      expect(f.storage.values[f.nativeStorageKey], original);
      expect(f.storage.operations.where((op) => op == 'write'), isEmpty);
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
    },
  );

  test(
    'ordinary model change disables original key and ABA cannot reactivate it',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final before = f.row;
      final proposed = before.copyWith(model: 'other-model');
      f.storage.operations.clear();
      await _held(
        f,
        (lease) => f.credentials.guardOrdinaryPut(
          lease: lease,
          existing: before,
          proposed: proposed,
        ),
      );
      expect(_record(f)['active'], isFalse);
      expect(f.storage.operations.where((op) => op == 'write').length, 1);
      f.row =
          proposed; // Synthetic row only; this is not SQL composition evidence.
      expect(
        (await f.inspect()).state,
        NativeProviderCredentialState.conflicting,
      );
      f.row = before;
      f.ordinaryMutation();
      expect((await f.inspect()).state, NativeProviderCredentialState.disabled);
      await expectLater(
        f.store(),
        throwsNative(NativeProviderFailure.conflicting),
      );
      expect(f.storage.operations.where((op) => op == 'write').length, 1);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'native plaintext key, embedding and extras conflicts do not write',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final original = f.storage.values[f.nativeStorageKey];
      f.storage.operations.clear();
      for (final proposed in [
        f.row.copyWith(apiKey: 'TEST_ONLY_ROW_KEY'),
        f.row.copyWith(embeddingEnabled: true),
        f.row.copyWith(embeddingApiKey: 'TEST_ONLY_EMBEDDING_KEY'),
        f.row.copyWith(
          extraRequestParameters: const [
            ExtraRequestParameter(
              key: 'temperature',
              value: '1',
              enabled: false,
            ),
          ],
        ),
      ]) {
        await expectLater(
          _held(
            f,
            (lease) => f.credentials.guardOrdinaryPut(
              lease: lease,
              existing: f.row,
              proposed: proposed,
            ),
          ),
          throwsNative(NativeProviderFailure.conflicting),
        );
      }
      expect(f.storage.values[f.nativeStorageKey], original);
      expect(f.storage.operations.where((op) => op == 'write'), isEmpty);
    },
  );

  test(
    'known-secret display name is refused without saving a redaction marker',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      f.storage.operations.clear();
      await expectLater(
        _held(
          f,
          (lease) => f.credentials.guardOrdinaryPut(
            lease: lease,
            existing: f.row,
            proposed: f.row.copyWith(name: nativeCanary),
          ),
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.storage.operations.where((op) => op == 'write'), isEmpty);
      expect(_record(f)['active'], isTrue);
    },
  );

  test(
    'physical empty record is corruption, never native absence or SQL permission',
    () async {
      final f = NativeProviderFixture();
      f.storage.values[f.nativeStorageKey] = '';
      var syntheticSql = 0;
      await expectLater(
        _held(f, (lease) async {
          await f.credentials.guardOrdinaryPut(
            lease: lease,
            existing: f.row,
            proposed: f.row,
          );
          syntheticSql++;
        }),
        throwsNative(NativeProviderFailure.corrupt),
      );
      expect(syntheticSql, 0);
      expect(f.storage.operations.where((op) => op == 'write'), isEmpty);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'delete disables only affected record; fresh other-ID observation remains usable',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final first = f.row;
      final second = first.copyWith(id: 'native-other');
      f.row = second;
      await f.store();
      final secondKey = f.nativeStorageKey;
      final secondRecord = f.storage.values[secondKey];
      f.row = first;
      f.storage.operations.clear();
      await _held(
        f,
        (lease) => f.credentials.guardOrdinaryDelete(
          lease: lease,
          connectionId: first.id,
        ),
      );
      expect(_record(f)['active'], isFalse);
      expect(f.storage.values[secondKey], secondRecord);
      f.row = second;
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
      expect(f.storage.operations.where((op) => op == 'write').length, 1);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  test(
    'started vault disable settles but retired admission blocks subsequent SQL',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      var current = true;
      var syntheticSql = 0;
      f.storage.operations.clear();
      f.storage.beforeWrite = () async {
        current = false;
      };
      await expectLater(
        _held(f, (lease) async {
          await f.credentials.guardOrdinaryDelete(
            lease: lease,
            connectionId: f.row.id,
          );
          syntheticSql++;
        }, isCurrent: () => current),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(syntheticSql, 0);
      expect(_record(f)['active'], isFalse);
      expect(f.storage.operations.where((op) => op == 'write').length, 1);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
}
