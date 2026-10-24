import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart' as db;
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_fields.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_key_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_screen_controller.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_focus.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';

import 'support_provider_action_fixture.dart' show ProviderActionFixture;
import 'support_provider_screen_fixture.dart';

const _otherSession = 'manual-provider-other-owner';
const _endpoint =
    'https://synthetic-manual-provider.invalid/v1/chat/completions';

Map<String, Object?> _settings(SupportAssistantSettings s) => {
  'api': s.apiConfigId,
  'model': s.modelId,
  'mode': s.mode,
  'temperature': s.temperature,
  'tokens': s.maxTokens,
  'reasoning': s.reasoningEffort,
  'dcp': s.dcpCompressionEnabled,
};

SupportWorkspaceNotifier _workspace(ProviderScreenFixture f) =>
    f.root.container.read(supportWorkspaceProvider.notifier);

Future<Map<String, Object?>> _saved(
  WidgetTester tester,
  ProviderScreenFixture f, [
  String session = ProviderActionFixture.sessionId,
]) async => _settings(
  await f.join(
    tester,
    () =>
        f.root.container.read(supportSessionStoreProvider).settingsFor(session),
    label: 'original stored Astoria settings',
  ),
);

Future<void> _workspaceIdle(
  WidgetTester tester,
  ProviderScreenFixture f,
) async {
  await tester.pump();
  await f.real(tester, () => Future<void>.delayed(Duration.zero));
  await f.until(tester, () {
    final state = f.root.container.read(supportWorkspaceProvider);
    return !state.isLoading && !state.isBusy;
  }, label: 'actual workspace settings tail');
}

