import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_connection_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/core/models/support_models.dart' as db;
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';
import 'package:glaze_flutter/shared/widgets/glaze_tab_bar.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

const _profile = ApiConnectionMetadata(
  connectionId: 'synthetic-profile',
  displayName: 'Synthetic selectable profile',
  providerId: 'openai',
  protocol: 'openai',
  mode: 'chat',
  endpoint: 'https://synthetic.invalid/v1/chat/completions',
  model: 'synthetic-model',
  llmCredential: CredentialMetadata.absent,
  embeddingCredential: CredentialMetadata.absent,
  embeddingUseSame: false,
  embeddingEnabled: false,
  embeddingEndpoint: '',
  embeddingModel: '',
  embeddingLlmPresetId: '',
);

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; !ready() && i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), true, reason: 'Original synthetic workspace job completed');
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.runAsync(() => tester.ensureVisible(target));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() => tester.tap(target));
  await tester.pump();
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  for (final empty in [true, false]) {
    testWidgets(
      '${empty ? 'empty history exposes global profile before starting chat' : 'existing session hydrates'}: modes, permissions and profile work',
      (tester) async {
        tester.view.physicalSize = const Size(550, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = (await tester.runAsync(
          () => Future<NativeFixture>.sync(NativeFixture.new),
        ))!;
        if (!empty) {
          await tester.runAsync(
            () => f.database.repoB.createSession(
              const db.SupportSession(
                id: 'synthetic-existing',
                title: 'Existing session',
                createdAt: 1,
                updatedAt: 1,
              ),
            ),
          );
        }
        final container = ProviderContainer(
          overrides: [
            ...nativeWidgetOverrides(f),
            supportSessionStoreProvider.overrideWithValue(f.workspace),
            supportConnectionsProvider.overrideWithValue(const [_profile]),
            appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
          ],
        );
        SupportWorkspaceState state() =>
            container.read(supportWorkspaceProvider);
        try {
          await HttpOverrides.runZoned(
            () => IOOverrides.runZoned(
              () async {
                await tester.pumpWidget(
                  UncontrolledProviderScope(
                    container: container,
                    child: localizedNativeWidget(const SupportSettingsPanel()),
                  ),
                );
                await _until(
                  tester,
                  () => !state().isLoading && !state().isBusy,
                );
                if (empty) {
                  expect(state().sessions, isEmpty);
                  expect(find.byType(GlazeTabBar), findsOneWidget);
                  expect(
                    find.byKey(const ValueKey('support_connection_selector')),
                    findsOneWidget,
                  );
                  expect(find.text('Общий профиль Астории'), findsOneWidget);
                  await _tap(
                    tester,
                    find.byKey(
                      const ValueKey('support_settings_start_session'),
                    ),
                  );
                  await _until(
                    tester,
                    () => state().activeSessionId.isNotEmpty && !state().isBusy,
                  );
                }
                final id = state().activeSessionId;
                expect(state().sessions, hasLength(1));
                expect(f.runtime.sessionId, id);
                expect(f.runtime.snapshot.isAvailable, true);
                expect(f.runtime.snapshot.preferences!.grants, isEmpty);
                expect(f.runtime.recipientConfirmed, false);
                expect(f.selectedLoads, 0);
                expect(f.settingsReads, 0);

                final strip = find.byKey(
                  const ValueKey('support_settings_mode'),
                );
                if (empty) {
                  await tester.scrollUntilVisible(
                    strip,
                    -300,
                    scrollable: find.byType(Scrollable).first,
                    maxScrolls: 10,
                  );
                  await tester.pump();
                }
                expect(
                  tester.widget<GlazeTabBar>(strip).style,
                  GlazeTabBarStyle.underline,
                );
                for (final mode in SupportAssistantMode.values) {
                  final label = find.descendant(
                    of: strip,
                    matching: find.text(mode.shortLabel),
                  );
                  expect(
                    tester.getRect(strip).contains(tester.getCenter(label)),
                    true,
                  );
                  await _tap(tester, label);
                  await _until(
                    tester,
                    () => state().settings.mode == mode && !state().isBusy,
                  );
                  final saved = await tester.runAsync(
                    () => f.workspace.settingsFor(id),
                  );
                  expect(saved!.mode, mode);
                }

                await _tap(
                  tester,
                  find.byKey(const ValueKey('support_connection_selector')),
                );
                await tester.pump(const Duration(milliseconds: 350));
                await _tap(tester, find.text(_profile.displayName).last);
                await _until(
                  tester,
                  () =>
                      state().settings.apiConfigId == _profile.connectionId &&
                      !state().isBusy,
                );
                final selected = await tester.runAsync(
                  () => f.workspace.settingsFor(id),
                );
                expect(selected!.apiConfigId, _profile.connectionId);
                expect(selected.modelId, _profile.model);
                expect(f.runtime.recipientConfirmed, false);
                expect(f.selectedLoads, 0);
                expect(f.settingsReads, 0);

                await _tap(
                  tester,
                  find.byKey(const ValueKey('support_privacy_group')),
                );
                final theme = find.descendant(
                  of: find.byKey(const ValueKey('support_privacy_theme_scope')),
                  matching: find.byType(GlazeSwitch),
                );
                await tester.ensureVisible(theme);
                expect(tester.widget<GlazeSwitch>(theme).onChanged, isNotNull);
                await _tap(tester, theme);
                await _until(
                  tester,
                  () =>
                      f.runtime.snapshot.preferences?.scope?.safeCategories
                          .contains(SupportSafeCategory.theme) ==
                      true,
                );
                expect(f.runtime.snapshot.preferences!.grants, isEmpty);
                expect(f.runtime.recipientConfirmed, false);
                expect(f.selectedLoads, 0);
                expect(f.settingsReads, 0);
                await tester.pumpWidget(const SizedBox.shrink());
              },
              createFile: (_) => throw StateError('Unexpected file/default DB'),
              createDirectory: (_) => throw StateError('Unexpected directory'),
              socketConnect:
                  (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                      throw StateError('Unexpected socket'),
            ),
            createHttpClient: (_) => throw StateError('Unexpected HTTP/model'),
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.runAsync(f.close);
        }
      },
    );
  }

  test(
    'corrupt permission policy stays denied after workspace hydration',
    () async {
      final f = NativeFixture();
      const id = 'synthetic-corrupt-policy';
      await f.database.repoB.createSession(
        const db.SupportSession(
          id: id,
          title: 'Synthetic session',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await f.database.repoB.putContextBlock(
        db.SupportContextBlock(
          id: SupportPermissionStore.codec.idFor(id),
          sessionId: id,
          startMessageId: '',
          endMessageId: '',
          summary: 'workspace-permissions-v1',
          protectedFactsJson: '{"not-a-policy":true}',
          createdAt: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          ...nativeWidgetOverrides(f),
          supportSessionStoreProvider.overrideWithValue(f.workspace),
        ],
      );
      try {
        final ready = container.listen(supportWorkspaceProvider, (_, _) {});
        for (
          var i = 0;
          i < 100 && container.read(supportWorkspaceProvider).isLoading;
          i++
        ) {
          await Future<void>.delayed(Duration.zero);
          await container.pump();
        }
        expect(container.read(supportWorkspaceProvider).activeSessionId, id);
        expect(
          f.runtime.snapshot.availability,
          SupportPermissionAvailability.corrupt,
        );
        expect(f.runtime.snapshot.preferences, isNull);
        expect(f.runtime.recipientConfirmed, false);
        expect(f.selectedLoads, 0);
        expect(f.settingsReads, 0);
        ready.close();
      } finally {
        container.dispose();
        await f.close();
      }
    },
  );
}
