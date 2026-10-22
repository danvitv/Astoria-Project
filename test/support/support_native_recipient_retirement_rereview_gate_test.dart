import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

// Oracle attempt 2 only. Actual UI/controller/resolver + memory AEAD/fake vault.
// Pause ONLY the final resolver checkpoint, after a legitimate committed review.
// No production/existing-test edits, nested startup scope, loader or network.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeNativeWidgetLocalization();
  });
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
    // Establish a real previously granted prerequisite, then require a fresh
    // native confirmation without changing its exact selected recipient/scope.
    final recipientReview = (await f.controller.prepareReview())!;
    expect(await f.controller.confirmRecipient(recipientReview), true);
    final grantReview = (await f.controller.prepareReview())!;
    expect(
      await f.controller.setGrant(
        grantReview,
        SupportPermission.modelSupportHistory,
        true,
      ),
      true,
    );
    f.runtime.invalidateBindings();
    expect(await f.runtime.refresh(resolve: true), true);
    expect(f.runtime.recipientConfirmed, false);
    expect(f.runtime.snapshot.preferences!.grants, {
      SupportPermission.modelSupportHistory,
    });
  });
  tearDown(() => f.close());

  for (final replace in [false, true]) {
    testWidgets(
      replace
          ? 'retired displayed issuer cannot publish final recipient confirmation or fresh model lease'
          : 'live displayed issuer final checkpoint legitimately confirms and permits a fresh model lease',
      (tester) async {
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
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        });
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

        late Completer<void> entered, release;
        var checkpointReads = 0;
        await tester.runAsync(() async {
          entered = Completer<void>();
          release = Completer<void>();
        });
        addTearDown(() {
          f.api.afterRead = null;
          if (!release.isCompleted) release.complete();
        });
        f.api.afterRead = () async {
          checkpointReads++;
          // First read is the pre-write resolver; second is after _write has
          // completed its latest encrypted refresh and released pending state.
          if (checkpointReads == 2) {
            entered.complete();
            await release.future;
          }
        };
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
        expect(checkpointReads, 2);
        expect(f.runtime.pending, 0);
        expect(f.runtime.recipientConfirmed, false);
        final committedRow = await tester.runAsync(f.database.row);
        final preserved = await tester.runAsync(f.database.preserved);
        final owner = f.runtime.writeOwner, lifetime = f.runtime.lifetime;
        final liveAnchor = f.controller.view.displayedIntent;
        expect(f.controller.isDisplayedIntentCurrent(liveAnchor), true);
        final source = SupportPermissionSource.supportHistory(
          NativeFixture.id,
          f.runtime.snapshot.preferences!.scope!.supportHistory!,
        );
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
          expect(f.controller.isDisplayedIntentCurrent(liveAnchor), false);
          expect(
            replacement.isDisplayedIntentCurrent(
              replacement.view.displayedIntent,
            ),
            true,
          );
        }
        // Isolate issuer retirement from session/configuration/owner changes.
        expect(f.runtime.writeOwner, owner);
        expect(f.runtime.lifetime, lifetime);
        release.complete();
        await tester.runAsync(() async {
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        });
        await tester.pumpAndSettle();
        expect(await tester.runAsync(f.database.row), committedRow);
        expect(await tester.runAsync(f.database.preserved), preserved);
        expect(f.selectedLoads, 0);
        expect(f.api.bulkReads, 0);
        expect(f.runtime.pending, 0);
        expect(f.runtime.error, isNull);
        expect(
          find.textContaining('Не удалось применить нативный выбор'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        final lease = await tester.runAsync(
          () => f.runtime.authorization.prepare(
            supportSessionId: NativeFixture.id,
            use: SupportPermissionUse.modelContext,
            sources: [source],
          ),
        );
        expect(
          lease,
          replace ? isNull : isNotNull,
          reason:
              'Final native confirmation must retain displayed issuer ownership; '
              'replaced=$replace, recipientConfirmed=${f.runtime.recipientConfirmed}',
        );
        expect(f.runtime.recipientConfirmed, !replace);
      },
    );
  }
}
