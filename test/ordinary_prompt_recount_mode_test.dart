import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/studio_feature_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/providers/prompt_build_providers.dart';
import 'package:glaze_flutter/features/chat/state/cached_token_breakdown.dart';
import 'package:glaze_flutter/features/chat/state/context_window_marker.dart';
import 'package:glaze_flutter/features/chat/widgets/tokenizer_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/tokenizer_widgets.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

final _studioEnabled = StateProvider<bool>((ref) => false);
final _selectedPreset = StateProvider<StudioPreset?>((ref) => null);
final _apiConfig = StateProvider<ApiConfig>(
  (ref) => const ApiConfig(id: 'api'),
);

const _studioPreset = StudioPreset(
  id: 'selected-studio',
  agents: [StudioAgent(id: 'writer', specId: 'final')],
);
final _ordinaryCollected = StateError(
  'Ordinary inputs collected; stop before worker',
);

/// The collector is the stop boundary: no worker, app storage or network can
/// run even when a regression unexpectedly takes the ordinary preparation path.
class _CountingBuilder implements PromptPayloadBuilder {
  int calls = 0;

  @override
  Future<PromptInputs> collectInputs({
    required String charId,
    required ChatSession? session,
    String? guidanceText,
  }) {
    calls++;
    return Future.error(_ordinaryCollected);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chat extends ChatNotifier {
  _Chat() : super('c1');

  @override
  Future<ChatState> build() async => ChatState(session: _session('c1_0'));

  void useOtherSession() =>
      state = AsyncData(ChatState(session: _session('c1_1')));

  void busy() =>
      state = AsyncData(state.requireValue.copyWith(isSendPending: true));
}

ChatSession _session(String id) => ChatSession(
  id: id,
  characterId: 'c1',
  sessionIndex: id == 'c1_0' ? 0 : 1,
  messages: [
    for (var i = 0; i < 5; i++)
      ChatMessage(id: 'm$i', role: 'user', content: 'message $i', timestamp: i),
  ],
);

class _Presets extends PresetListNotifier {
  @override
  Future<List<Preset>> build() async => const [];
}

Future<ProviderContainer> _container(
  _CountingBuilder builder, {
  required bool studio,
  StudioPreset? preset = _studioPreset,
  Completer<bool>? modeLoading,
}) async {
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWith(
        (ref) => throw StateError('Unexpected app DB'),
      ),
      sharedPreferencesProvider.overrideWith(
        (ref) async => throw StateError('Unexpected preferences'),
      ),
      _studioEnabled.overrideWith((ref) => studio),
      _selectedPreset.overrideWith((ref) => preset),
      studioFeatureSettledProvider.overrideWith((ref) async {
        final enabled = ref.watch(_studioEnabled);
        if (modeLoading != null) await modeLoading.future;
        return enabled;
      }),
      studioPresetProvider.overrideWith(
        (ref) async => ref.watch(_selectedPreset),
      ),
      activeApiConfigProvider.overrideWith((ref) => ref.watch(_apiConfig)),
      chatProvider('c1').overrideWith(_Chat.new),
      presetListProvider.overrideWith(_Presets.new),
      promptPayloadBuilderProvider.overrideWithValue(builder),
    ],
  );
  addTearDown(container.dispose);
  await container.read(chatProvider('c1').future);
  return container;
}

TokenBreakdown _breakdown({int contextSize = 1000}) =>
    ContextCalculator(contextSize: contextSize, maxTokens: 1000).calculate(
      staticBlocks: const [],
      historyMessages: [
        for (var i = 0; i < 5; i++)
          PromptMessage(
            role: 'user',
            content: 'message $i',
            sourceMessageId: 'm$i',
            isHistory: true,
          ),
      ],
    );

