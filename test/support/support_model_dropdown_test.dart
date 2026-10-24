import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/llm/provider_model_catalog.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'support_guidance_screen_fixture.dart';
import '../core/provider_model_catalog_fixture.dart';

List<Object?> _values(SupportAssistantSettings settings) => [
  settings.mode,
  settings.apiConfigId,
  settings.modelId,
  settings.temperature,
  settings.maxTokens,
  settings.reasoningEffort,
  settings.dcpCompressionEnabled,
];

ModelCatalogHarness _catalog() {
  final h = ModelCatalogHarness(
    ApiConfig(
      id: guidanceProfile.connectionId,
      endpoint: guidanceProfile.endpoint,
      model: guidanceProfile.model,
      apiKey: 'SYNTHETIC_CATALOG_KEY_72',
    ),
  );
  addTearDown(h.close);
  return h;
}

Future<void> _open(WidgetTester tester, GuidanceScreenFixture f) async {
  await f.tapKey(tester, 'support_guidance_model');
  await f.tapKey(tester, 'support_model_selector');
}

void main() {
  late ModelCatalogHarness catalog;
  ProviderModelCatalog factory() => (catalog = _catalog()).service;
  guidanceScreenTest(
    'dropdown loads actual provider models once and only final Save changes settings',
    (tester, f) async {
      await f.action(
        tester,
        () => f.workspace.selectConnection(
          guidanceProfile.connectionId,
          defaultModelId: 'current-choice',
        ),
      );
      await f.idle(tester);
      final before = f.state.settings;
      await _open(tester, f);
      await f.turns.until(
        tester,
        () =>
            catalog.requests.length == 1 &&
            find.text('Загрузка моделей…').evaluate().isEmpty,
        label: 'the original HTTP catalog future is published',
      );
      await f.tapKey(tester, 'support_model_dropdown');

      for (final id in ['provider-first', 'provider-next']) {
        expect(
          find.byKey(ValueKey('support_model_option_$id')),
          findsOneWidget,
        );
      }
      for (final id in ['current-choice', 'synthetic-model']) {
        expect(find.byKey(ValueKey('support_model_option_$id')), findsNothing);
      }
      expect(catalog.requests.single.method, 'GET');
      expect(catalog.requests.single.uri.path, '/v1/models');
      expect(catalog.requests.single.data, isNull);
      await f.tapKey(tester, 'support_model_option_provider-next');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'provider-next',
      );
      expect(
        f.state.settings,
        before,
        reason: 'An option is not confirmation.',
      );
      expect(
        find.byKey(const ValueKey('support_model_option_provider-next')),
        findsNothing,
      );

      await f.tap(tester, find.text('Сохранить идентификатор'));
      await f.idle(tester);
      expect(f.state.settings.modelId, 'provider-next');
      expect(f.state.settings.apiConfigId, before.apiConfigId);
      expect((await f.saved(tester)).grants, isEmpty);
      f.noReadersOrWire();
    },
    screen: false,
    catalogFactory: factory,
  );

  guidanceScreenTest(
    'an empty dropdown keeps manual entry and performs no catalog request',
    (tester, f) async {
      await _open(tester, f);
      await f.tapKey(tester, 'support_model_dropdown');
      expect(
        find.text('Список моделей пуст. Укажи идентификатор ниже.'),
        findsOneWidget,
      );
      await f.reveal(tester, find.byType(TextField));
      await f.turns.real(
        tester,
        () => tester.enterText(find.byType(TextField), 'manual-model'),
      );
      await tester.pump();
      expect(f.state.settings.modelId, isNull);
      await f.tap(tester, find.text('Сохранить идентификатор'));
      await f.idle(tester);
      expect(f.state.settings.modelId, 'manual-model');
      f.noReadersOrWire();
    },
    screen: false,
    connections: const [],
  );

  guidanceScreenTest(
    'a provider option after session replacement cannot mutate either session',
    (tester, f) async {
      await f.action(
        tester,
        () => f.workspace.selectConnection(guidanceProfile.connectionId),
      );
      await f.idle(tester);
      final before = f.state.settings;
      await _open(tester, f);
      await f.turns.until(
        tester,
        () =>
            catalog.requests.length == 1 &&
            find.text('Загрузка моделей…').evaluate().isEmpty,
        label: 'the original HTTP catalog response is available',
      );
      await f.tapKey(tester, 'support_model_dropdown');
      final original = tester
          .widget<MenuItem>(
            find.byKey(const ValueKey('support_model_option_provider-first')),
          )
          .onTap;
      await f.turns.real(tester, () async {
        f.workspace.selectSession(GuidanceScreenFixture.other);
      });
      await f.idle(tester);
      final other = f.state.settings;
      await f.turns.real(tester, () async {
        original();
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(f.state.settings, other);
      await f.turns.real(tester, () async {
        f.workspace.selectSession(GuidanceScreenFixture.session);
      });
      await f.idle(tester);
      expect(_values(f.state.settings), _values(before));
      f.noReadersOrWire();
    },
    screen: false,
    catalogFactory: factory,
  );
}
