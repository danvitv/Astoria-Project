import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'support_theme_consent_fixture.dart';
import 'support_theme_consent_isolation.dart';

final class _ForgedIntent implements SupportNativeDisplayedIntent {}

SupportPermissionRecipient _recipient(ThemeConsentFixture f) =>
    SupportPermissionRecipient(
      connectionId: 'synthetic-connection',
      modelId: 'synthetic-model',
      protocol: SupportRecipientProtocol.openai,
      nativeRoute: 'https://synthetic.invalid/v1/chat/completions',
      configurationRevision: f.revisions.revision,
    );

void main() {
  themeConsentTest(
    'local review validates original issuer before any read',
    (f) async {
      final anchor = f.controller.view.displayedIntent;
      final other = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      final reads = f.sql.reads.length;
      expect(
        await other.prepareReview(
          displayedIntent: anchor,
          resolveRecipient: false,
        ),
        isNull,
      );
      expect(
        await f.controller.prepareReview(
          displayedIntent: _ForgedIntent(),
          resolveRecipient: false,
        ),
        isNull,
      );
      expect(f.sql.reads.length, reads);
      expect(f.resolverReads, 0);
      final review = await f.review();
      final row = await f.row();
      expect(await other.selectTheme(review, false), false);
      expect(
        await other.setGrant(review, SupportPermission.readSafeSettings, true),
        false,
      );
      expect(await f.row(), row);
    },
    scope: ThemeConsentFixture.scope(),
  );

  for (final loss in [
    'issuer',
    'cancel',
    'session-ABA',
    'configuration-ABA',
    'dispose',
  ]) {
    themeConsentTest(
      'local refresh retains original $loss before/after checks',
      (f) async {
        final anchor = f.controller.view.displayedIntent;
        final row = await f.row();
        final barrier = ThemeConsentBarrier();
        var paused = false;
        f.beforeDecrypt = (aad) async {
          if (!paused && aad.endsWith('|protected_facts_ciphertext')) {
            paused = true;
            await barrier.wait();
          }
        };
        final preparing = f.controller.prepareReview(
          displayedIntent: anchor,
          resolveRecipient: false,
        );
        try {
          await barrier.entered.future;
          switch (loss) {
            case 'issuer':
              f.controller.invalidateDisplayedIntents();
            case 'cancel':
              f.controller.cancelReview();
            case 'session-ABA':
              f.runtime.selectSession('synthetic-away');
              f.runtime.selectSession(ThemeConsentFixture.id);
            case 'configuration-ABA':
              f.revisions.beginMutation()();
            case 'dispose':
              f.runtime.dispose();
          }
        } finally {
          f.beforeDecrypt = null;
          barrier.release();
        }
        expect(await preparing, isNull);
        expect(await f.row(), row);
        expect(f.resolverReads, 0);
        expect(f.settingsReads, 0);
        expect(f.apiReads, 0);
        expect(f.metadataReads, 0);
      },
      scope: ThemeConsentFixture.scope(),
    );
  }

  for (final loss in ['issuer', 'cancel', 'session-ABA', 'dispose']) {
    themeConsentTest(
      'original $loss fences admitted local theme scope after real AEAD',
      (f) async {
        final review = await f.review();
        final row = await f.row();
        final barrier = ThemeConsentBarrier();
        f.primitive.afterEncrypt = (aad) async {
          if (aad.endsWith('|protected_facts_ciphertext')) await barrier.wait();
        };
        final selecting = f.controller.selectTheme(review, true);
        try {
          await barrier.entered.future;
          switch (loss) {
            case 'issuer':
              f.controller.invalidateDisplayedIntents();
            case 'cancel':
              f.controller.cancelReview();
            case 'session-ABA':
              f.runtime.selectSession('synthetic-away');
              f.runtime.selectSession(ThemeConsentFixture.id);
            case 'dispose':
              f.runtime.dispose();
          }
        } finally {
          f.primitive.afterEncrypt = null;
          barrier.release();
        }
        expect(await selecting, false);
        expect(await f.row(), row);
        expect(f.runtime.pending, 0);
        expect(f.resolverReads, 0);
      },
    );
  }

  themeConsentTest(
    'theme category ABA rejects original review and emitted anchor',
    (f) async {
      final old = await f.review();
      final anchor = old.view.displayedIntent;
      expect(await f.controller.selectTheme(old, false), true);
      expect(await f.controller.selectTheme(await f.review(), true), true);
      final row = await f.row();
      expect(f.controller.isDisplayedIntentCurrent(anchor), false);
      expect(await f.controller.selectTheme(old, false), false);
      expect(
        await f.controller.setGrant(
          old,
          SupportPermission.readSafeSettings,
          true,
        ),
        false,
      );
      expect(await f.row(), row);
      expect((await f.policy()).scope!.selectionRevision, 3);
    },
    scope: ThemeConsentFixture.scope(),
  );

  for (final replacement in ['scope-ABA', 'identity', 'recipient']) {
    themeConsentTest(
      'reviewed latest row rejects unobserved $replacement without rebinding',
      (f) async {
        final old = await f.review();
        switch (replacement) {
          case 'scope-ABA':
            await f.otherPermissions.selectScopeFromNative(
              ThemeConsentFixture.id,
              ThemeConsentFixture.scope(revision: 2, categories: []),
              isCurrent: () => true,
            );
            await f.otherPermissions.selectScopeFromNative(
              ThemeConsentFixture.id,
              ThemeConsentFixture.scope(revision: 3),
              isCurrent: () => true,
            );
          case 'identity':
            await f.replacePolicy(
              scope: ThemeConsentFixture.scope(),
              identity: 'replacement-policy',
            );
          case 'recipient':
            await f.otherPermissions.selectRecipientFromNative(
              ThemeConsentFixture.id,
              _recipient(f),
              isCurrent: () => true,
            );
        }
        final row = await f.row();
        expect(await f.controller.selectTheme(old, false), false);
        expect(await f.row(), row);
        expect(f.resolverReads, 0);
      },
      scope: ThemeConsentFixture.scope(),
    );
  }

  themeConsentTest(
    'same-binding grant revision merges with captured local review',
    (f) async {
      final review = await f.review();
      final anchor = review.view.displayedIntent;
      final owner = f.runtime.writeOwner;
      await f.otherPermissions.setGrantFromNative(
        ThemeConsentFixture.id,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      await f.runtime.refresh();
      expect(f.runtime.writeOwner, owner);
      expect(f.controller.isDisplayedIntentCurrent(anchor), true);
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        true,
      );
      expect((await f.policy()).grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
      });
      expect(f.resolverReads, 0);
    },
    scope: ThemeConsentFixture.scope(),
  );

  themeConsentTest(
    'independent same-review grants still merge during local AEAD wait',
    (f) async {
      final review = await f.review();
      final barrier = ThemeConsentBarrier();
      var paused = false;
      f.primitive.afterEncrypt = (aad) async {
        if (!paused && aad.endsWith('|protected_facts_ciphertext')) {
          paused = true;
          await barrier.wait();
        }
      };
      final read = f.controller.setGrant(
        review,
        SupportPermission.readSafeSettings,
        true,
      );
      Future<bool>? change;
      try {
        await barrier.entered.future;
        change = f.controller.setGrant(
          review,
          SupportPermission.confirmedSettingsChanges,
          true,
        );
      } finally {
        f.primitive.afterEncrypt = null;
        barrier.release();
      }
      expect(await read, true);
      expect(await change, true);
      expect((await f.policy()).grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
      });
      expect(f.resolverReads, 0);
    },
    scope: ThemeConsentFixture.scope(),
  );

  themeConsentTest(
    'default prepareReview remains recipient-resolving for old callers',
    (f) async {
      f.allowResolver = true;
      final review = (await f.controller.prepareReview(
        displayedIntent: f.controller.view.displayedIntent,
      ))!;
      expect(f.resolverReads, 1);
      expect(f.settingsReads, 2);
      expect(f.apiReads, 1);
      expect(review.view.needsRecipientConfirmation, true);
      expect(f.runtime.recipientConfirmed, false);
      expect((await f.policy()).grants, isEmpty);
      expect((await f.policy()).recipient, isNull);
    },
    scope: ThemeConsentFixture.scope(),
  );

  for (final right in [
    SupportPermission.modelSafeSettingsDiagnostics,
    SupportPermission.modelSupportHistory,
    SupportPermission.confirmedConnectionTests,
  ]) {
    themeConsentTest(
      'no-recipient local review cannot enable ${right.name}',
      (f) async {
        final review = await f.review();
        final row = await f.row();
        expect(await f.controller.setGrant(review, right, true), false);
        expect(await f.row(), row);
        expect(f.resolverReads, 0);
      },
      scope: ThemeConsentFixture.scope(histories: true),
    );
  }

  for (final right in [
    SupportPermission.modelSupportHistory,
    SupportPermission.confirmedConnectionTests,
  ]) {
    themeConsentTest(
      'local review keeps original unavailable ${right.name} despite later confirmation',
      (f) async {
        await f.replacePolicy(
          scope: ThemeConsentFixture.scope(histories: true),
          recipient: _recipient(f),
        );
        await f.runtime.refresh();
        final review = await f.review();
        f.allowResolver = true;
        await f.runtime.refresh(resolve: true);
        f.runtime.recipientConfirmed = true;
        final row = await f.row();
        final reads = f.resolverReads;
        expect(await f.controller.setGrant(review, right, true), false);
        expect(await f.row(), row);
        expect(
          f.resolverReads,
          reads,
          reason: 'Original review availability is mandatory',
        );
      },
    );

    themeConsentTest(
      'available local review still resolves current ${right.name} before grant',
      (f) async {
        await f.replacePolicy(
          scope: ThemeConsentFixture.scope(histories: true),
          recipient: _recipient(f),
        );
        await f.runtime.refresh();
        f.allowResolver = true;
        await f.runtime.refresh(resolve: true);
        f.runtime.recipientConfirmed = true;
        final review = await f.review();
        expect(
          review.view.rights.firstWhere((v) => v.right == right).available,
          true,
        );
        // Synthetic raw settings change deliberately misses a configuration fence;
        // the original current resolver must still refuse the local-review grant.
        f.recipientSettings = const SupportAssistantSettings();
        final row = await f.row();
        final reads = f.resolverReads;
        expect(await f.controller.setGrant(review, right, true), false);
        expect(f.resolverReads, reads + 1);
        expect(await f.row(), row);
        expect((await f.policy()).grants, isEmpty);
      },
    );
  }

  themeConsentTest(
    'explicit theme alone never offers model-safe sharing with confirmed recipient',
    (f) async {
      await f.replacePolicy(
        scope: ThemeConsentFixture.scope(),
        recipient: _recipient(f),
      );
      await f.runtime.refresh();
      f.allowResolver = true;
      await f.runtime.refresh(resolve: true);
      f.runtime.recipientConfirmed = true;
      final review = await f.review();
      expect(
        review.view.rights
            .firstWhere(
              (v) => v.right == SupportPermission.modelSafeSettingsDiagnostics,
            )
            .available,
        false,
      );
      final row = await f.row();
      final reads = f.resolverReads;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
        ),
        false,
      );
      expect(f.resolverReads, reads);
      expect(await f.row(), row);
    },
  );
}