void main() {
  group('ordinary recount mode', () {
    test(
      'Studio skips the collector and retains the session-stamped boundary',
      () async {
        final builder = _CountingBuilder();
        final container = await _container(builder, studio: true);
        container.read(cachedTokenBreakdownProvider('c1').notifier).state =
            _breakdown();
        container
                .read(cachedTokenBreakdownSessionProvider('c1').notifier)
                .state =
            'c1_0';
        final subscription = container.listen(
          contextWindowBoundaryProvider('c1'),
          (_, _) {},
        );
        addTearDown(subscription.close);

        expect(
          await container.read(contextWindowRecountProvider('c1').future),
          isNull,
        );
        expect(builder.calls, 0);
        expect(
          container.read(contextWindowBoundaryProvider('c1')),
          const ContextWindowBoundary('m4', afterMessage: true),
        );

        container
                .read(cachedTokenBreakdownSessionProvider('c1').notifier)
                .state =
            'another-session';
        expect(container.read(contextWindowBoundaryProvider('c1')), isNull);
      },
    );

    for (final studio in [false, true]) {
      test(
        'ordinary collection remains enabled when studio=$studio and ${studio ? 'no preset resolves' : 'a Studio preset is inactive'}',
        () async {
          final builder = _CountingBuilder();
          final container = await _container(
            builder,
            studio: studio,
            preset: studio ? null : _studioPreset,
          );
          final subscription = container.listen(
            contextWindowRecountProvider('c1'),
            (_, _) {},
          );
          addTearDown(subscription.close);

          await expectLater(
            container.read(contextWindowRecountProvider('c1').future),
            throwsA(same(_ordinaryCollected)),
          );
          expect(builder.calls, 1);
        },
      );
    }

    test('mode loading never briefly starts an ordinary recount', () async {
      final loading = Completer<bool>();
      final builder = _CountingBuilder();
      final container = await _container(
        builder,
        studio: true,
        modeLoading: loading,
      );
      final subscription = container.listen(
        contextWindowRecountProvider('c1'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final result = container.read(contextWindowRecountProvider('c1').future);
      expect(builder.calls, 0);
      loading.complete(true);
      expect(await result, isNull);
      expect(builder.calls, 0);
    });

    test(
      'changing the selected Studio preset reacts without an ordinary build',
      () async {
        final builder = _CountingBuilder();
        final container = await _container(builder, studio: true);
        final subscription = container.listen(
          ordinaryPromptRecountEnabledProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);
        expect(
          await container.read(ordinaryPromptRecountEnabledProvider.future),
          isFalse,
        );
        container.read(_selectedPreset.notifier).state = null;
        expect(
          await container.read(ordinaryPromptRecountEnabledProvider.future),
          isTrue,
        );
        container.read(_selectedPreset.notifier).state = _studioPreset;
        expect(
          await container.read(ordinaryPromptRecountEnabledProvider.future),
          isFalse,
        );
        container.read(_studioEnabled.notifier).state = false;
        expect(
          await container.read(ordinaryPromptRecountEnabledProvider.future),
          isTrue,
        );
        expect(builder.calls, 0);
      },
    );

    test('empty or retired-agent presets retain ordinary fallback', () async {
      final builder = _CountingBuilder();
      final container = await _container(
        builder,
        studio: true,
        preset: const StudioPreset(id: 'empty'),
      );
      final subscription = container.listen(
        ordinaryPromptRecountEnabledProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(
        await container.read(ordinaryPromptRecountEnabledProvider.future),
        isTrue,
      );
      container.read(_selectedPreset.notifier).state = const StudioPreset(
        id: 'retired',
        agents: [StudioAgent(id: 'retired', specId: 'unknown')],
      );
      expect(
        await container.read(ordinaryPromptRecountEnabledProvider.future),
        isTrue,
      );
    });

    test('busy ordinary sessions still skip collection', () async {
      final builder = _CountingBuilder();
      final container = await _container(builder, studio: false);
      (container.read(chatProvider('c1').notifier) as _Chat).busy();
      final subscription = container.listen(
        contextWindowRecountProvider('c1'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(
        await container.read(contextWindowRecountProvider('c1').future),
        isNull,
      );
      expect(builder.calls, 0);
    });

    test(
      'runnable-agent gate matches final, phase and Think overrides',
      () async {
        final container = await _container(_CountingBuilder(), studio: true);
        final subscription = container.listen(
          ordinaryPromptRecountEnabledProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);
        for (final (preset, ordinary) in [
          (
            const StudioPreset(
              id: 'forced-final',
              agents: [
                StudioAgent(id: 'writer', specId: 'final', enabled: false),
              ],
              agentEnabled: {'final': false},
            ),
            false,
          ),
          (
            const StudioPreset(
              id: 'controller',
              agents: [StudioAgent(id: 'controller', specId: 'continuity')],
            ),
            false,
          ),
          (
            const StudioPreset(
              id: 'disabled-controller',
              agents: [StudioAgent(id: 'controller', specId: 'continuity')],
              agentEnabled: {'continuity': false},
            ),
            true,
          ),
          (
            const StudioPreset(
              id: 'wrong-phase',
              agents: [
                StudioAgent(
                  id: 'controller',
                  specId: 'continuity',
                  phase: 'post_processing',
                ),
              ],
            ),
            true,
          ),
          (
            const StudioPreset(
              id: 'inactive-think',
              agents: [StudioAgent(id: 'think', specId: 'think')],
            ),
            true,
          ),
          (
            const StudioPreset(
              id: 'forced-think',
              agents: [
                StudioAgent(id: 'think', specId: 'think', enabled: false),
              ],
              agentEnabled: {'think': true},
            ),
            false,
          ),
        ]) {
          container.read(_selectedPreset.notifier).state = preset;
          expect(
            await container.read(ordinaryPromptRecountEnabledProvider.future),
            ordinary,
            reason: preset.id,
          );
        }
      },
    );
  });

  group('mounted TokenizerSheet', () {
    Future<void> mount(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: TokenizerSheet(charId: 'c1', embedded: true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'Studio shows cached breakdown without collection after session or API changes',
      (tester) async {
        final builder = _CountingBuilder();
        final container = await _container(builder, studio: true);
        final cached = _breakdown(contextSize: 10000);
        container.read(cachedTokenBreakdownProvider('c1').notifier).state =
            cached;
        container
                .read(cachedTokenBreakdownSessionProvider('c1').notifier)
                .state =
            'c1_0';
        await mount(tester, container);
        expect(builder.calls, 0);
        expect(
          tester
              .widget<TokenizerLayout>(find.byType(TokenizerLayout))
              .breakdown,
          same(cached),
        );

        (container.read(chatProvider('c1').notifier) as _Chat).useOtherSession();
        container.read(_apiConfig.notifier).state = const ApiConfig(
          id: 'api',
          contextSize: 20000,
        );
        await tester.pump();
        await tester.pump();
        expect(builder.calls, 0);
        expect(
          container.read(cachedTokenBreakdownProvider('c1')),
          same(cached),
        );
        expect(find.byType(TokenizerLayout), findsNothing);

        final updated = _breakdown(contextSize: 20000);
        container.read(cachedTokenBreakdownProvider('c1').notifier).state =
            updated;
        await tester.pump();
        expect(find.byType(TokenizerLayout), findsNothing);
        container
                .read(cachedTokenBreakdownSessionProvider('c1').notifier)
                .state =
            'c1_1';
        await tester.pump();
        expect(
          tester
              .widget<TokenizerLayout>(find.byType(TokenizerLayout))
              .breakdown,
          same(updated),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('ordinary mode still collects on opening and session change', (
      tester,
    ) async {
      final builder = _CountingBuilder();
      final container = await _container(builder, studio: false);
      await mount(tester, container);
      expect(builder.calls, 1);
        (container.read(chatProvider('c1').notifier) as _Chat).useOtherSession();
      await tester.pump();
      await tester.pump();
      expect(builder.calls, 2);
      container.read(_apiConfig.notifier).state = const ApiConfig(
        id: 'api',
        contextSize: 20000,
      );
      await tester.pump();
      await tester.pump();
      expect(builder.calls, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'switching a mounted sheet from Studio to ordinary enables recount',
      (tester) async {
        final builder = _CountingBuilder();
        final container = await _container(builder, studio: true);
        await mount(tester, container);
        expect(builder.calls, 0);
        container.read(_studioEnabled.notifier).state = false;
        await tester.pump();
        await tester.pump();
        expect(builder.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
