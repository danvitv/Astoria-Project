import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'helpers/support_permission_database_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

void main() {
  late PermissionDatabaseFixture f;
  const id = PermissionDatabaseFixture.id;
  const codec = PermissionDatabaseFixture.codec;
  setUp(() async {
    f = PermissionDatabaseFixture();
    await f.seed();
  });
  tearDown(() => f.close());
  test(
    'synthetic two encrypted adapters serialize concurrent grants on latest row preserving exact other ciphertext',
    () async {
      final before = await f.preserved();
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.primitive.afterEncrypt = (aad) async {
        if (!paused &&
            aad.contains(codec.idFor(id)) &&
            aad.endsWith('|summary_ciphertext')) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final a = f.a.setGrantFromNative(
        id,
        SupportPermission.readSafeSettings,
        true,
        isCurrent: PermissionDatabaseFixture.current,
      );
      await entered.future;
      final b = f.b.setGrantFromNative(
        id,
        SupportPermission.readDiagnostics,
        true,
        isCurrent: PermissionDatabaseFixture.current,
      );
      release.complete();
      await Future.wait([a, b]);
      final p = (await f.b.readForNative(id)).preferences!;
      expect(p.grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.readDiagnostics,
      });
      expect(p.revision, 4);
      expect(await f.preserved(), before);
      final row = (await f.row())!;
      expect(row.protectedFactsCiphertext, isNot(contains('readSafeSettings')));
      expect(row.protectedFactsCiphertext, isNot(contains('synthetic-game')));
      expect(
        row.summaryCiphertext,
        isNot(contains(SupportPermissionCodec.marker)),
      );
      expect(row.startMessageId, isEmpty);
      expect(row.endMessageId, isEmpty);
    },
  );
  test(
    'synthetic delayed adapter derives toggle from the latest row, no stale full-row snapshot',
    () async {
      f.repoA.pauseAdmission();
      final a = f.a.setGrantFromNative(
        id,
        SupportPermission.readSafeSettings,
        true,
        isCurrent: PermissionDatabaseFixture.current,
      );
      await f.repoA.entered!.future;
      await f.b.setGrantFromNative(
        id,
        SupportPermission.readDiagnostics,
        true,
        isCurrent: PermissionDatabaseFixture.current,
      );
      f.repoA.release!.complete();
      await a;
      expect((await f.b.readForNative(id)).preferences!.grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.readDiagnostics,
      });
    },
  );
  test(
    'synthetic missing policy denies and creates native consent only under surviving parent',
    () async {
      await (f.db.delete(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).go();
      final p = (await f.b.readForNative(id)).preferences!;
      expect(p.grants, isEmpty);
      expect(p.scope, isNull);
      await expectLater(
        f.a.setGrantFromNative(
          id,
          SupportPermission.modelGameHistory,
          true,
          isCurrent: PermissionDatabaseFixture.current,
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(await f.row(), isNull);
      await f.b.selectScopeFromNative(
        id,
        permissionScope(),
        isCurrent: PermissionDatabaseFixture.current,
      );
      expect((await f.b.readForNative(id)).preferences!.grants, isEmpty);
    },
  );
  test('synthetic support sessions cannot inherit scope or rights', () async {
    await f.b.setGrantFromNative(
      id,
      SupportPermission.modelGameHistory,
      true,
      isCurrent: PermissionDatabaseFixture.current,
    );
    await f.repoB.createSession(
      const SupportSession(
        id: 'synthetic-other',
        title: 'synthetic other',
        createdAt: 5,
        updatedAt: 5,
      ),
    );
    expect(
      (await f.b.readForNative('synthetic-other')).preferences!.grants,
      isEmpty,
    );
    expect(
      (await f.b.readForNative(
        id,
      )).preferences!.allows(SupportPermission.modelGameHistory),
      isTrue,
    );
  });
  for (final invalid in [
    'corrupt',
    'unknown-version',
    'locked-row',
    'locked-parent',
    'read-unavailable',
  ]) {
    test(
      'synthetic $invalid refuses normal edits with zero encryption and preserved bytes',
      () async {
        switch (invalid) {
          case 'corrupt':
            await f.corrupt();
          case 'unknown-version':
            await f.corrupt(unknownVersion: true);
          case 'locked-row':
            await (f.db.update(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).write(
              const SupportContextBlocksCompanion(
                protectedFactsCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'locked-parent':
            await (f.db.update(
              f.db.supportSessions,
            )..where((t) => t.id.equals(id))).write(
              const SupportSessionsCompanion(
                titleCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'read-unavailable':
            f.primitive.beforeDecrypt = (_) async {
              throw StateError('synthetic-read-failure');
            };
        }
        final before = await f.row(), other = await f.preserved();
        var encryptions = 0;
        f.primitive.afterEncrypt = (_) async {
          encryptions++;
        };
        await expectLater(
          f.a.setGrantFromNative(
            id,
            SupportPermission.confirmedSettingsChanges,
            true,
            isCurrent: PermissionDatabaseFixture.current,
          ),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
        expect(encryptions, 0);
        expect(await f.row(), before);
        expect(await f.preserved(), other);
        expect((await f.b.readForNative(id)).isAvailable, isFalse);
        if (invalid == 'locked-row' ||
            invalid == 'locked-parent' ||
            invalid == 'read-unavailable') {
          await expectLater(
            f.a.recoverToDenyFromNative(
              id,
              confirmed: true,
              isCurrent: PermissionDatabaseFixture.current,
            ),
            throwsA(isA<SupportPermissionsUnavailable>()),
          );
          expect(encryptions, 0);
          expect(await f.row(), before);
          expect(await f.preserved(), other);
        }
      },
    );
  }
  test(
    'synthetic delayed normal grant refuses deleted parent without recreating policy or history',
    () async {
      f.repoA.pauseAdmission();
      final pending = f.a.setGrantFromNative(
        id,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: PermissionDatabaseFixture.current,
      );
      final refusal = expectLater(
        pending,
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      await f.repoA.entered!.future;
      await f.repoB.deleteSession(id);
      f.repoA.release!.complete();
      await refusal;
      expect(await f.row(), isNull);
      expect(
        (await f.b.readForNative(id)).availability,
        SupportPermissionAvailability.unavailable,
      );
      expect(await f.preserved(), {
        'history': <Object>[],
        'others': <Object>[],
        'sessions': <Object>[],
      });
    },
  );
  for (final unknown in [false, true]) {
    test(
      'synthetic confirmed ${unknown ? 'unknown' : 'corrupt'} recovery resets only permission row to deny, new identity',
      () async {
        await f.b.setGrantFromNative(
          id,
          SupportPermission.modelGameHistory,
          true,
          isCurrent: PermissionDatabaseFixture.current,
        );
        final old = (await f.b.readForNative(id)).preferences!;
        await f.corrupt(unknownVersion: unknown);
        final before = await f.row(), others = await f.preserved();
        await expectLater(
          f.a.recoverToDenyFromNative(
            id,
            confirmed: false,
            isCurrent: PermissionDatabaseFixture.current,
          ),
          throwsStateError,
        );
        expect(await f.row(), before);
        final recovered = (await f.a.recoverToDenyFromNative(
          id,
          confirmed: true,
          isCurrent: PermissionDatabaseFixture.current,
        ))!;
        expect(recovered.policyIdentity, isNot(old.policyIdentity));
        expect(recovered.revision, 1);
        expect(recovered.grants, isEmpty);
        expect(recovered.scope, isNull);
        expect(recovered.recipient, isNull);
        expect(await f.preserved(), others);
      },
    );
  }
  for (final replacement in [
    'healthy',
    'missing',
    'locked-row',
    'locked-parent',
    'deleted-parent',
    'reparented',
  ]) {
    test(
      'synthetic deferred recovery refuses latest $replacement byte-for-byte',
      () async {
        await f.corrupt();
        f.repoA.pauseAdmission();
        final recovery = f.a.recoverToDenyFromNative(
          id,
          confirmed: true,
          isCurrent: PermissionDatabaseFixture.current,
        );
        final refusal = expectLater(
          recovery,
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
        await f.repoA.entered!.future;
        switch (replacement) {
          case 'healthy':
            await f.repoB.putContextBlock(
              codec.encode(
                permissionPolicy(grants: [SupportPermission.modelGameHistory]),
                1,
              ),
            );
          case 'missing':
            await (f.db.delete(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).go();
          case 'locked-row':
            await (f.db.update(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).write(
              const SupportContextBlocksCompanion(
                protectedFactsCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'locked-parent':
            await (f.db.update(
              f.db.supportSessions,
            )..where((t) => t.id.equals(id))).write(
              const SupportSessionsCompanion(
                titleCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'deleted-parent':
            await f.repoB.deleteSession(id);
          case 'reparented':
            await f.repoB.createSession(
              const SupportSession(
                id: 'synthetic-other',
                title: 'synthetic other',
                createdAt: 5,
                updatedAt: 5,
              ),
            );
            await (f.db.update(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).write(
              const SupportContextBlocksCompanion(
                sessionId: Value('synthetic-other'),
              ),
            );
        }
        final before = await f.row(), others = await f.preserved();
        f.repoA.release!.complete();
        await refusal;
        expect(await f.row(), before);
        expect(await f.preserved(), others);
      },
    );
  }
  for (final failure in [
    'cipher',
    'write',
    'mapped-read',
    'owner-read',
    'owner-encrypt',
    'owner-mapped-read',
  ]) {
    test(
      'synthetic $failure rolls back permission update/recovery, no history/settings changes',
      () async {
        await f.corrupt();
        final before = await f.row(), others = await f.preserved();
        var current = true, reads = 0;
        if (failure == 'write') {
          await f.db.customStatement(
            "CREATE TEMP TRIGGER synthetic_permission_failure BEFORE INSERT ON support_context_blocks BEGIN SELECT RAISE(ABORT, 'synthetic-permission-write-failure'); END",
          );
        }
        f.primitive.afterEncrypt = (aad) async {
          if (!aad.endsWith('|protected_facts_ciphertext')) return;
          if (failure == 'cipher') {
            throw StateError('synthetic-encrypt-failure');
          }
          if (failure == 'owner-encrypt') current = false;
        };
        f.primitive.beforeDecrypt = (aad) async {
          if (!aad.contains(codec.idFor(id))) return;
          reads++;
          if (failure == 'owner-read' && reads == 1) current = false;
          if (failure == 'owner-mapped-read' && reads == 3) current = false;
          if (failure == 'mapped-read' && reads == 3) {
            throw const SupportCipherException(
              SupportCipherFailure.authenticationFailed,
            );
          }
        };
        final operation = f.a.recoverToDenyFromNative(
          id,
          confirmed: true,
          isCurrent: () => current,
        );
        if (failure == 'owner-read') {
          expect(await operation, isNull);
        } else {
          await expectLater(
            operation,
            throwsA(isA<SupportPermissionsUnavailable>()),
          );
        }
        f.primitive.afterEncrypt = null;
        f.primitive.beforeDecrypt = null;
        expect(await f.row(), before);
        expect(await f.preserved(), others);
      },
    );
  }
}