Future<void> _mountPanel(WidgetTester tester, ProviderScreenFixture f) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await f.mount(tester);
  await f.join(tester, () async {
    await f.root.backing.support.createSession(
      const db.SupportSession(
        id: _otherSession,
        title: 'Synthetic second owner',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    f.root.container.read(supportWorkspaceProvider);
    await f.root.container.pump();
    await _workspace(f).refresh();
    _workspace(f).selectSession(ProviderActionFixture.sessionId);
    await _workspace(f).refresh();
  }, label: 'declared memory workspace initialization');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.root.container,
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'declared-memory-only',
        assetLoader: const ProviderMemoryLoader(),
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            locale: context.locale,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            home: const Scaffold(
              body: SupportSettingsPanel(
                focus: SupportSettingsFocus.connection,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _workspaceIdle(tester, f);
  await f.join(
    tester,
    () => f.root.container.read(supportConnectionMetadataProvider.future),
    label: 'original API picker metadata settled before passive baseline',
  );
  await tester.pump();
  expect(
    find.byKey(const ValueKey('support_connection_selector')),
    findsOneWidget,
  );
}

Future<Finder> _revealUse(WidgetTester tester, ProviderScreenFixture f) async {
  final use = find.byKey(const ValueKey('support_provider_use_astoria'));
  if (use.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      use,
      150,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('support_provider_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await f.reveal(tester, use);
  return use;
}

Future<void> _finishRoute(WidgetTester tester, Finder child) async {
  final route = ModalRoute.of(tester.element(child))!;
  await tester.pump();
  await tester.pump(route.transitionDuration + const Duration(microseconds: 1));
  await tester.pump();
  expect(route.isCurrent, isTrue);
}

Future<void> _openPicker(WidgetTester tester, ProviderScreenFixture f) async {
  final selector = find.byKey(const ValueKey('support_connection_selector'));
  await Scrollable.ensureVisible(tester.element(selector), alignment: 0.5);
  await tester.pump();
  expect(selector.hitTestable(), findsOneWidget);
  await f.real(tester, () => tester.tap(selector));
  await tester.pump();
  await _finishRoute(tester, find.text('Добавить провайдера'));
  expect(find.text('Не выбрано'), findsOneWidget);
  expect(find.text('Добавить провайдера').hitTestable(), findsOneWidget);
}

Future<void> _addFromPicker(
  WidgetTester tester,
  ProviderScreenFixture f,
) async {
  final add = find.text('Добавить провайдера');
  await f.real(tester, () => tester.tap(add));
  await f.until(
    tester,
    () => find.byType(SupportProviderSheet).evaluate().isNotEmpty,
    label: 'existing native provider entry from actual API picker',
  );
  await _finishRoute(tester, find.byType(SupportProviderSheet));
  await f.until(
    tester,
    () => f.controller(tester) == null || f.controller(tester)!.hasForm,
    label: 'direct creation after original native route binding',
  );
  await tester.pump();
  await tester.pump();
  expect(find.text('Добавить провайдера'), findsNothing);
}

Future<SupportProviderScreenController> _create(
  WidgetTester tester,
  ProviderScreenFixture f, {
  bool custom = false,
}) async {
  await _openPicker(tester, f);
  await _addFromPicker(tester, f);
  final c = f.controller(tester)!;
  expect(c.purpose, SupportProviderPurpose.astoria);
  expect(c.connections, isNull);
  expect(
    find.byKey(const ValueKey('support_provider_mode_create')),
    findsNothing,
  );
  for (final field in [
    'purpose',
    'max_tokens',
    'context_size',
    'temperature',
  ]) {
    expect(find.byKey(ValueKey('support_provider_$field')), findsNothing);
  }
  await f.text(tester, 'support_provider_name', 'Synthetic manual provider');
  await f.text(tester, 'support_provider_model', 'synthetic-manual-model');
  if (custom) {
    await f.tap(tester, 'support_provider_custom_endpoint');
    await f.text(tester, 'support_provider_endpoint', _endpoint);
  }
  await f.tap(tester, 'support_provider_review');
  final preview = c.binding.preview(c.review!)!;
  expect(preview.purpose, SupportProviderPurpose.astoria);
  expect(preview.after!.model, 'synthetic-manual-model');
  expect(preview.after!.maxTokens, 512);
  expect(preview.after!.contextSize, 32768);
  expect(preview.after!.temperature, 0.7);
  if (custom) {
    expect(preview.after!.endpoint, _endpoint);
    expect(preview.destinationKind, SupportProviderDestinationKind.customHttps);
    expect(
      tester
          .widget<SupportProviderButton>(
            find.byKey(const ValueKey('support_provider_confirm')),
          )
          .onTap,
      isNull,
    );
    await f.tap(tester, 'support_provider_custom_confirm');
  }
  expect(f.root.requests, isEmpty);
  await f.tap(tester, 'support_provider_confirm');
  final actual = await f.join(
    tester,
    () => c.originalJob!,
    label: 'original keyless native creation fact',
  );
  expect(actual.code, SupportProviderActionCode.applied);
  expect(actual.applied!.purpose, SupportProviderPurpose.astoria);
  await _revealUse(tester, f);
  return c;
}

void main() {
  providerScreenTest(
    'empty API picker has manual Add; default-OFF opening is passive',
    (tester, f) async {
      await _mountPanel(tester, f);
      expect(
        await f.join(
          tester,
          f.root.api.getConfigIds,
          label: 'empty API profiles',
        ),
        isEmpty,
      );
      await _openPicker(tester, f);
      final vault = List.of(f.root.backing.storage.operations);
      final reads = List.of(f.root.backing.events);
      await _addFromPicker(tester, f);
      expect(f.controller(tester), isNull);
      expect(find.byKey(const ValueKey('support_provider_form')), findsNothing);
      expect(
        tester
            .widget<SupportProviderButton>(
              find.byKey(const ValueKey('support_provider_permissions_open')),
            )
            .onTap,
        isNotNull,
      );
      expect(
        find.byKey(const ValueKey('support_provider_use_astoria')),
        findsNothing,
      );
      expect(f.root.backing.storage.operations, vault);
      expect(f.root.backing.events, reads);
      expect(f.root.requests, isEmpty);
      expect(
        f.root.controller.runtime.localPermissionSnapshot.preferences!.grants,
        isEmpty,
      );
    },
    permissions: false,
  );

  providerScreenTest(
    'manual custom URL -> exact review -> keyless create -> trusted key -> explicit Use only',
    (tester, f) async {
      await _mountPanel(tester, f);
      final before = await _saved(tester, f);
      final c = await _create(tester, f, custom: true);
      final applied = c.actualResult!.applied!;
      final id = applied.value!.connectionId;
      final row = await f.join(
        tester,
        () => f.root.api.getById(id),
        label: 'actual blank-key native provider row',
      );
      expect(row!.apiKey, isEmpty);
      expect(row.embeddingApiKey, isEmpty);
      expect(await _saved(tester, f), before); // Creation never selects it.
      expect(
        _settings(f.root.container.read(supportWorkspaceProvider).settings),
        before,
      );
      await f.tap(tester, 'support_provider_result_key_open');
      expect(c.keyEntry!.requiresCustomConfirmation, isTrue);
      expect(
        find.byKey(const ValueKey('support_provider_key_input')),
        findsNothing,
      );
      await f.tap(tester, 'support_provider_key_custom_confirm');
      await f.until(
        tester,
        () =>
            c.keyEntry?.readyForInput == true &&
            find
                .byKey(const ValueKey('support_provider_key_input'))
                .evaluate()
                .isNotEmpty,
        label: 'separate exact native key destination confirmation',
      );
      expect(c.keyEntry!.readyForInput, isTrue);
      await f.text(
        tester,
        'support_provider_key_input',
        ProviderActionFixture.secret,
      );
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('support_provider_key_input')),
      );
      expect(input.obscureText, isTrue);
      await f.tap(tester, 'support_provider_key_submit', waits: false);
      expect(input.controller!.text, isEmpty);
      await f.until(
        tester,
        () => find
            .descendant(
              of: find.byType(SupportProviderKeySheet),
              matching: find.text(
                'Key saved (${ProviderActionFixture.secret.runes.length})',
              ),
            )
            .evaluate()
            .isNotEmpty,
        label: 'original trusted native key submission settled',
      );
      expect(c.current, isTrue); // Its own config/key fences do not revoke it.
      expect(applied.value, isNotNull);
      expect(await _saved(tester, f), before); // Key entry is not assignment.
      final use = tester
          .widget<SupportProviderButton>(await _revealUse(tester, f))
          .onTap!;
      await f.tap(tester, 'support_provider_use_astoria', waits: false);
      await _workspaceIdle(tester, f);
      final expected = {
        ...before,
        'api': id,
        'model': 'synthetic-manual-model',
      };
      expect(await _saved(tester, f), expected);
      expect(
        _settings(f.root.container.read(supportWorkspaceProvider).settings),
        expected,
      );
      await f.real(tester, () async => use()); // Retained gesture cannot retry.
      await tester.pump();
      await _workspaceIdle(tester, f);
      expect(await _saved(tester, f), expected);
      expect(
        f.root.container.read(supportWorkspaceProvider).activeMessages,
        isEmpty,
      );
      expect(f.root.requests, isEmpty); // No catalog, probe or generation send.
      expect(find.text(ProviderActionFixture.secret), findsNothing);
    },
  );

  for (final owner in ['closed', 'B', 'A-B-A']) {
    providerScreenTest('retained original manual Use denied after $owner', (
      tester,
      f,
    ) async {
      await _mountPanel(tester, f);
      final a = await _saved(tester, f);
      final b = await _saved(tester, f, _otherSession);
      final c = await _create(tester, f);
      final retained = tester
          .widget<SupportProviderButton>(
            find.byKey(const ValueKey('support_provider_use_astoria')),
          )
          .onTap!;
      if (owner == 'closed') {
        await f.tap(tester, 'support_provider_cancel', waits: false);
      } else {
        await f.join(tester, () async {
          _workspace(f).selectSession(_otherSession);
          await _workspace(f).refresh();
          if (owner == 'A-B-A') {
            _workspace(f).selectSession(ProviderActionFixture.sessionId);
            await _workspace(f).refresh();
          }
        }, label: 'actual workspace owner replacement');
      }
      await f.real(tester, () async => retained());
      await tester.pump();
      await _workspaceIdle(tester, f);
      expect(c.current, isFalse);
      expect(await _saved(tester, f), a);
      expect(await _saved(tester, f, _otherSession), b);
      expect(f.root.requests, isEmpty);
    });
  }

  providerScreenTest(
    'manual Use callback rejects a foreign original applied handle',
    (tester, f) async {
      await _mountPanel(tester, f);
      final before = await _saved(tester, f);
      final c = await _create(tester, f);
      final use = tester
          .widget<SupportProviderSheet>(find.byType(SupportProviderSheet))
          .onUseConnection!;
      final foreign = f.root.bind();
      final other = await f.join(tester, () async {
        final review = (await foreign.prepare(
          const SupportProviderSetupInput(
            purpose: SupportProviderPurpose.astoria,
            name: 'Synthetic foreign provider',
            protocol: 'openai',
            endpoint: 'https://api.openai.com/v1/chat/completions',
            model: 'synthetic-foreign-model',
            maxTokens: 512,
            contextSize: 32768,
            temperature: 0.7,
          ),
        ))!;
        return foreign.confirm(review)!;
      }, label: 'foreign actual native creation');
      expect(other.applied!.value, isNotNull);
      expect(c.current, isTrue);
      expect(use(other.applied!), isFalse);
      await tester.pump();
      await _workspaceIdle(tester, f);
      expect(await _saved(tester, f), before);
      expect(f.root.requests, isEmpty);
    },
  );

  providerScreenTest(
    'manual Add retains settings intent from before the API picker',
    (tester, f) async {
      await _mountPanel(tester, f);
      await _openPicker(tester, f);
      final add = find
          .ancestor(
            of: find.text('Добавить провайдера'),
            matching: find.byType(GestureDetector),
          )
          .first;
      final retained = tester.widget<GestureDetector>(add).onTap!;
      await f.join(tester, () async {
        _workspace(f).selectSession(_otherSession);
        await _workspace(f).refresh();
        _workspace(f).selectSession(ProviderActionFixture.sessionId);
        await _workspace(f).refresh();
      }, label: 'A-B-A before manual Add');
      await f.real(tester, () async => retained());
      await tester.pump();
      await tester.pump();
      expect(find.byType(SupportProviderSheet), findsNothing);
      expect(f.root.requests, isEmpty);
    },
  );
}
