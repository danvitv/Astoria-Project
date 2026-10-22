import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'helpers/support_native_fixture.dart';
import 'helpers/support_permission_database_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

void main() {
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
  });
  tearDown(() => f.close());
  Future<SupportNativeReview> review() async =>
      (await f.controller.prepareReview())!;

  test(
    'defaults independent safe views and explicit current recipient reconfirmation',
    () async {
      final r = await review();
      expect(r.view.rights.every((v) => !v.enabled), isTrue);
      expect(r.view.needsRecipientConfirmation, isTrue);
      expect(
        r.view.rights
            .firstWhere((v) => v.right == SupportPermission.readSafeSettings)
            .available,
        isTrue,
      );
      expect(
        r.view.rights
            .firstWhere((v) => v.right == SupportPermission.modelSupportHistory)
            .available,
        isFalse,
      );
      expect(
        r.view.rights
            .firstWhere((v) => v.right == SupportPermission.modelAttachments)
            .available,
        isFalse,
      );
      expect(await f.controller.confirmRecipient(r), isTrue);
      expect(f.controller.view.needsRecipientConfirmation, isFalse);
      expect(f.controller.view.toString(), 'SupportNativeView');
      expect(() => f.controller.view.rights.clear(), throwsUnsupportedError);
      expect(f.selectedLoads, 0);
    },
  );

  test(
    'two valid same-review queued independent toggles do not cancel one another',
    () async {
      final r = await review();
      f.database.repoA.pauseAdmission();
      final a = f.controller.setGrant(
        r,
        SupportPermission.readSafeSettings,
        true,
      );
      await f.database.repoA.entered!.future;
      final b = f.controller.setGrant(
        r,
        SupportPermission.confirmedSettingsChanges,
        true,
      );
      f.database.repoA.release!.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      final p = (await f.database.b.readForNative(
        NativeFixture.id,
      )).preferences!;
      expect(
        p.grants,
        containsAll([
          SupportPermission.readSafeSettings,
          SupportPermission.confirmedSettingsChanges,
        ]),
      );
    },
  );

  test(
    'independent adapter grant revision merges instead of full revision CAS',
    () async {
      final r = await review();
      final preserved = await f.database.preserved();
      f.database.repoA.pauseAdmission();
      final a = f.controller.setGrant(
        r,
        SupportPermission.readSafeSettings,
        true,
      );
      await f.database.repoA.entered!.future;
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      f.database.repoA.release!.complete();
      expect(await a, isTrue);
      expect(
        (await f.database.b.readForNative(
          NativeFixture.id,
        )).preferences!.grants,
        containsAll([
          SupportPermission.readSafeSettings,
          SupportPermission.confirmedSettingsChanges,
        ]),
      );
      expect(await f.database.preserved(), preserved);
    },
  );

  for (final replacement in ['scope', 'recipient', 'identity', 'missing']) {
    test(
      'latest reviewed $replacement mismatch refuses enable byte-for-byte',
      () async {
        final r = await review();
        f.database.repoA.pauseAdmission();
        final a = f.controller.setGrant(
          r,
          SupportPermission.readSafeSettings,
          true,
        );
        await f.database.repoA.entered!.future;
        switch (replacement) {
          case 'scope':
            await f.database.b.selectScopeFromNative(
              NativeFixture.id,
              SupportPermissionScope(
                selectionRevision: 3,
                safeCategories: [SupportSafeCategory.connections],
              ),
              isCurrent: () => true,
            );
          case 'recipient':
            await f.database.b.selectRecipientFromNative(
              NativeFixture.id,
              permissionRecipient(model: 'different-model'),
              isCurrent: () => true,
            );
          case 'identity':
            final old = (await f.database.b.readForNative(
              NativeFixture.id,
            )).preferences!;
            await f.database.repoB.putContextBlock(
              PermissionDatabaseFixture.codec.encode(
                SupportPermissionPreferences(
                  supportSessionId: old.supportSessionId,
                  policyIdentity: 'replacement-policy',
                  revision: 1,
                  scope: old.scope,
                  recipient: old.recipient,
                ),
                1,
              ),
            );
          case 'missing':
            await (f.database.db.delete(f.database.db.supportContextBlocks)
                  ..where(
                    (t) => t.id.equals(
                      PermissionDatabaseFixture.codec.idFor(NativeFixture.id),
                    ),
                  ))
                .go();
        }
        final bytes = await f.database.row();
        f.database.repoA.release!.complete();
        expect(await a, isFalse);
        expect(await f.database.row(), bytes);
      },
    );
  }

  test(
    'latest bindings permit revocation without broadening old reviewed scope',
    () async {
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.readSafeSettings,
        true,
        isCurrent: () => true,
      );
      final r = await review();
      await f.database.b.selectRecipientFromNative(
        NativeFixture.id,
        permissionRecipient(model: 'replacement'),
        isCurrent: () => true,
      );
      expect(
        await f.controller.setGrant(
          r,
          SupportPermission.readSafeSettings,
          false,
        ),
        isTrue,
      );
      expect(
        (await f.database.b.readForNative(
          NativeFixture.id,
        )).preferences!.allows(SupportPermission.readSafeSettings),
        isFalse,
      );
    },
  );

  for (final loss in ['switch', 'ABA', 'cancel', 'dispose', 'configuration']) {
    test(
      '$loss invalidates an admitted enable before latest-row write',
      () async {
        final r = await review();
        f.database.repoA.pauseAdmission();
        final a = f.controller.setGrant(
          r,
          SupportPermission.readSafeSettings,
          true,
        );
        await f.database.repoA.entered!.future;
        switch (loss) {
          case 'switch':
            f.runtime.selectSession('different-session');
          case 'ABA':
            f.runtime.selectSession('different-session');
            f.runtime.selectSession(NativeFixture.id);
          case 'cancel':
            f.controller.cancelReview();
          case 'dispose':
            f.runtime.dispose();
          case 'configuration':
            final settle = f.revisions.beginMutation();
            settle();
        }
        final bytes = await f.database.row();
        f.database.repoA.release!.complete();
        expect(await a, isFalse);
        expect(await f.database.row(), bytes);
      },
    );
  }

  test(
    'pending selection synchronously invalidates older confirmation',
    () async {
      final old = await review();
      f.database.repoA.pauseAdmission();
      final selection = f.controller.selectConnections(old, false);
      await f.database.repoA.entered!.future;
      expect(
        await f.controller.setGrant(
          old,
          SupportPermission.readSafeSettings,
          true,
        ),
        isFalse,
      );
      f.database.repoA.release!.complete();
      expect(await selection, isTrue);
    },
  );

  test(
    'missing review cannot replace policy initialized by another adapter',
    () async {
      await (f.database.db.delete(f.database.db.supportContextBlocks)..where(
            (t) => t.id.equals(
              PermissionDatabaseFixture.codec.idFor(NativeFixture.id),
            ),
          ))
          .go();
      final old = await review();
      await f.database.b.selectScopeFromNative(
        NativeFixture.id,
        SupportPermissionScope(
          selectionRevision: 1,
          safeCategories: [SupportSafeCategory.connections],
        ),
        isCurrent: () => true,
      );
      final bytes = await f.database.row();
      expect(await f.controller.selectConnections(old, false), isFalse);
      expect(await f.database.row(), bytes);
    },
  );

  test(
    'missing initialization is explicit conservative selection, no grants',
    () async {
      await (f.database.db.delete(f.database.db.supportContextBlocks)..where(
            (t) => t.id.equals(
              PermissionDatabaseFixture.codec.idFor(NativeFixture.id),
            ),
          ))
          .go();
      final r = await review();
      expect(
        await f.controller.setGrant(
          r,
          SupportPermission.readSafeSettings,
          true,
        ),
        isFalse,
      );
      expect(await f.controller.selectConnections(r, true), isTrue);
      final p = (await f.database.b.readForNative(
        NativeFixture.id,
      )).preferences!;
      expect(p.policyIdentity, isNot('missing'));
      expect(p.grants, isEmpty);
    },
  );

  for (final replacement in ['corrupt', 'healthy', 'missing', 'locked']) {
    test(
      'confirmed recovery only resets current corrupt not $replacement substitute',
      () async {
        await f.database.corrupt();
        final r = await review();
        expect(await f.controller.recoverToDeny(r, confirmed: false), isFalse);
        f.database.repoA.pauseAdmission();
        final recovery = f.controller.recoverToDeny(r, confirmed: true);
        await f.database.repoA.entered!.future;
        switch (replacement) {
          case 'corrupt':
            break;
          case 'healthy':
            await f.database.repoB.putContextBlock(
              PermissionDatabaseFixture.codec.encode(permissionPolicy(), 1),
            );
          case 'missing':
            await (f.database.db.delete(f.database.db.supportContextBlocks)
                  ..where(
                    (t) => t.id.equals(
                      PermissionDatabaseFixture.codec.idFor(NativeFixture.id),
                    ),
                  ))
                .go();
          case 'locked':
            await (f.database.db.update(f.database.db.supportContextBlocks)
                  ..where(
                    (t) => t.id.equals(
                      PermissionDatabaseFixture.codec.idFor(NativeFixture.id),
                    ),
                  ))
                .write(
                  const SupportContextBlocksCompanion(
                    protectedFactsCiphertext: Value('synthetic-locked'),
                  ),
                );
        }
        final bytes = await f.database.row(),
            preserved = await f.database.preserved();
        f.database.repoA.release!.complete();
        expect(await recovery, replacement == 'corrupt');
        if (replacement != 'corrupt') {
          expect(await f.database.row(), bytes);
        } else {
          expect(
            (await f.database.b.readForNative(
              NativeFixture.id,
            )).preferences!.grants,
            isEmpty,
          );
        }
        expect(await f.database.preserved(), preserved);
      },
    );
  }

  test(
    'message selection chooses exact eligible native order and empty stays empty',
    () async {
      final r = await review();
      final choice = (await f.controller.prepareMessages(
        r,
        SupportConsentSelectionSource.support,
        NativeFixture.id,
      ))!;
      expect(choice.page.items.single.messageId, 'synthetic-message');
      expect(
        await f.controller.selectMessages(choice, ['unseen-gap']),
        isFalse,
      );
      expect(await f.controller.selectMessages(choice, []), isTrue);
      expect(
        (await f.database.b.readForNative(
          NativeFixture.id,
        )).preferences!.scope!.supportHistory,
        isNull,
      );
      expect(f.selectedLoads, 0);
    },
  );

  test(
    'selection metadata reread refuses stale swipe and foreign support session',
    () async {
      var swipe = 1;
      f.messagesPort = (source, id, offset) async => SupportConsentMessagePage(
        source: source,
        sessionId: id,
        status: SupportConsentSelectionStatus.available,
        items: [
          SupportConsentMessageOption(
            sessionId: id,
            messageId: 'message-exact',
            role: SupportConsentSelectionRole.assistant,
            nativeOrder: 2,
            swipeId: swipe,
          ),
        ],
      );
      final r = await review();
      expect(
        await f.controller.prepareMessages(
          r,
          SupportConsentSelectionSource.support,
          'foreign',
        ),
        isNull,
      );
      final choice = (await f.controller.prepareMessages(
        r,
        SupportConsentSelectionSource.support,
        NativeFixture.id,
      ))!;
      swipe = 2;
      expect(
        await f.controller.selectMessages(choice, ['message-exact']),
        isFalse,
      );
    },
  );

  test(
    'configuration await at recipient confirmation refuses changed target',
    () async {
      final r = await review();
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.api.afterRead = () async {
        if (!paused) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final confirmation = f.controller.confirmRecipient(r);
      await entered.future;
      final settle = f.revisions.beginMutation();
      settle();
      release.complete();
      expect(await confirmation, isFalse);
      expect(f.controller.view.needsRecipientConfirmation, isTrue);
    },
  );

  test(
    'new native lifetime requires reconfirmation despite durable dependent grants',
    () async {
      expect(await f.controller.confirmRecipient(await review()), isTrue);
      expect(
        await f.controller.setGrant(
          await review(),
          SupportPermission.modelSupportHistory,
          true,
        ),
        isTrue,
      );
      f.runtime.selectSession(NativeFixture.id, force: true);
      final current = await review();
      expect(current.view.needsRecipientConfirmation, isTrue);
      expect(
        current.view.rights
            .firstWhere((v) => v.right == SupportPermission.modelSupportHistory)
            .enabled,
        isFalse,
      );
      expect(
        await f.controller.setGrant(
          current,
          SupportPermission.modelSupportHistory,
          true,
        ),
        isFalse,
      );
    },
  );

  test(
    'recipient commit checkpoint denies raw settings change during queued grant',
    () async {
      expect(await f.controller.confirmRecipient(await review()), isTrue);
      final r = await review();
      f.database.repoA.pauseAdmission();
      final enabling = f.controller.setGrant(
        r,
        SupportPermission.modelSupportHistory,
        true,
      );
      await f.database.repoA.entered!.future;
      await f.workspace.changeSettings(
        NativeFixture.id,
        (s) => s.copyWith(modelId: 'new-selected-model'),
      );
      f.database.repoA.release!.complete();
      expect(await enabling, isFalse);
      expect(f.controller.view.needsRecipientConfirmation, isTrue);
      expect(
        f.controller.view.rights
            .firstWhere((v) => v.right == SupportPermission.modelSupportHistory)
            .enabled,
        isFalse,
      );
    },
  );

  test(
    'exact chosen order omits gaps and attachments rather than expanding range',
    () async {
      f.messagesPort = (source, id, offset) async => SupportConsentMessagePage(
        source: source,
        sessionId: id,
        status: SupportConsentSelectionStatus.limited,
        sourceCount: 20,
        omittedCount: 5,
        limitedCount: 10,
        items: [
          for (final order in [0, 3, 8])
            SupportConsentMessageOption(
              sessionId: id,
              messageId: 'exact-$order',
              role: SupportConsentSelectionRole.user,
              nativeOrder: order,
            ),
        ],
      );
      final choice = (await f.controller.prepareMessages(
        await review(),
        SupportConsentSelectionSource.support,
        NativeFixture.id,
      ))!;
      expect(
        await f.controller.selectMessages(choice, ['exact-8', 'exact-0']),
        isTrue,
      );
      final scope = (await f.database.b.readForNative(
        NativeFixture.id,
      )).preferences!.scope!;
      expect(scope.supportHistory!.messageIds, ['exact-0', 'exact-8']);
      expect(scope.selectedData, isEmpty);
    },
  );

  test(
    'selector locked or unavailable parent never manufactures an intent',
    () async {
      for (final status in [
        SupportConsentSelectionStatus.parentLocked,
        SupportConsentSelectionStatus.unavailable,
      ]) {
        f.messagesPort = (source, id, offset) async =>
            SupportConsentMessagePage(
              source: source,
              sessionId: id,
              status: status,
              items: const [],
            );
        expect(
          await f.controller.prepareMessages(
            await review(),
            SupportConsentSelectionSource.support,
            NativeFixture.id,
          ),
          isNull,
        );
      }
    },
  );

  test(
    'prepare review cannot migrate to ABA session while resolver awaits',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.api.afterRead = () async {
        if (!paused) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final preparing = f.controller.prepareReview();
      await entered.future;
      f.runtime.selectSession('other');
      f.runtime.selectSession(NativeFixture.id);
      release.complete();
      expect(await preparing, isNull);
    },
  );

  for (final intent in ['scope', 'recipient']) {
    test(
      'queued $intent selection rejects latest changed reviewed binding',
      () async {
        final r = await review();
        f.database.repoA.pauseAdmission();
        final selection = intent == 'scope'
            ? f.controller.selectConnections(r, true)
            : f.controller.confirmRecipient(r);
        await f.database.repoA.entered!.future;
        if (intent == 'scope') {
          await f.database.b.selectScopeFromNative(
            NativeFixture.id,
            SupportPermissionScope(
              selectionRevision: 7,
              safeCategories: [SupportSafeCategory.connections],
            ),
            isCurrent: () => true,
          );
        } else {
          await f.database.b.selectRecipientFromNative(
            NativeFixture.id,
            permissionRecipient(model: 'replacement-model'),
            isCurrent: () => true,
          );
        }
        final bytes = await f.database.row();
        f.database.repoA.release!.complete();
        expect(await selection, isFalse);
        expect(await f.database.row(), bytes);
      },
    );
  }

  test(
    'independent recipient-dependent toggles use write ownership not lease epoch',
    () async {
      expect(await f.controller.confirmRecipient(await review()), isTrue);
      final r = await review();
      final results = await Future.wait([
        f.controller.setGrant(r, SupportPermission.modelSupportHistory, true),
        f.controller.setGrant(
          r,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
        ),
      ]);
      expect(results, [true, true]);
      final p = (await f.database.b.readForNative(
        NativeFixture.id,
      )).preferences!;
      expect(
        p.grants,
        containsAll([
          SupportPermission.modelSupportHistory,
          SupportPermission.modelSafeSettingsDiagnostics,
        ]),
      );
      expect(f.controller.view.needsRecipientConfirmation, isFalse);
    },
  );

  test(
    'reused game session or branch metadata cannot substitute same message IDs',
    () async {
      var character = 'original-character';
      f.messagesPort = (source, id, offset) async => SupportConsentMessagePage(
        source: source,
        sessionId: id,
        status: SupportConsentSelectionStatus.available,
        roleplaySession: SupportConsentSessionOption(
          sessionId: id,
          characterId: character,
          sessionIndex: 0,
          variantGroupId: 'group',
          variantOrder: 0,
          characterLabel: 'Synthetic',
          variantLabel: 'Original',
          messageCount: 1,
          status: SupportConsentSelectionStatus.available,
        ),
        items: [
          SupportConsentMessageOption(
            sessionId: id,
            messageId: 'shared-id',
            role: SupportConsentSelectionRole.user,
            nativeOrder: 0,
          ),
        ],
      );
      final choice = (await f.controller.prepareMessages(
        await review(),
        SupportConsentSelectionSource.roleplay,
        'game-session',
      ))!;
      character = 'replacement-character';
      expect(await f.controller.selectMessages(choice, ['shared-id']), isFalse);
      expect(
        (await f.database.b.readForNative(
          NativeFixture.id,
        )).preferences!.scope!.gameSessionId,
        isNull,
      );
    },
  );
}
