import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart' as db;
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_send_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'helpers/support_native_fixture.dart';
import 'helpers/workspace_test_harness.dart';

void main() {
  late NativeFixture f;
  late WorkspaceHarness h;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
    final store = ControlledWorkspaceStore(f.database.repoB);
    store.sessions.clear();
    store.messages.clear();
    store.availability.clear();
    store.addSession(NativeFixture.id);
    store.addSession('b');
    h = WorkspaceHarness(
      store: store,
      native: f.runtime,
      database: f.database.db,
      repository: f.database.repoB,
    );
    await h.settle();
  });
  tearDown(() async {
    await h.close();
    await f.close();
  });
  Future<void> grant() => f.database.b.setGrantFromNative(
    NativeFixture.id,
    SupportPermission.readSafeSettings,
    true,
    isCurrent: () => true,
  );

  for (final denial in ['missing', 'grant', 'category', 'corrupt', 'locked']) {
    test(
      'actual diagnostic topic $denial denies BEFORE metadata even with model/report/history grants',
      () async {
        await f.database.b.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
          isCurrent: () => true,
        );
        await f.database.b.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.modelSupportHistory,
          true,
          isCurrent: () => true,
        );
        await f.database.b.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.reportSupportHistory,
          true,
          isCurrent: () => true,
        );
        switch (denial) {
          case 'missing':
            await (f.database.db.delete(f.database.db.supportContextBlocks)
                  ..where(
                    (t) => t.id.equals(
                      'workspace-permissions-v1:${NativeFixture.id}',
                    ),
                  ))
                .go();
          case 'grant':
            break;
          case 'category':
            await f.database.b.selectScopeFromNative(
              NativeFixture.id,
              SupportPermissionScope(
                selectionRevision: 3,
                safeCategories: [SupportSafeCategory.theme],
              ),
              isCurrent: () => true,
            );
            await grant();
          case 'corrupt':
            await f.database.corrupt();
          case 'locked':
            await (f.database.db.update(f.database.db.supportContextBlocks)
                  ..where(
                    (t) => t.id.equals(
                      'workspace-permissions-v1:${NativeFixture.id}',
                    ),
                  ))
                .write(
                  const SupportContextBlocksCompanion(
                    protectedFactsCiphertext: Value('synthetic-locked'),
                  ),
                );
        }
        f.api.ids.clear();
        expect(
          await h.notifier.triggerQuickAction('connection_diagnostics'),
          isTrue,
        );
        expect(f.selectedLoads, 0);
        expect(f.api.ids, isEmpty);
        expect(f.api.bulkReads, 0);
        expect(f.inspection, isNull);
        final card =
            h.state.activeMessages.single.cards.single as DiagnosticCheckCard;
        expect(card.findings, isEmpty);
        expect(card.status, SupportCheckStatus.missingEvidence);
        expect(
          h.state.activeMessages.single.body,
          isNot(contains('Показаны только метаданные')),
        );
      },
    );
  }

  test(
    'actual granted send selected-only safe current-redactor DTO stays transient',
    () async {
      await grant();
      expect(await h.notifier.sendUserMessage('помоги настроить api'), isTrue);
      expect(f.selectedLoads, 1);
      expect(f.api.ids, isNotEmpty);
      expect(f.api.ids.toSet(), {'synthetic-connection'});
      expect(f.api.bulkReads, 0);
      final inspected = f.inspection!;
      expect(inspected.connectionLabel, 'Synthetic selected connection');
      expect(inspected.configured, isTrue);
      expect(inspected.characterCount, NativeFixture.canary.runes.length);
      expect(inspected.toString(), 'SupportConnectionInspection');
      expect(h.state.activeMessages.length, 2);
      final card = h.state.activeMessages.last.cards.single as SetupActionCard;
      expect(card.credentialMetadata, isNull);
      expect(
        h.state.activeMessages.last.body,
        isNot(contains(inspected.connectionLabel)),
      );
      final r = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          r,
          SupportPermission.readSafeSettings,
          false,
        ),
        isTrue,
      );
      expect(f.inspection, isNull);
      expect(h.state.activeMessages.length, 2); // Public history is unaffected.
    },
  );

  for (final change in [
    'revoke',
    'scope',
    'settings-failure',
    'configuration',
    'switch',
    'rebuild',
    'cancel',
  ]) {
    test(
      'actual send $change during selected loader cannot publish transient result',
      () async {
        await grant();
        final gate = WorkspaceGate();
        f.beforeSelected = gate.wait;
        final send = h.notifier.sendUserMessage('помоги настроить api');
        await gate.entered.future;
        switch (change) {
          case 'revoke':
            final r = (await f.controller.prepareReview())!;
            await f.controller.setGrant(
              r,
              SupportPermission.readSafeSettings,
              false,
            );
          case 'scope':
            final r = (await f.controller.prepareReview())!;
            await f.controller.selectConnections(r, false);
          case 'settings-failure':
            h.store.failures.add('change-before');
            final settings = h.notifier.selectModel('changed-model');
            expect(f.runtime.recipientConfirmed, isFalse);
            gate.release.complete();
            await send;
            expect(await settings, isFalse);
          case 'configuration':
            final settle = f.revisions.beginMutation();
            settle();
          case 'switch':
            h.notifier.selectSession('b');
          case 'rebuild':
            h.container.invalidate(supportWorkspaceProvider);
            await h.settle();
          case 'cancel':
            f.controller.cancelReview();
        }
        if (!gate.release.isCompleted) gate.release.complete();
        expect(await send, isTrue); // Already durable user acceptance survives.
        await h.settle();
        expect(f.inspection, isNull);
        for (final message in h.store.messages[NativeFixture.id]!) {
          expect(
            message.body,
            isNot(contains('Synthetic selected connection')),
          );
          for (final card in message.cards.whereType<SetupActionCard>()) {
            expect(card.credentialMetadata, isNull);
          }
        }
      },
    );
  }

  test(
    'revocation before lease loader gives zero selected loader calls',
    () async {
      await grant();
      final gate = h.store.gates['user-after'] = WorkspaceGate();
      final send = h.notifier.sendUserMessage('api');
      await gate.entered.future;
      final r = (await f.controller.prepareReview())!;
      await f.controller.setGrant(r, SupportPermission.readSafeSettings, false);
      gate.release.complete();
      expect(await send, isTrue);
      expect(f.selectedLoads, 0);
    },
  );

  test(
    'recipient settings existence adapter refuses deleted locked and corrupt without history loading',
    () async {
      final target = await f.workspace.create(
        'Synthetic exact settings target',
      );
      expect(await f.workspace.readableSettingsFor(target), isNotNull);
      await f.database.repoB.deleteSession(target);
      expect(await f.workspace.readableSettingsFor(target), isNull);
      expect(await f.workspace.readableSettingsFor('missing-exact'), isNull);
      await f.database.repoB.putContextBlock(
        const db.SupportContextBlock(
          id: 'workspace-settings-v1:${NativeFixture.id}',
          sessionId: NativeFixture.id,
          startMessageId: '',
          endMessageId: '',
          summary: 'workspace-settings-v1',
          protectedFactsJson: 'synthetic-corrupt',
          createdAt: 1,
        ),
      );
      expect(await f.workspace.readableSettingsFor(NativeFixture.id), isNull);
      expect(
        (await f.database.repoB.getMessagesForSession(
          NativeFixture.id,
        )).single.body,
        contains('SYNTHETIC_PERMISSION_CANARY'),
      );
    },
  );

  test(
    'configuration pending and unavailable recipient never manufacture confirmation',
    () async {
      final settle = f.revisions.beginMutation();
      final r = (await f.controller.prepareReview())!;
      expect(r.view.recipient, isA<SupportRecipientUnavailable>());
      expect(await f.controller.confirmRecipient(r), isFalse);
      settle();
      expect(f.controller.view.needsRecipientConfirmation, isTrue);
    },
  );

  test(
    'real encrypted sender persists public guidance not inspected provenance',
    () async {
      await grant();
      await f.runtime.refresh();
      final published = <SupportMessageItem>[];
      var acceptedUser = false, acceptedReply = false;
      await SupportWorkspaceSendService(
        store: f.workspace,
        isCurrent: () => true,
        publish: published.add,
        acceptUser: () => acceptedUser = true,
        acceptReply: () => acceptedReply = true,
        inspectConnection: f.runtime.inspectSelectedConnection,
      ).send(NativeFixture.id, text: 'Synthetic current request api');
      expect(acceptedUser && acceptedReply, isTrue);
      expect(f.inspection, isNotNull);
      expect(published.length, 2);
      final durable = await f.database.repoB.getMessagesForSession(
        NativeFixture.id,
      );
      expect(durable.length, 3);
      expect(durable.last.body, isNot(contains(f.inspection!.connectionLabel)));
      expect(durable.last.cardsJson, isNot(contains(NativeFixture.canary)));
      expect(durable.last.cardsJson, isNot(contains('characterCount')));
    },
  );

  test(
    'revocation during reply append clears published transient result, durable guidance stays public',
    () async {
      await grant();
      final gate = h.store.gates['reply-before'] = WorkspaceGate();
      final send = h.notifier.sendUserMessage('api');
      await gate.entered.future;
      expect(f.inspection, isNotNull);
      final r = (await f.controller.prepareReview())!;
      await f.controller.setGrant(r, SupportPermission.readSafeSettings, false);
      expect(f.inspection, isNull);
      gate.release.complete();
      expect(await send, isTrue);
      expect(
        (h.state.activeMessages.last.cards.single as SetupActionCard)
            .credentialMetadata,
        isNull,
      );
    },
  );

  test(
    'current redactor rotates while actual selected API read awaits',
    () async {
      await grant();
      var rotated = false;
      f.api.afterRead = () async {
        if (!rotated) {
          rotated = true;
          f.redactor = SecretRedactor(
            knownSecrets: [
              NativeFixture.canary,
              'Synthetic selected connection',
            ],
          );
        }
      };
      expect(
        await h.notifier.triggerQuickAction('connection_diagnostics'),
        isTrue,
      );
      expect(f.inspection, isNotNull);
      expect(
        f.inspection!.connectionLabel,
        isNot(contains('Synthetic selected connection')),
      );
      expect(f.selectedLoads, 1);
      expect(f.api.bulkReads, 0);
    },
  );

  test(
    'failed generation write and failed dependent-clear never restore old recipient authority',
    () async {
      expect(
        await f.controller.confirmRecipient(
          (await f.controller.prepareReview())!,
        ),
        isTrue,
      );
      final old = (await f.controller.prepareReview())!;
      await grant();
      final gate = h.store.gates['change-before'] = WorkspaceGate();
      h.store.failures.add('change-before');
      f.database.primitive.afterEncrypt = (aad) async {
        if (aad.contains('workspace-permissions-v1:')) {
          throw StateError('synthetic-clear-failure');
        }
      };
      final settings = h.notifier.selectModel('changed-model');
      expect(f.runtime.recipientConfirmed, isFalse);
      await gate.entered.future;
      expect(f.runtime.settingsPending, 1);
      expect(
        await f.runtime.inspectSelectedConnection(NativeFixture.id, () => true),
        isFalse,
      );
      expect(f.selectedLoads, 0);
      expect(await f.controller.confirmRecipient(old), isFalse);
      gate.release.complete();
      expect(await settings, isFalse);
      f.database.primitive.afterEncrypt = null;
      expect(f.runtime.settingsPending, 0);
      expect(f.controller.view.needsRecipientConfirmation, isTrue);
      expect(f.inspection, isNull);
      expect(h.state.error, isNot(contains('synthetic-clear-failure')));
    },
  );

  test(
    'revocation at exact settings-loader await prevents the next selected API metadata read',
    () async {
      await grant();
      final gate = WorkspaceGate();
      f.settingsPort = (id) async {
        final selected = await f.workspace.readableSettingsFor(id);
        if (f.settingsReads == 3) await gate.wait();
        return selected;
      };
      final send = h.notifier.sendUserMessage('api');
      await gate.entered.future;
      expect(f.api.ids, [
        'synthetic-connection',
      ]); // Resolver row, not the metadata row.
      f.runtime.invalidateLease();
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.readSafeSettings,
        false,
        isCurrent: () => true,
      );
      gate.release.complete();
      expect(await send, isTrue);
      expect(f.api.ids, ['synthetic-connection']);
      expect(f.inspection, isNull);
    },
  );
}
