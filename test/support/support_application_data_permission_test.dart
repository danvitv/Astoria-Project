import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import 'helpers/support_model_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = SupportPermissionCodec();
  const right = SupportPermission.readApplicationData;
  SupportPermissionPreferences policy({bool grant = true}) =>
      SupportPermissionPreferences(
        supportSessionId: 'session',
        policyIdentity: 'global-native',
        revision: 1,
        grants: grant ? [right] : const [],
      );

  test(
    'new exact codec grants broad consent without scope/recipient; legacy never opts in',
    () {
      final p = policy();
      expect(p.hasScopeFor(right), true);
      final block = codec.encodeGlobal(p, 1);
      final decoded = codec.decodeGlobal('other-session', block);
      expect(decoded.isGlobal, true);
      expect(decoded.allows(right), true);
      expect(decoded.scope, isNull);
      expect(decoded.recipient, isNull);
      expect(
        jsonDecode(
          jsonDecode(block.protectedFactsJson)['policy'] as String,
        )['version'],
        3,
      );
      for (final legacy in [
        permissionPolicy(),
        permissionPolicy(
          scope: SupportPermissionScope(
            selectionRevision: 1,
            gameSessionId: 'game',
            gameHistoryExtent: SupportHistoryExtent.wholeSession,
          ),
        ),
      ]) {
        final stored = codec.encodeGlobal(legacy, 1);
        final old = codec.decodeGlobal('session', stored);
        expect(old.allows(right), false);
      }
    },
  );

  test(
    'scope and recipient edits preserve app-wide consent; one revoke removes it',
    () {
      final p = policy();
      final next = p
          .withNativeScope(permissionScope())
          .withNativeRecipient(permissionRecipient());
      expect(next.allows(right), true);
      expect(
        next.withNativeScope(null).withNativeRecipient(null).allows(right),
        true,
      );
      expect(next.withNativeGrant(right, false).allows(right), false);
    },
  );

  test(
    'application OFF drops hidden legacy read/model grants without broadening action/report rights',
    () {
      final legacy = permissionPolicy(
        grants: [
          SupportPermission.readGameData,
          SupportPermission.modelGameHistory,
          SupportPermission.confirmedSettingsChanges,
          SupportPermission.reportGameHistory,
        ],
      );
      final global = codec.decodeGlobal(
        'session',
        codec.encodeGlobal(legacy, 1),
      );
      final revoked = global.withNativeGrant(right, false);
      expect(revoked.allows(SupportPermission.readGameData), false);
      expect(revoked.allows(SupportPermission.modelGameHistory), false);
      expect(revoked.allows(SupportPermission.confirmedSettingsChanges), true);
      expect(revoked.allows(SupportPermission.reportGameHistory), true);
      final enabled = global.withNativeGrant(right, true);
      expect(enabled.allows(right), true);
      expect(enabled.allows(SupportPermission.modelGameHistory), false);
    },
  );

  test(
    'new invalid/nonboolean/missing/duplicate/legacy smuggled rights fail closed',
    () {
      final block = codec.encode(policy(), 1);
      for (final change in <void Function(Map<String, dynamic>)>[
        (m) => (m['grants'] as Map).remove(right.name),
        (m) => (m['grants'] as Map)[right.name] = 'true',
        (m) => (m['grants'] as Map)['unknown'] = true,
        (m) => m['version'] = 1,
        (m) => m['version'] = 99,
      ]) {
        final data =
            jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
        change(data);
        expect(
          () => codec.decode(
            'session',
            block.copyWith(protectedFactsJson: jsonEncode(data)),
          ),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
      }
      expect(
        () => codec.decode(
          'session',
          block.copyWith(
            protectedFactsJson: block.protectedFactsJson.replaceFirst(
              '"readApplicationData":true',
              '"readApplicationData":false,"readApplicationData":true',
            ),
          ),
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(
        () => codec.decode('session', block.copyWith(isLocked: true)),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
    },
  );

  test(
    'global encrypted persistence/revoke never falls back to legacy grants',
    () async {
      final f = await SupportModelFixture.create();
      try {
        await f.store.setGrantFromNative(
          'session',
          right,
          true,
          isCurrent: () => true,
        );
        final global = await f.repo.getContextBlockById(
          SupportPermissionCodec.globalId,
        );
        expect(codec.decodeGlobal('session', global!).allows(right), true);
        final raw =
            await (f.db.select(f.db.supportContextBlocks)
                  ..where((t) => t.id.equals(SupportPermissionCodec.globalId)))
                .getSingle();
        // No broad consent row is allowed in per-chat storage by the native store.
        final legacy = await f.repo.getContextBlockById(codec.idFor('session'));
        expect(codec.decode('session', legacy).allows(right), false);
        expect(
          raw.protectedFactsCiphertext,
          isNot(contains('readApplicationData')),
        );
        await f.store.setGrantFromNative(
          'session',
          right,
          false,
          isCurrent: () => true,
        );
        expect(
          (await f.store.readForNative('session')).preferences!.allows(right),
          false,
        );
        await (f.db.delete(
          f.db.supportContextBlocks,
        )..where((t) => t.id.equals(SupportPermissionCodec.globalId))).go();
        expect((await f.store.readForNative('session')).isAvailable, false);
        final production = SupportPermissionStore(
          f.repo,
          initializeGlobalOnRefresh: true,
        );
        expect((await production.readForNative('session')).isAvailable, false);
      } finally {
        await f.close();
      }
    },
  );
}
