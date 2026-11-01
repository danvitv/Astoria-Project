import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_application_data_consent.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

const _access = ValueKey('support_application_data_switch');
const _accept = ValueKey('support_application_data_consent_accept');
const _decline = ValueKey('support_application_data_consent_decline');

Future<T> _native<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? result;
  Object? error;
  unawaited(
    operation().then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  // Reuse the established privacy-test driver. After a real widget gesture the
  // cipher key FIFO retains a completed fake-zone future; awaiting the next
  // decrypt entirely inside runAsync strands its late callback in that zone.
  for (var i = 0; !done && i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (error != null) throw error!;
  expect(done, true, reason: 'Synthetic native operation completed');
  return result as T;
}

Future<void> _turns(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  if (finder.evaluate().isEmpty) {
    // ListView creates lower groups lazily on narrow panels. Scroll the real
    // settings view before asking ensureVisible for an element that exists.
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
      maxScrolls: 20,
    );
  }
  await tester.ensureVisible(finder);
  // ensureVisible updates the scroll position; advance layout before hit-testing
  // the actual gesture, as in the established native privacy widget tests.
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await _show(tester, key);
  await tester.tap(find.byKey(key));
  await _turns(tester);
}

GlazeSwitch _switch(WidgetTester tester) => tester.widget<GlazeSwitch>(
  find.descendant(of: find.byKey(_access), matching: find.byType(GlazeSwitch)),
);

class _PanelWorkspace extends SupportWorkspaceNotifier {
  @override
  SupportWorkspaceState build() => const SupportWorkspaceState(
    activeSessionId: NativeFixture.id,
    settings: SupportAssistantSettings(),
    isLoading: false,
  );
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  // Reuse the established native widget fixture lifecycle: construct and open
  // the real encrypted database outside Flutter's fake widget-clock zone.
  late NativeFixture fixture;
  setUp(() async {
    fixture = NativeFixture();
    await fixture.seed();
    await fixture.database.a.initializeGlobalFromNative(
      NativeFixture.id,
      isCurrent: () => true,
    );
    await fixture.runtime.refresh();
  });
  tearDown(() => fixture.close());

