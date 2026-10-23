import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_history_selection_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';
import 'helpers/support_permission_database_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

final class _ForgedIntent implements SupportNativeDisplayedIntent {}

final class _FrozenView extends SupportNativeViewNotifier {
  _FrozenView(this.snapshot);
  final SupportNativeView snapshot;
  @override
  SupportNativeView build() => snapshot;
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  NativeFixture f, {
  SupportNativeView? oldSnapshot,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeWidgetOverrides(f),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
        if (oldSnapshot != null)
          supportNativeViewProvider.overrideWith(
            () => _FrozenView(oldSnapshot),
          ),
      ],
      child: localizedNativeWidget(
        ListView(children: const [SupportPrivacyGroup()]),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('support_privacy_group')));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(SupportPrivacyGroup)),
  );
}

GlazeSwitch _switch(WidgetTester tester, String name) =>
    tester.widget<GlazeSwitch>(
      find.descendant(
        of: find.byKey(ValueKey('support_privacy_$name')),
        matching: find.byType(GlazeSwitch),
      ),
    );

Future<void> _settleWithoutPump(WidgetTester tester) =>
    tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });

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

  test(
    'only the original native issuer validates a displayed anchor',
    () async {
      final anchor = f.controller.view.displayedIntent;
      expect(anchor, isNotNull);
      expect(f.controller.isDisplayedIntentCurrent(anchor), true);
      final other = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      expect(other.isDisplayedIntentCurrent(anchor), false);
      expect(f.controller.isDisplayedIntentCurrent(_ForgedIntent()), false);
      expect(f.controller.isDisplayedIntentCurrent(null), false);
      expect(await other.prepareReview(displayedIntent: anchor), isNull);
      expect(
        await f.controller.prepareReview(displayedIntent: _ForgedIntent()),
        isNull,
      );
      expect(f.settingsReads, 0);
      expect(f.api.ids, isEmpty);
      expect(anchor.toString(), isNot(contains(NativeFixture.id)));
    },
  );

  test(
    'displayed anchor does not lock unrelated grant revision or lease epoch',
    () async {
      final anchor = f.controller.view.displayedIntent;
      final epoch = f.runtime.epoch, owner = f.runtime.writeOwner;
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      await f.runtime.refresh();
      expect(f.runtime.epoch, greaterThan(epoch));
      expect(f.runtime.writeOwner, owner);
      expect(f.controller.isDisplayedIntentCurrent(anchor), true);
      final review = (await f.controller.prepareReview(
        displayedIntent: anchor,
      ))!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        true,
      );
      expect(
        (await f.database.b.readForNative(
          NativeFixture.id,
        )).preferences!.grants,
        {
          SupportPermission.confirmedSettingsChanges,
          SupportPermission.readSafeSettings,
        },
      );
      expect(f.runtime.recipientConfirmed, false);
    },
  );

  test(
    'retired UI issuer invalidates both emitted anchor and prepared review',
    () async {
      final anchor = f.controller.view.displayedIntent;
      final review = (await f.controller.prepareReview(
        displayedIntent: anchor,
      ))!;
      final row = await f.database.row();
      f.controller.invalidateDisplayedIntents();
      expect(f.controller.isDisplayedIntentCurrent(anchor), false);
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        false,
      );
      expect(await f.database.row(), row);
    },
  );

  for (final replacement in [
    'identity',
    'recipient',
    'configuration',
    'dispose',
  ]) {
    testWidgets(
      'old rendered local grant rejects $replacement before any preparation',
      (tester) async {
        await _pump(tester, f);
        final displayed = _switch(tester, 'readSafeSettings');
        await tester.runAsync(() async {
          switch (replacement) {
            case 'identity':
              final p = (await f.database.b.readForNative(
                NativeFixture.id,
              )).preferences!;
              await f.database.repoB.putContextBlock(
                PermissionDatabaseFixture.codec.encode(
                  SupportPermissionPreferences(
                    supportSessionId: p.supportSessionId,
                    policyIdentity: 'synthetic-new-identity',
                    revision: 1,
                    scope: p.scope,
                    recipient: p.recipient,
                  ),
                  1,
                ),
              );
              await f.runtime.refresh();
            case 'recipient':
              await f.database.b.selectRecipientFromNative(
                NativeFixture.id,
                permissionRecipient(model: 'synthetic-replacement-model'),
                isCurrent: () => true,
              );
              await f.runtime.refresh();
            case 'configuration':
              final settle = f.revisions.beginMutation();
              settle();
            case 'dispose':
              f.runtime.dispose();
          }
        });
        final row = await tester.runAsync(f.database.row);
        final reads = f.settingsReads, apiReads = f.api.ids.length;
        displayed.onChanged!(true);
        expect(f.runtime.pending, 0);
        expect(f.settingsReads, reads);
        expect(f.api.ids.length, apiReads);
        await _settleWithoutPump(tester);
        expect(await tester.runAsync(f.database.row), row);
        expect(identical(_switch(tester, 'readSafeSettings'), displayed), true);
        expect(f.selectedLoads, 0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'old emitted snapshot cannot bind to newer runtime even during build',
    (tester) async {
      final old = f.controller.view;
      await tester.runAsync(() async {
        f.runtime.selectSession('synthetic-away');
        f.runtime.selectSession(NativeFixture.id);
        await f.runtime.refresh();
      });
      await _pump(tester, f, oldSnapshot: old);
      final row = await tester.runAsync(f.database.row);
      final reads = f.settingsReads;
      _switch(tester, 'readSafeSettings').onChanged!(true);
      expect(f.settingsReads, reads);
      await _settleWithoutPump(tester);
      expect(await tester.runAsync(f.database.row), row);
      expect(f.runtime.recipientConfirmed, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old control rejects actual provider controller replacement without pump',
    (tester) async {
      final container = await _pump(tester, f);
      final displayed = _switch(tester, 'readSafeSettings');
      final replacement = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      container.updateOverrides([
        ...nativeWidgetOverrides(f, controller: replacement),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
      ]);
      expect(
        container.read(supportNativeConsentControllerProvider),
        same(replacement),
      );
      final row = await tester.runAsync(f.database.row);
      final reads = f.settingsReads;
      displayed.onChanged!(true);
      expect(f.settingsReads, reads);
      await _settleWithoutPump(tester);
      expect(await tester.runAsync(f.database.row), row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'controller replacement fences recipient write after its own binding admission',
    (tester) async {
      final container = await _pump(tester, f);
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
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await tester.pumpAndSettle();
      final row = await tester.runAsync(f.database.row);
      f.database.repoA.pauseAdmission();
      tester
          .widget<GlazeActionButton>(
            find.byKey(const ValueKey('support_privacy_review_confirm')),
          )
          .onTap!();
      for (var i = 0; i < 100 && !f.database.repoA.entered!.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(f.database.repoA.entered!.isCompleted, true);
      expect(f.runtime.pending, 1);
      final replacement = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      container.updateOverrides([
        ...nativeWidgetOverrides(f, controller: replacement),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
      ]);
      expect(
        container.read(supportNativeConsentControllerProvider),
        same(replacement),
      );
      f.database.repoA.release!.complete();
      for (var i = 0; i < 100 && f.runtime.pending > 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(f.runtime.pending, 0);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(f.database.row), row);
      expect(f.runtime.recipientConfirmed, false);
      expect(
        find.textContaining('Не удалось применить нативный выбор'),
        findsNothing,
      );
      expect(
        replacement.isDisplayedIntentCurrent(replacement.view.displayedIntent),
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final control in [
    'connections_scope',
    'game_scope',
    'support_scope',
    'recipient',
    'recovery',
  ]) {
    testWidgets(
      'rendered $control rejects pre-admission lifetime ABA, not a fresh target',
      (tester) async {
        if (control == 'recovery') {
          await tester.runAsync(() async {
            await f.database.corrupt();
            await f.runtime.refresh();
          });
        }
        await _pump(tester, f);
        final VoidCallback invoke;
        if (control == 'connections_scope') {
          final displayed = _switch(tester, control);
          expect(displayed.onChanged, isNotNull);
          invoke = () => displayed.onChanged!(false);
        } else {
          final button = tester.widget<GlazeActionButton>(
            find.byKey(ValueKey('support_privacy_$control')),
          );
          expect(button.onTap, isNotNull);
          invoke = button.onTap!;
        }
        await tester.runAsync(() async {
          f.runtime.selectSession('synthetic-away');
          f.runtime.selectSession(NativeFixture.id);
          await f.runtime.refresh();
        });
        final row = await tester.runAsync(f.database.row);
        final reads = f.settingsReads, apiReads = f.api.ids.length;
        invoke();
        expect(f.runtime.pending, 0);
        expect(f.settingsReads, reads);
        expect(f.api.ids.length, apiReads);
        await _settleWithoutPump(tester);
        expect(await tester.runAsync(f.database.row), row);
        await tester.pumpAndSettle();
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(find.byType(SupportHistorySelectionSheet), findsNothing);
        expect(f.runtime.recipientConfirmed, false);
        expect(f.selectedLoads, 0);
        expect(f.api.bulkReads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'same-binding rendered local grant merges an independent edit without repump',
    (tester) async {
      await _pump(tester, f);
      final displayed = _switch(tester, 'readSafeSettings');
      await tester.runAsync(() async {
        await f.database.b.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.reportSupportHistory,
          true,
          isCurrent: () => true,
        );
        await f.runtime.refresh();
      });
      await tester.runAsync(() async {
        displayed.onChanged!(true);
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      final policy = (await tester.runAsync(
        () => f.database.b.readForNative(NativeFixture.id),
      ))!;
      expect(policy.preferences!.grants, {
        SupportPermission.readSafeSettings,
        SupportPermission.reportSupportHistory,
      });
      expect(f.runtime.recipientConfirmed, false);
      expect(f.selectedLoads, 0);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late preparation failure is not painted into replacement session',
    (tester) async {
      await _pump(tester, f);
      final entered = Completer<void>(), release = Completer<void>();
      f.api.afterRead = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await tester.runAsync(() async {
        // Local-read toggles deliberately do not resolve a model recipient.
        // Exercise the actual recipient preparation whose late failure this
        // case owns, rather than requiring an API read from a local grant.
        tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_privacy_recipient')),
            )
            .onTap!();
        for (var i = 0; i < 100 && !entered.isCompleted; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      expect(
        entered.isCompleted,
        true,
        reason: 'Actual native resolver reached its synthetic pause',
      );
      f.runtime.selectSession('synthetic-replacement');
      release.complete();
      await _settleWithoutPump(tester);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не удалось применить нативный выбор'),
        findsNothing,
      );
      expect(f.runtime.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'configuration host change before invocation never manufactures a fresh review',
    (tester) async {
      await _pump(tester, f);
      final button = tester.widget<GlazeActionButton>(
        find.byKey(const ValueKey('support_privacy_recipient')),
      );
      await tester.runAsync(
        () => f.api.put(
          const ApiConfig(
            id: 'synthetic-connection',
            name: 'Synthetic selected connection',
            endpoint: 'http://replacement.invalid:8080/v1/chat/completions',
            apiKey: NativeFixture.canary,
            model: 'stored-model',
          ),
        ),
      );
      final reads = f.settingsReads;
      button.onTap!();
      expect(f.settingsReads, reads);
      await _settleWithoutPump(tester);
      await tester.pumpAndSettle();
      expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
      expect(f.runtime.recipientConfirmed, false);
      expect(tester.takeException(), isNull);
    },
  );
}
