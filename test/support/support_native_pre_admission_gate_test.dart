import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

// Oracle-only regression: actual native callback + real encrypted memory policy.
// No source/settled-fixture changes, App, platform vault, catalog or network.
const _replacement = 'synthetic-replacement-support';
const _newMessage = 'synthetic-replacement-message';

GlazeSwitch _switch(WidgetTester tester, SupportPermission right) =>
    tester.widget<GlazeSwitch>(
      find.descendant(
        of: find.byKey(ValueKey('support_privacy_${right.name}')),
        matching: find.byType(GlazeSwitch),
      ),
    );

Future<void> _pump(WidgetTester tester, NativeFixture fixture) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeWidgetOverrides(fixture),
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
}

Future<SupportPermissionPreferences> _policy(
  WidgetTester tester,
  NativeFixture fixture,
  String id,
) async => (await tester.runAsync(
  () => fixture.database.b.readForNative(id).then((s) => s.preferences!),
))!;

Future<Map<String, List<Object>>> _preserved(
  WidgetTester tester,
  NativeFixture fixture,
) async {
  final rows = (await tester.runAsync(fixture.database.preserved))!;
  // The settled helper excludes only its original session's permission row.
  // This test adds a second session; both policy rows are observed separately.
  return {
    ...rows,
    'others': rows['others']!
        .where(
          (row) =>
              row is! SupportContextBlockRow ||
              !row.id.startsWith('workspace-permissions-v1:'),
        )
        .toList(),
  };
}

Future<void> _seedReplacement(NativeFixture fixture) async {
  await fixture.database.repoB.createSession(
    const SupportSession(
      id: _replacement,
      title: 'Synthetic replacement',
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  await fixture.database.repoB.appendMessage(
    const SupportMessage(
      id: _newMessage,
      sessionId: _replacement,
      role: 'user',
      body: 'STATIC_GATE_REPLACEMENT_BODY',
      cardsJson: '[]',
      createdAt: 2,
    ),
  );
  await fixture.database.b.selectScopeFromNative(
    _replacement,
    SupportPermissionScope(
      selectionRevision: 1,
      supportHistory: SupportMessageSelection([_newMessage]),
      safeCategories: [SupportSafeCategory.connections],
    ),
    isCurrent: () => true,
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeNativeWidgetLocalization();
  });
  late NativeFixture fixture;
  setUp(() async {
    fixture = NativeFixture();
    await fixture.seed();
    await _seedReplacement(fixture);
  });
  tearDown(() => fixture.close());

  for (final right in [
    SupportPermission.readSafeSettings,
    SupportPermission.reportSupportHistory,
  ]) {
    testWidgets(
      'gate control: current ${right.name} grants without model consent',
      (tester) async {
        await _pump(tester, fixture);
        final handler = _switch(tester, right).onChanged;
        expect(handler, isNotNull);
        await tester.runAsync(() async {
          handler!(true);
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        });
        expect((await _policy(tester, fixture, NativeFixture.id)).grants, {
          right,
        });
        expect(fixture.runtime.pending, 0);
        expect(fixture.runtime.recipientConfirmed, false);
        expect(fixture.selectedLoads, 0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    for (final change in ['session', 'scope', 'lifetime ABA']) {
      testWidgets(
        'gate: displayed ${right.name} handler must reject pre-admission $change',
        (tester) async {
          await _pump(tester, fixture);
          final displayed = _switch(tester, right);
          final oldHandler = displayed.onChanged;
          expect(oldHandler, isNotNull);
          expect(displayed.value, false);
          expect(fixture.runtime.recipientConfirmed, false);
          final originalOwner = fixture.runtime.writeOwner;
          final originalLifetime = fixture.runtime.lifetime;
          final originalPolicy = await _policy(
            tester,
            fixture,
            NativeFixture.id,
          );
          final originalRow = await tester.runAsync(fixture.database.row);

          // Do NOT pump between change and invocation: the user-facing old
          // widget/closure is still displayed when the replacement is admitted.
          await tester.runAsync(() async {
            switch (change) {
              case 'session':
                fixture.runtime.selectSession(_replacement);
                expect(await fixture.runtime.refresh(), true);
              case 'scope':
                await fixture.database.repoB.appendMessage(
                  const SupportMessage(
                    id: 'synthetic-new-range-message',
                    sessionId: NativeFixture.id,
                    role: 'user',
                    body: 'STATIC_GATE_NEW_RANGE_BODY',
                    cardsJson: '[]',
                    createdAt: 5,
                  ),
                );
                await fixture.database.b.selectScopeFromNative(
                  NativeFixture.id,
                  SupportPermissionScope(
                    selectionRevision:
                        originalPolicy.scope!.selectionRevision + 1,
                    supportHistory: SupportMessageSelection([
                      'synthetic-new-range-message',
                    ]),
                    safeCategories: [SupportSafeCategory.connections],
                  ),
                  isCurrent: () => true,
                );
                expect(await fixture.runtime.refresh(), true);
              case 'lifetime ABA':
                fixture.runtime.selectSession(_replacement);
                fixture.runtime.selectSession(NativeFixture.id);
                expect(await fixture.runtime.refresh(), true);
            }
          });
          expect(identical(_switch(tester, right), displayed), true);
          expect(fixture.runtime.writeOwner, isNot(originalOwner));
          if (change != 'scope') {
            expect(fixture.runtime.lifetime, isNot(originalLifetime));
          }
          // Fresh current controls really WOULD allow these independent rights.
          // Model reconfirmation must not make a stale grant rejection vacuous.
          expect(
            fixture.controller.view.rights
                .firstWhere((r) => r.right == right)
                .available,
            true,
          );
          final currentId = fixture.runtime.sessionId;
          final before = await _policy(tester, fixture, currentId);
          final preserved = await _preserved(tester, fixture);
          expect(before.grants, isEmpty);

          await tester.runAsync(() async {
            oldHandler!(true);
            // The callback has a void UI type. Drive only real SQLite/AEAD
            // callbacks, without rebuilding the old visible element.
            for (var i = 0; i < 100; i++) {
              await Future<void>.delayed(Duration.zero);
            }
          });
          expect(identical(_switch(tester, right), displayed), true);
          expect(fixture.runtime.pending, 0);
          final after = await _policy(tester, fixture, currentId);
          expect(await _preserved(tester, fixture), preserved);
          if (change == 'session') {
            expect(await tester.runAsync(fixture.database.row), originalRow);
          }
          expect(fixture.selectedLoads, 0);
          expect(fixture.api.bulkReads, 0);
          expect(fixture.runtime.recipientConfirmed, false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            after.grants,
            before.grants,
            reason:
                'Old displayed intent must not authorize the fresh $change '
                'target; current encrypted policy is ${after.grants}',
          );
        },
      );
    }
  }
}