  for (final busyMode in ['pending', 'configuration', 'source']) {
    testWidgets('$busyMode instability does not disable the real OFF gesture', (
      tester,
    ) async {
      await _native(tester, () async {
        await fixture.database.a.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.readApplicationData,
          true,
          isCurrent: () => true,
        );
        await fixture.runtime.refresh();
      });
      var runtime = fixture.runtime;
      var controller = fixture.controller;
      void Function()? finishConfiguration;
      if (busyMode == 'source') {
        runtime = SupportNativeRuntime(
          permissions: fixture.database.a,
          resolveRecipient: fixture.runtime.resolveRecipient,
          loadSelectedConnection: fixture.runtime.loadSelectedConnection,
          configurationRevision: fixture.runtime.configurationRevision,
          configurationStable: fixture.runtime.configurationStable,
          gameSourceStable: () => false,
        );
        addTearDown(runtime.dispose);
        runtime.selectSession(NativeFixture.id);
        await _native(tester, runtime.refresh);
        controller = SupportNativeConsentController(
          runtime: runtime,
          readMessages: (_, _, _) =>
              throw StateError('OFF must not open a picker'),
        );
        expect(runtime.owns(NativeFixture.id, runtime.writeOwner), false);
      } else if (busyMode == 'configuration') {
        finishConfiguration = fixture.revisions.beginMutation();
        runtime.checkConfiguration();
      } else {
        // Declared native pending-operation surrogate. The separate real FILE/model
        // suite proves that this same controller gesture cancels continuation POSTs.
        runtime.pending++;
      }
      final epoch = runtime.epoch;
      await tester.pumpWidget(
        ProviderScope(
          overrides: nativeWidgetOverrides(fixture, controller: controller),
          child: localizedNativeWidget(
            ListView(children: const [SupportPrivacyGroup()]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (busyMode != 'source') expect(controller.view.busy, true);
      expect(_switch(tester).value, true);
      try {
        await _tap(tester, _access);
        expect(runtime.epoch, greaterThan(epoch));
        expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
        expect(_switch(tester).value, false);
        expect(runtime.pending, busyMode == 'pending' ? 1 : 0);
        await _native(tester, () async {
          expect(
            (await fixture.database.b.readForNative(
              NativeFixture.id,
            )).preferences!.allows(SupportPermission.readApplicationData),
            false,
          );
        });
      } finally {
        if (busyMode == 'pending') runtime.pending--;
        finishConfiguration?.call();
        runtime.notify();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets(
    'failed OFF stays blocked and can be saved again without consent',
    (tester) async {
      await _native(tester, () async {
        await fixture.database.a.setGrantFromNative(
          NativeFixture.id,
          SupportPermission.readApplicationData,
          true,
          isCurrent: () => true,
        );
        await fixture.runtime.refresh();
      });
      fixture.database.primitive.afterEncrypt = (_) async =>
          throw StateError('synthetic write failure');
      await tester.pumpWidget(
        ProviderScope(
          overrides: nativeWidgetOverrides(fixture),
          child: localizedNativeWidget(
            ListView(children: const [SupportPrivacyGroup()]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, _access);
      expect(_switch(tester).value, false);
      expect(fixture.database.b.applicationDataReadDenied, true);
      expect(
        find.byKey(const ValueKey('support_application_data_revoke_retry')),
        findsOneWidget,
      );
      await _native(tester, () async {
        expect(
          (await fixture.database.b.readForNative(
            NativeFixture.id,
          )).preferences!.allows(SupportPermission.readApplicationData),
          true,
        );
      });
      fixture.database.primitive.afterEncrypt = null;
      await _tap(
        tester,
        const ValueKey('support_application_data_revoke_retry'),
      );
      expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('support_application_data_revoke_retry')),
        findsNothing,
      );
      expect(_switch(tester).value, false);
      await _native(tester, () async {
        expect(
          (await fixture.database.b.readForNative(
            NativeFixture.id,
          )).preferences!.allows(SupportPermission.readApplicationData),
          false,
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [236.0, 360.0, 1120.0]) {
    testWidgets('one global data switch and exact consent fit $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeWidgetOverrides(fixture),
            appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
            supportWorkspaceProvider.overrideWith(_PanelWorkspace.new),
            supportConnectionsProvider.overrideWithValue(const []),
          ],
          child: localizedNativeWidget(const SupportSettingsPanel()),
        ),
      );
      await tester.pumpAndSettle();
      await _show(tester, _access);
      expect(_switch(tester).value, false);
      final privacy = find.byType(SupportPrivacyGroup);
      expect(
        find.descendant(of: privacy, matching: find.byType(GlazeSwitch)),
        findsOneWidget,
      );
      for (final old in [
        'support_privacy_game_scope',
        'support_privacy_support_scope',
        'support_privacy_recipient',
        'support_privacy_theme_scope',
        'support_privacy_modelGameHistory',
        'support_privacy_reportGameHistory',
      ]) {
        expect(find.byKey(ValueKey(old)), findsNothing);
      }
      await _tap(tester, _access);
      expect(find.byType(SupportApplicationDataConsentSheet), findsOneWidget);
      expect(find.textContaining('API-ключи, токены'), findsOneWidget);
      expect(find.textContaining('несколько сессий'), findsOneWidget);
      await _tap(tester, _accept);
      expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
      expect(_switch(tester).value, true);
      await _native(tester, () async {
        final policy = (await fixture.database.b.readForNative(
          NativeFixture.id,
        )).preferences!;
        expect(policy.grants, {SupportPermission.readApplicationData});
        expect(policy.isGlobal, true);
      });
      // Disable is direct, with no second dialog or new report/model grants.
      await _tap(tester, _access);
      expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
      expect(_switch(tester).value, false);
      await _native(tester, () async {
        final policy = (await fixture.database.b.readForNative(
          NativeFixture.id,
        )).preferences!;
        expect(policy.grants, isEmpty);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'cancel never grants and legacy contextual cards open no picker',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeWidgetOverrides(fixture),
            appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
          ],
          child: localizedNativeWidget(
            ListView(
              children: const [
                SupportPrivacyGroup(initialRecipientReview: true),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
      await _tap(tester, _access);
      expect(find.byType(SupportApplicationDataConsentSheet), findsOneWidget);
      await _tap(tester, _decline);
      expect(_switch(tester).value, false);
      await _native(tester, () async {
        expect(
          (await fixture.database.b.readForNative(
            NativeFixture.id,
          )).preferences!.grants,
          isEmpty,
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
