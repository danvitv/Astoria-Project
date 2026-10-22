import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';
import 'helpers/support_permission_database_fixture.dart';

// Completion-only controls. Real memory AEAD/fake vault, actual selected resolver
// and same-scope widget overrides. No default App, storage, loader or network.
Future<void> _settle(WidgetTester tester) => tester.runAsync(() async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(Duration.zero);
  }
});

Future<ProviderContainer> _openReview(
  WidgetTester tester,
  NativeFixture f,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeWidgetOverrides(f),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
      ],
      child: localizedNativeWidget(
        ListView(children: const [SupportPrivacyGroup()]),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('support_privacy_group')));
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(SupportPrivacyGroup)),
  );
  await tester.runAsync(() async {
    tester
        .widget<GlazeActionButton>(
          find.byKey(const ValueKey('support_privacy_recipient')),
        )
        .onTap!();
  });
  await _settle(tester);
  await tester.pumpAndSettle();
  expect(find.byType(SupportPrivacyReviewSheet), findsOneWidget);
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('support_privacy_review_confirm')),
    200,
    scrollable: find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .last,
  );
  await tester.pumpAndSettle();
  return container;
}

SupportPermissionSource _historySource(NativeFixture f) =>
    SupportPermissionSource.supportHistory(
      NativeFixture.id,
      f.runtime.snapshot.preferences!.scope!.supportHistory!,
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeNativeWidgetLocalization();
  });
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  Future<SupportNativeReview> review() async => (await f.controller
      .prepareReview(displayedIntent: f.controller.view.displayedIntent))!;

  Future<void> grant(SupportPermission right) async {
    expect(await f.controller.setGrant(await review(), right, true), true);
  }

  Future<void> establishModelPrerequisite() async {
    expect(await f.controller.confirmRecipient(await review()), true);
    await grant(SupportPermission.modelSupportHistory);
    f.runtime.invalidateBindings();
    expect(await f.runtime.refresh(resolve: true), true);
    expect(f.runtime.recipientConfirmed, false);
  }

  for (final replace in [false, true]) {
    testWidgets(
      replace
          ? 'issuer retired during finally refresh denies before starting final resolver'
          : 'live issuer during finally refresh proceeds to final resolver and fresh model lease',
      (tester) async {
        await tester.runAsync(establishModelPrerequisite);
        final container = await _openReview(tester, f);
        final before = await tester.runAsync(f.database.row);
        final preserved = await tester.runAsync(f.database.preserved);
        late Completer<void> entered, release;
        await tester.runAsync(() async {
          entered = Completer<void>();
          release = Completer<void>();
        });
        var checkpointReads = 0;
        f.api.afterRead = () async => checkpointReads++;
        final policyId = PermissionDatabaseFixture.codec.idFor(
          NativeFixture.id,
        );
        final policySummaryAad =
            'astoria.support.v1|support_context_blocks|$policyId|'
            '${NativeFixture.id}|summary_ciphertext';
        f.database.primitive.beforeDecrypt = (aad) async {
          // Exact policy read only AFTER the committed write released pending.
          // Transaction input/result decrypts still have pending == 1.
          if (!entered.isCompleted &&
              aad == policySummaryAad &&
              f.runtime.pending == 0 &&
              checkpointReads == 1) {
            entered.complete();
            await release.future;
          }
        };
        addTearDown(() {
          f.database.primitive.beforeDecrypt = null;
          f.api.afterRead = null;
          if (!release.isCompleted) release.complete();
        });
        tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_privacy_review_confirm')),
            )
            .onTap!();
        for (var i = 0; i < 100 && !entered.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(entered.isCompleted, true);
        expect(checkpointReads, 1);
        expect(f.runtime.pending, 0);
        expect(f.runtime.recipientConfirmed, false);
        final committed = await tester.runAsync(f.database.row);
        expect(committed, isNot(before));
        final owner = f.runtime.writeOwner, lifetime = f.runtime.lifetime;
        final anchor = f.controller.view.displayedIntent;
        expect(f.controller.isDisplayedIntentCurrent(anchor), true);
        final source = _historySource(f);
        expect(
          await tester.runAsync(
            () => f.runtime.authorization.prepare(
              supportSessionId: NativeFixture.id,
              use: SupportPermissionUse.modelContext,
              sources: [source],
            ),
          ),
          isNull,
        );
        final replacement = SupportNativeConsentController(
          runtime: f.runtime,
          readMessages: f.controller.readMessages,
        );
        if (replace) {
          container.updateOverrides([
            ...nativeWidgetOverrides(f, controller: replacement),
            appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
          ]);
          expect(
            container.read(supportNativeConsentControllerProvider),
            same(replacement),
          );
          expect(f.controller.isDisplayedIntentCurrent(anchor), false);
          expect(
            replacement.isDisplayedIntentCurrent(
              replacement.view.displayedIntent,
            ),
            true,
          );
        }
        expect(f.runtime.writeOwner, owner);
        expect(f.runtime.lifetime, lifetime);
        release.complete();
        await _settle(tester);
        await tester.pumpAndSettle();
        expect(await tester.runAsync(f.database.row), committed);
        expect(await tester.runAsync(f.database.preserved), preserved);
        expect(f.runtime.writeOwner, owner);
        expect(f.runtime.lifetime, lifetime);
        expect(f.runtime.pending, 0);
        expect(f.runtime.error, isNull);
        expect(f.selectedLoads, 0);
        expect(f.api.bulkReads, 0);
        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('Не удалось применить нативный выбор'),
          findsNothing,
        );
        if (replace) {
          expect(
            replacement.isDisplayedIntentCurrent(
              replacement.view.displayedIntent,
            ),
            true,
          );
        }
        expect(
          await tester.runAsync(
            () => f.runtime.authorization.prepare(
              supportSessionId: NativeFixture.id,
              use: SupportPermissionUse.modelContext,
              sources: [source],
            ),
          ),
          replace ? isNull : isNotNull,
        );
        expect(f.runtime.recipientConfirmed, !replace);
        expect(checkpointReads, replace ? 1 : 2);
      },
    );
  }

  for (final first in [true, false]) {
    test(
      first
          ? 'first recipient confirmation accepts legitimate own refresh owner transition'
          : 'genuine changed recipient confirmation accepts own refresh and preserves independent grants',
      () async {
        if (first) {
          await f.database.b.selectRecipientFromNative(
            NativeFixture.id,
            null,
            isCurrent: () => true,
          );
          expect(await f.runtime.refresh(), true);
        } else {
          expect(await f.controller.confirmRecipient(await review()), true);
          await grant(SupportPermission.modelSupportHistory);
          await f.workspace.changeSettings(
            NativeFixture.id,
            (s) => s.copyWith(modelId: 'synthetic-new-recipient-model'),
          );
        }
        await grant(SupportPermission.readSafeSettings);
        await grant(SupportPermission.reportSupportHistory);
        final original = await review();
        final saved = f.runtime.snapshot.preferences!;
        final resolved = original.view.recipient as SupportResolvedRecipient;
        if (first) {
          expect(saved.recipient, isNull);
        } else {
          expect(saved.recipient!.modelId, 'synthetic-model');
          expect(resolved.recipient.modelId, 'synthetic-new-recipient-model');
          expect(saved.allows(SupportPermission.modelSupportHistory), true);
        }
        final owner = f.runtime.writeOwner, lifetime = f.runtime.lifetime;
        final preserved = await f.database.preserved();
        expect(await f.controller.confirmRecipient(original), true);
        // Admission advances once; observation of our own new recipient again.
        expect(f.runtime.writeOwner, owner + 2);
        expect(f.runtime.lifetime, lifetime);
        expect(f.runtime.recipientConfirmed, true);
        final current = f.runtime.snapshot.preferences!;
        expect(resolved.recipient.sameAs(current.recipient), true);
        expect(current.policyIdentity, saved.policyIdentity);
        expect(current.grants, {
          SupportPermission.readSafeSettings,
          SupportPermission.reportSupportHistory,
        });
        expect(await f.database.preserved(), preserved);
        expect(f.selectedLoads, 0);
        expect(f.api.bulkReads, 0);
        expect(f.runtime.error, isNull);
        // A new explicit grant, not recipient confirmation alone, enables model.
        await grant(SupportPermission.modelSupportHistory);
        expect(
          await f.runtime.authorization.prepare(
            supportSessionId: NativeFixture.id,
            use: SupportPermissionUse.modelContext,
            sources: [_historySource(f)],
          ),
          isNotNull,
        );
      },
    );
  }

  Future<({Future<bool> completion, Completer<void> release})>
  pauseFinalConfirmation() async {
    final original = await review();
    final entered = Completer<void>(), release = Completer<void>();
    var reads = 0;
    f.api.afterRead = () async {
      if (++reads == 2) {
        entered.complete();
        await release.future;
      }
    };
    addTearDown(() {
      f.api.afterRead = null;
      if (!release.isCompleted) release.complete();
    });
    final completion = f.controller.confirmRecipient(original);
    await entered.future;
    expect(reads, 2);
    expect(f.runtime.pending, 0);
    expect(f.runtime.recipientConfirmed, false);
    return (completion: completion, release: release);
  }

  test(
    'independent grant refresh and data epoch change do not cancel final confirmation',
    () async {
      await establishModelPrerequisite();
      await grant(SupportPermission.readSafeSettings);
      await grant(SupportPermission.reportSupportHistory);
      final preserved = await f.database.preserved();
      final paused = await pauseFinalConfirmation();
      final owner = f.runtime.writeOwner, epoch = f.runtime.epoch;
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      expect(await f.runtime.refresh(), true);
      expect(f.runtime.writeOwner, owner);
      expect(f.runtime.epoch, greaterThan(epoch));
      final committed = await f.database.row();
      paused.release.complete();
      expect(await paused.completion, true);
      expect(await f.database.row(), committed);
      expect(await f.database.preserved(), preserved);
      expect(f.runtime.snapshot.preferences!.grants, {
        SupportPermission.modelSupportHistory,
        SupportPermission.readSafeSettings,
        SupportPermission.reportSupportHistory,
        SupportPermission.confirmedSettingsChanges,
      });
      expect(
        await f.runtime.authorization.prepare(
          supportSessionId: NativeFixture.id,
          use: SupportPermissionUse.modelContext,
          sources: [_historySource(f)],
        ),
        isNotNull,
      );
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
      expect(f.runtime.error, isNull);
    },
  );

  test(
    'retired final completion cannot undo replacement confirmation or committed policy',
    () async {
      await establishModelPrerequisite();
      final preserved = await f.database.preserved();
      final paused = await pauseFinalConfirmation();
      f.controller.invalidateDisplayedIntents();
      final replacement = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      final replacementReview = (await replacement.prepareReview(
        displayedIntent: replacement.view.displayedIntent,
      ))!;
      expect(await replacement.confirmRecipient(replacementReview), true);
      final committed = await f.database.row();
      final owner = f.runtime.writeOwner,
          lifetime = f.runtime.lifetime,
          epoch = f.runtime.epoch;
      final anchor = replacement.view.displayedIntent;
      paused.release.complete();
      expect(await paused.completion, false);
      expect(f.runtime.recipientConfirmed, true);
      expect(f.runtime.writeOwner, owner);
      expect(f.runtime.lifetime, lifetime);
      expect(f.runtime.epoch, epoch);
      expect(replacement.isDisplayedIntentCurrent(anchor), true);
      expect(await f.database.row(), committed);
      expect(await f.database.preserved(), preserved);
      expect(
        await f.runtime.authorization.prepare(
          supportSessionId: NativeFixture.id,
          use: SupportPermissionUse.modelContext,
          sources: [_historySource(f)],
        ),
        isNotNull,
      );
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
      expect(f.runtime.error, isNull);
    },
  );

  for (final loss in ['owner', 'ABA', 'configuration']) {
    test('final resolver completion retains $loss checkpoint denial', () async {
      await establishModelPrerequisite();
      final preserved = await f.database.preserved();
      final paused = await pauseFinalConfirmation();
      final committed = await f.database.row();
      switch (loss) {
        case 'owner':
          f.runtime.invalidateBindings();
        case 'ABA':
          f.runtime.selectSession('synthetic-other-session');
          f.runtime.selectSession(NativeFixture.id);
        case 'configuration':
          final settle = f.revisions.beginMutation();
          settle();
          f.runtime.checkConfiguration();
      }
      final owner = f.runtime.writeOwner, lifetime = f.runtime.lifetime;
      paused.release.complete();
      expect(await paused.completion, false);
      expect(f.runtime.writeOwner, owner);
      expect(f.runtime.lifetime, lifetime);
      expect(f.runtime.recipientConfirmed, false);
      expect(await f.database.row(), committed);
      expect(await f.database.preserved(), preserved);
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
      expect(f.runtime.pending, 0);
      expect(f.runtime.error, isNull);
    });
  }
}
