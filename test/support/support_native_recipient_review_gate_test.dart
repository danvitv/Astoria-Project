import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

// Actual validated native review, same-scope memory AEAD/fake startup ports.
// No reconstructed recipient DTO, application startup or server request.
Future<List<String>> _renderReview(
  WidgetTester tester,
  NativeFixture f,
  String endpoint, {
  String protocol = LlmProtocol.openai,
  bool stream = true,
}) async {
  final review = (await tester.runAsync(() async {
    await f.api.put(
      ApiConfig(
        id: 'synthetic-connection',
        name: 'Synthetic selected connection',
        endpoint: endpoint,
        apiKey: NativeFixture.canary,
        model: 'synthetic-model',
        protocol: protocol,
        stream: stream,
      ),
    );
    return f.controller.prepareReview();
  }))!;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeWidgetOverrides(f),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
      ],
      child: localizedNativeWidget(
        SupportPrivacyReviewSheet(
          controller: f.controller,
          review: review,
          isCurrent: () => true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Synthetic selected connection'), findsOneWidget);
  expect(find.text('synthetic-model'), findsOneWidget);
  expect(find.textContaining('https://'), findsNothing);
  expect(find.textContaining(NativeFixture.canary), findsNothing);
  expect(find.textContaining('/v1/'), findsNothing);
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .toList();
}

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

  testWidgets('same name/model review distinguishes actual changed host', (
    tester,
  ) async {
    final original = await _renderReview(
      tester,
      f,
      'https://synthetic.invalid/v1/chat/completions',
    );
    final replacement = await _renderReview(
      tester,
      f,
      'https://replacement.invalid/v1/chat/completions',
    );
    expect(
      replacement,
      isNot(equals(original)),
      reason: 'Meaningful native consent must distinguish the actual host',
    );
    expect(f.runtime.recipientConfirmed, false);
    expect(f.selectedLoads, 0);
    expect(f.api.bulkReads, 0);
  });

  for (final width in [236.0, 360.0]) {
    testWidgets(
      'review origin scheme/port and operation are distinct at RU $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _renderReview(
          tester,
          f,
          'https://synthetic.invalid/v1/chat/completions',
        );
        expect(find.text('HTTPS · synthetic.invalid'), findsOneWidget);
        expect(find.text('Chat Completions'), findsOneWidget);
        await _renderReview(
          tester,
          f,
          'http://synthetic.invalid:8080/v1/chat/completions',
        );
        expect(find.text('HTTP · synthetic.invalid:8080'), findsOneWidget);
        expect(find.text('HTTPS · synthetic.invalid'), findsNothing);
        await _renderReview(
          tester,
          f,
          'https://synthetic.invalid/v1/responses',
          protocol: LlmProtocol.openaiResponses,
        );
        expect(find.text('Responses'), findsOneWidget);
        expect(find.text('Chat Completions'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'actual review displays fixed OpenRouter origin and downstream limitation',
    (tester) async {
      await _renderReview(
        tester,
        f,
        'https://saved.invalid/v1/chat/completions',
        protocol: LlmProtocol.openrouter,
      );
      expect(find.text('HTTPS · openrouter.ai'), findsOneWidget);
      expect(find.text('Chat Completions'), findsOneWidget);
      expect(find.textContaining('downstream'), findsOneWidget);
      expect(find.textContaining('saved.invalid'), findsNothing);
    },
  );

  testWidgets(
    'actual Gemini reviews distinguish both operations without showing model path',
    (tester) async {
      for (final stream in [false, true]) {
        await _renderReview(
          tester,
          f,
          'https://synthetic.invalid',
          protocol: LlmProtocol.gemini,
          stream: stream,
        );
        expect(find.text('HTTPS · synthetic.invalid'), findsOneWidget);
        expect(
          find.text(
            stream ? 'Gemini streamGenerateContent' : 'Gemini generateContent',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('/models/'), findsNothing);
      }
    },
  );
}
