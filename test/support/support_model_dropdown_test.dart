import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_connection_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'support_guidance_screen_fixture.dart';

List<Object?> _values(SupportAssistantSettings settings) => [
  settings.mode,
  settings.apiConfigId,
  settings.modelId,
  settings.temperature,
  settings.maxTokens,
  settings.reasoningEffort,
  settings.dcpCompressionEnabled,
];

ApiConnectionMetadata _profile(
  String id,
  String model, {
  String endpoint = 'https://synthetic.invalid/v1/chat/completions',
  String protocol = 'openai',
  String mode = 'chat',
}) => ApiConnectionMetadata(
  connectionId: id,
  displayName: 'Synthetic saved profile',
  providerId: 'openai',
  protocol: protocol,
  mode: mode,
  endpoint: endpoint,
  model: model,
  llmCredential: CredentialMetadata.absent,
  embeddingCredential: CredentialMetadata.absent,
  embeddingUseSame: false,
  embeddingEnabled: false,
  embeddingEndpoint: '',
  embeddingModel: '',
  embeddingLlmPresetId: '',
);

Future<void> _open(WidgetTester tester, GuidanceScreenFixture f) async {
  await f.tapKey(tester, 'support_guidance_model');
  await f.tapKey(tester, 'support_model_selector');
}

void main() {
  guidanceScreenTest(
    'saved-model dropdown deduplicates only the same endpoint and edits a draft',
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
      await f.tapKey(tester, 'support_model_dropdown');

      for (final id in [
        'current-choice',
        'synthetic-model',
        'synthetic-next',
      ]) {
        expect(
          find.byKey(ValueKey('support_model_option_$id')),
          findsOneWidget,
        );
      }
      for (final id in [
        'foreign-origin',
        'foreign-protocol',
        'embedding-only',
      ]) {
        expect(find.byKey(ValueKey('support_model_option_$id')), findsNothing);
      }
      expect(find.text('bad\nmodel'), findsNothing);
      await f.tapKey(tester, 'support_model_option_synthetic-next');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'synthetic-next',
      );
      expect(
        f.state.settings,
        before,
        reason: 'An option is not confirmation.',
      );
      expect(
        find.byKey(const ValueKey('support_model_option_synthetic-next')),
        findsNothing,
      );

      await f.tap(tester, find.text('Сохранить идентификатор'));
      await f.idle(tester);
      expect(f.state.settings.modelId, 'synthetic-next');
      expect(f.state.settings.apiConfigId, before.apiConfigId);
      expect((await f.saved(tester)).grants, isEmpty);
      f.noReadersOrWire();
    },
    screen: false,
    connections: [
      guidanceProfile,
      _profile('duplicate', 'synthetic-model'),
      _profile('next', 'synthetic-next'),
      _profile(
        'other-host',
        'foreign-origin',
        endpoint: 'https://other.invalid/v1/chat/completions',
      ),
      _profile('other-protocol', 'foreign-protocol', protocol: 'anthropic'),
      _profile('embedding', 'embedding-only', mode: 'embedding'),
      _profile('invalid', 'bad\nmodel'),
    ],
  );

  guidanceScreenTest(
    'an empty dropdown keeps manual entry and performs no catalog request',
    (tester, f) async {
      await _open(tester, f);
      await f.tapKey(tester, 'support_model_dropdown');
      expect(
        find.text('Сохранённых моделей нет. Укажи идентификатор ниже.'),
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
    'a saved option after session replacement cannot mutate either session',
    (tester, f) async {
      await f.action(
        tester,
        () => f.workspace.selectConnection(guidanceProfile.connectionId),
      );
      await f.idle(tester);
      final before = f.state.settings;
      await _open(tester, f);
      await f.tapKey(tester, 'support_model_dropdown');
      final original = tester
          .widget<MenuItem>(
            find.byKey(const ValueKey('support_model_option_synthetic-model')),
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
  );
}
