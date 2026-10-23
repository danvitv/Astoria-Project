import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'support_theme_consent_fixture.dart';

SupportNativeRightView _right(
  SupportNativeView view,
  SupportPermission right,
) => view.rights.firstWhere((v) => v.right == right);

void main() {
  themeConsentTest('theme view and empty scope defaults remain OFF', (f) async {
    final view = f.controller.view;
    expect(view.themeSelected, false);
    expect(view.connectionsSelected, false);
    expect(view.rights.every((v) => !v.enabled), true);
    expect(_right(view, SupportPermission.readSafeSettings).available, false);
    expect(
      await f.runtime.authorization.prepare(
        supportSessionId: ThemeConsentFixture.id,
        use: SupportPermissionUse.localRead,
        sources: [
          SupportPermissionSource.safeProjection(
            ThemeConsentFixture.id,
            SupportSafeCategory.theme,
          ),
        ],
      ),
      isNull,
    );
    final review = await f.review();
    final row = await f.row();
    expect(
      await f.controller.setGrant(
        review,
        SupportPermission.readSafeSettings,
        true,
      ),
      false,
    );
    expect(await f.row(), row);
    expect(f.resolverReads, 0);
    expect(f.settingsReads, 0);
    expect(f.apiReads, 0);
    expect(f.metadataReads, 0);
    final compatible = SupportNativeView(
      sessionId: view.sessionId,
      availability: view.availability,
      busy: view.busy,
      recipient: view.recipient,
      needsRecipientConfirmation: view.needsRecipientConfirmation,
      rights: view.rights,
    );
    expect(compatible.themeSelected, false);
    expect(compatible.toString(), 'SupportNativeView');
  });

  for (final category in SupportSafeCategory.values) {
    final implemented =
        category == SupportSafeCategory.theme ||
        category == SupportSafeCategory.connections;
    themeConsentTest(
      'local availability is implemented explicit ${category.name} only',
      (f) async {
        final review = await f.review();
        expect(
          review.view.themeSelected,
          category == SupportSafeCategory.theme,
        );
        expect(
          review.view.connectionsSelected,
          category == SupportSafeCategory.connections,
        );
        expect(
          _right(review.view, SupportPermission.readSafeSettings).available,
          implemented,
        );
        expect(
          _right(
            review.view,
            SupportPermission.modelSafeSettingsDiagnostics,
          ).available,
          false,
        );
        expect(
          _right(
            review.view,
            SupportPermission.confirmedSettingsChanges,
          ).enabled,
          false,
        );
        expect(review.view.rights.every((v) => !v.enabled), true);
        final row = await f.row();
        final source = SupportPermissionSource.safeProjection(
          ThemeConsentFixture.id,
          category,
        );
        expect(
          await f.runtime.authorization.prepare(
            supportSessionId: ThemeConsentFixture.id,
            use: SupportPermissionUse.localRead,
            sources: [source],
          ),
          isNull,
          reason: 'Selected category alone grants no reading right',
        );
        expect(
          await f.controller.setGrant(
            review,
            SupportPermission.readSafeSettings,
            true,
          ),
          implemented,
        );
        if (!implemented) expect(await f.row(), row);
        final policy = await f.policy();
        expect(
          policy.grants,
          implemented ? {SupportPermission.readSafeSettings} : isEmpty,
        );
        for (final right in [
          SupportPermission.reportGameHistory,
          SupportPermission.reportSupportHistory,
          SupportPermission.reportPersonalDataAttachments,
          SupportPermission.confirmedSettingsChanges,
        ]) {
          expect(policy.allows(right), false);
          expect(_right(f.controller.view, right).enabled, false);
        }
        expect(policy.recipient, isNull);
        expect(f.runtime.recipientConfirmed, false);
        expect(f.resolverReads, 0);
        expect(f.settingsReads, 0);
        expect(f.apiReads, 0);
        expect(f.metadataReads, 0);
        expect(
          f.sql.reads.where((sql) => sql.contains('support_messages')),
          isEmpty,
        );
        final rowBeforeSourceChecks = await f.row();
        expect(
          source.allowedFor(policy, SupportPermissionUse.modelContext),
          false,
        );
        // Exact-category safe projection is report-source eligibility only:
        // exact sanitized report approval is still required separately, with
        // no local/model grant or settings effect inferred from this result.
        expect(
          source.allowedFor(policy, SupportPermissionUse.reportPreparation),
          true,
        );
        expect(await f.row(), rowBeforeSourceChecks);
        if (category == SupportSafeCategory.theme) {
          expect(
            source.allowedFor(policy, SupportPermissionUse.localRead),
            true,
          );
          expect(await f.row(), rowBeforeSourceChecks);
          expect(
            await f.runtime.authorization.prepare(
              supportSessionId: ThemeConsentFixture.id,
              use: SupportPermissionUse.localRead,
              sources: [source],
            ),
            isNotNull,
            reason: 'Permission metadata only; no theme loader',
          );
          // Read scope does not make connection inspection available.
          expect(
            await f.runtime.inspectSelectedConnection(
              ThemeConsentFixture.id,
              () => true,
            ),
            false,
          );
        }
        if (category == SupportSafeCategory.connections) {
          expect(
            await f.runtime.authorization.prepare(
              supportSessionId: ThemeConsentFixture.id,
              use: SupportPermissionUse.localRead,
              sources: [
                SupportPermissionSource.safeProjection(
                  ThemeConsentFixture.id,
                  SupportSafeCategory.theme,
                ),
              ],
            ),
            isNull,
            reason:
                'Connection read right cannot substitute for explicit theme scope',
          );
        }
      },
      scope: ThemeConsentFixture.scope(categories: [category]),
    );
  }

  themeConsentTest(
    'missing row initializes explicit theme scope without granting',
    (f) async {
      await (f.db.delete(f.db.supportContextBlocks)..where(
            (t) => t.id.equals(
              ThemeConsentFixture.codec.idFor(ThemeConsentFixture.id),
            ),
          ))
          .go();
      await f.runtime.refresh();
      final review = await f.review();
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        false,
      );
      expect(await f.controller.selectTheme(review, true), true);
      final policy = await f.policy();
      expect(policy.policyIdentity, 'local-policy');
      expect(policy.grants, isEmpty);
      expect(policy.scope!.safeCategories, {SupportSafeCategory.theme});
      expect(policy.recipient, isNull);
      expect(f.resolverReads, 0);
    },
  );

  themeConsentTest(
    'selection and read grant remain independent from settings changes',
    (f) async {
      expect(await f.controller.selectTheme(await f.review(), true), true);
      expect((await f.policy()).grants, isEmpty);
      expect(f.controller.view.themeSelected, true);
      expect(
        await f.controller.setGrant(
          await f.review(),
          SupportPermission.readSafeSettings,
          true,
        ),
        true,
      );
      expect(
        _right(
          f.controller.view,
          SupportPermission.confirmedSettingsChanges,
        ).enabled,
        false,
      );
      expect(
        await f.controller.setGrant(
          await f.review(),
          SupportPermission.confirmedSettingsChanges,
          true,
        ),
        true,
      );
      expect((await f.policy()).grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
      });
      expect(await f.controller.selectTheme(await f.review(), false), true);
      expect((await f.policy()).grants, {
        SupportPermission.confirmedSettingsChanges,
      });
      expect(
        _right(f.controller.view, SupportPermission.readSafeSettings).available,
        false,
      );
      expect(f.resolverReads, 0);
      expect(f.metadataReads, 0);
    },
  );

  for (final loss in [
    'unavailable',
    'locked',
    'corrupt',
    'configuration',
    'pending',
    'settings-pending',
  ]) {
    themeConsentTest(
      'current local availability retains $loss denial',
      (f) async {
        final original = await f.review();
        void Function()? settle;
        switch (loss) {
          case 'unavailable':
            await (f.db.delete(
              f.db.supportSessions,
            )..where((t) => t.id.equals(ThemeConsentFixture.id))).go();
            await f.runtime.refresh();
          case 'locked':
            await (f.db.update(
              f.db.supportSessions,
            )..where((t) => t.id.equals(ThemeConsentFixture.id))).write(
              const SupportSessionsCompanion(
                titleCiphertext: Value('synthetic-locked'),
              ),
            );
            await f.runtime.refresh();
          case 'corrupt':
            final block = (await f.repo.getContextBlockById(
              ThemeConsentFixture.codec.idFor(ThemeConsentFixture.id),
            ))!;
            await f.repo.putContextBlock(
              block.copyWith(protectedFactsJson: 'synthetic-corrupt'),
            );
            await f.runtime.refresh();
          case 'configuration':
            settle = f.revisions.beginMutation();
          case 'pending':
            f.runtime.pending++;
          case 'settings-pending':
            settle = f.runtime.beginSettingsChange();
        }
        try {
          final view = f.controller.view;
          expect(
            _right(view, SupportPermission.readSafeSettings).available,
            false,
          );
          expect(
            await f.runtime.authorization.prepare(
              supportSessionId: ThemeConsentFixture.id,
              use: SupportPermissionUse.localRead,
              sources: [
                SupportPermissionSource.safeProjection(
                  ThemeConsentFixture.id,
                  SupportSafeCategory.theme,
                ),
              ],
            ),
            isNull,
          );
          if (loss == 'pending' ||
              loss == 'settings-pending' ||
              loss == 'configuration') {
            expect(
              await f.controller.prepareReview(
                displayedIntent: view.displayedIntent,
                resolveRecipient: false,
              ),
              isNull,
            );
          }
          if (loss != 'pending') {
            final row = await f.row();
            expect(
              await f.controller.setGrant(
                original,
                SupportPermission.readSafeSettings,
                true,
              ),
              false,
            );
            expect(await f.row(), row);
          }
          expect(f.resolverReads, 0);
        } finally {
          if (loss == 'pending') f.runtime.pending--;
          settle?.call();
        }
      },
      scope: ThemeConsentFixture.scope(),
    );
  }
}
