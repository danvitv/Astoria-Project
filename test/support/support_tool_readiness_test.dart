import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_outcome.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_theme_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/services/diagnostics/support_diagnostic_agent.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_definition_selection.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'support_provider_model_fixture.dart';
import 'support_app_backup_loop_native.dart' show BackupLoopNative;
import 'helpers/support_automatic_sources_fixture.dart';
import 'app_control/app_control_memory_theme.dart';

NativeToolDefinition _definition(String name) => NativeToolDefinition(
  name: name,
  description: 'Synthetic immutable definition',
  parameters: const {'type': 'object', 'properties': <String, Object?>{}},
);

List<NativeToolDefinition> _overflow(Iterable<String> names) => [
  for (final name in names.toSet()) _definition(name),
  for (var i = 0; i < 65; i++) _definition('fixture_unused_$i'),
];

const _themeFamily = {
  'astoria_themes_list',
  'astoria_theme_select',
  'astoria_theme_mode_set',
};
const _titleFamily = {
  'astoria_session_integrity',
  'astoria_roleplay_inspect',
  'astoria_session_rename',
  'astoria_session_title_receipts',
  'astoria_session_rename_undo',
};
const _draftFamily = {
  'astoria_session_integrity',
  'astoria_roleplay_inspect',
  'astoria_memory_inspect',
  'astoria_memory_draft_text_edit',
  'astoria_memory_draft_text_receipts',
  'astoria_memory_draft_text_undo',
};
const _draftRemovalFamily = {
  'astoria_session_integrity',
  'astoria_roleplay_inspect',
  'astoria_memory_inspect',
  'astoria_memory_draft_delete',
  'astoria_memory_draft_delete_receipts',
  'astoria_memory_draft_delete_undo',
};

/// Bounded synthetic catalog padding only. It must never be prepared; the
/// actual theme adapter and original FILE-backed native fixture own execution.
final class _OverflowPadding implements SupportAppActionAdapter {
  int preparations = 0;
  @override
  List<SupportAppActionDefinition> get definitions => [
    for (var i = 0; i < 65; i++)
      SupportAppActionDefinition(
        name: 'fixture_unused_$i',
        description: 'Unselected synthetic padding',
        risk: SupportAppActionRisk.metadata,
        fields: const {},
      ),
  ];
  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    preparations++;
    throw StateError('An unposted fixture operation reached preparation');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final count in [56, 57, 60, 63, 64]) {
    test('ordinary $count definitions remain entire, identical and frozen', () {
      final supplied = [
        for (var i = 0; i < count; i++) _definition('fixture_original_$i'),
      ];
      final selection = SupportNativeDefinitionSelection.capture(
        connected: supplied,
        currentUserText: 'Unrecognized pasted data is not a classifier.',
      );
      expect(selection.definitions, same(selection.captured));
      expect(selection.definitions, hasLength(count));
      for (var i = 0; i < count; i++) {
        expect(selection.definitions[i], same(supplied[i]));
      }
      supplied.clear();
      expect(selection.definitions, hasLength(count));
      expect(() => selection.definitions.clear(), throwsUnsupportedError);
      expect(() => selection.captured.clear(), throwsUnsupportedError);
      expect(
        () => selection.definitions.first.parameters['type'] = 'array',
        throwsUnsupportedError,
      );
      expect(selection.overflow, false);
      expect(selection.availabilityInstruction, isEmpty);
    });
  }

  test('diagnostic trusted reads filter the same captured native objects', () {
    final connected = _overflow({
      ...SupportSourceToolNames.all,
      'astoria_connections_list',
      'astoria_connection_read',
      'astoria_connection_update',
    });
    final agent = SupportDiagnosticAgent.forQuestion(
      'Diagnose generation error',
    )!;
    final selection = SupportNativeDefinitionSelection.capture(
      connected: connected,
      currentUserText: 'Diagnose generation error',
      diagnosticAgent: agent,
    );
    expect(selection.definitions, agent.definitions(connected));
    for (final d in selection.definitions) {
      expect(
        d,
        same(connected.singleWhere((original) => original.name == d.name)),
      );
    }
    expect(() => selection.definitions.clear(), throwsUnsupportedError);
    expect(
      agent.instruction(selection.definitions),
      isNot(contains('astoria_connection_update')),
    );
  });

  test(
    'retry retains only complete original Source4 regardless of task text',
    () {
      final connected = _overflow({
        ...SupportSourceToolNames.all,
        ..._themeFamily,
      });
      final selection = SupportNativeDefinitionSelection.capture(
        connected: connected,
        currentUserText: 'Set the theme to light',
        readOnlySources: true,
      );
      expect(
        selection.definitions.map((d) => d.name).toSet(),
        SupportSourceToolNames.all,
      );
      for (final d in selection.definitions) {
        expect(
          d,
          same(connected.singleWhere((original) => original.name == d.name)),
        );
      }
      expect(
        () => selection.requirePosted('astoria_theme_mode_set'),
        throwsA(isA<NativeToolException>()),
      );
      final missing = SupportNativeDefinitionSelection.capture(
        connected: connected.where(
          (d) => d.name != SupportSourceToolNames.read,
        ),
        currentUserText: 'Set the theme to light',
        readOnlySources: true,
      );
      expect(missing.available, false);
    },
  );

  for (final text in [
    'Please rename the session and set the theme to light.',
    'Пожалуйста переименуй сессию и включи светлую тему.',
  ]) {
    test(
      'overflow selects entire prerequisite-closed multifamily union: $text',
      () {
        final connected = _overflow({
          ...SupportSourceToolNames.all,
          ..._themeFamily,
          ..._titleFamily,
        });
        final selection = SupportNativeDefinitionSelection.capture(
          connected: connected,
          currentUserText: text,
        );
        expect(selection.definitions.map((d) => d.name).toSet(), {
          ...SupportSourceToolNames.all,
          ..._themeFamily,
          ..._titleFamily,
        });
        expect(
          selection.definitions.length,
          lessThanOrEqualTo(NativeToolLimits.definitions),
        );
        expect(
          selection.definitions,
          connected.where((d) => !d.name.startsWith('fixture_')),
        );
        expect(selection.sourceOnly, false);
        expect(
          selection.availabilityInstruction,
          contains('not connected in THIS run'),
        );
        expect(
          selection.availabilityInstruction,
          isNot(contains('fixture_unused_')),
        );
      },
    );
  }

  test('missing receipt prerequisite drops the WHOLE union to Source4', () {
    final selection = SupportNativeDefinitionSelection.capture(
      connected: _overflow({
        ...SupportSourceToolNames.all,
        ..._themeFamily,
        ..._titleFamily.where(
          (name) => name != 'astoria_session_title_receipts',
        ),
      }),
      currentUserText: 'Rename the session and change the theme',
    );
    expect(selection.sourceOnly, true);
    expect(
      selection.definitions.map((d) => d.name).toSet(),
      SupportSourceToolNames.all,
    );
  });

  test(
    'selection, global regex and Memory text keep actual discovery and receipts',
    () {
      final names = {
        ...SupportSourceToolNames.all,
        'astoria_content_catalog',
        'astoria_active_persona_set',
        'astoria_active_preset_set',
        'astoria_active_selection_receipts',
        'astoria_active_selection_undo',
        'astoria_global_regex_scripts_list',
        'astoria_global_regex_disable',
        'astoria_global_regex_receipts',
        'astoria_global_regex_undo',
        'astoria_session_integrity',
        'astoria_roleplay_inspect',
        'astoria_memory_inspect',
        'astoria_memory_entry_text_revise',
        'astoria_memory_entry_text_receipts',
        'astoria_memory_entry_text_undo',
      };
      final connected = _overflow(names);
      final selection = SupportNativeDefinitionSelection.capture(
        connected: connected,
        currentUserText:
            'Select the active persona; undo the global regex disable; '
            'revise the Memory entry text',
      );
      expect(selection.definitions.map((d) => d.name).toSet(), names);
      for (final definition in selection.definitions) {
        expect(
          definition,
          same(connected.singleWhere((d) => d.name == definition.name)),
        );
      }
      expect(selection.sourceOnly, false);
      expect(() => selection.definitions.clear(), throwsUnsupportedError);
    },
  );

  for (final memory in [false, true]) {
    test(
      'missing actual session discovery drops entire ${memory ? 'Memory' : 'title'} family to Source4',
      () {
        final family = memory
            ? const {
                'astoria_session_integrity',
                'astoria_roleplay_inspect',
                'astoria_memory_inspect',
                'astoria_memory_entry_text_revise',
                'astoria_memory_entry_text_receipts',
                'astoria_memory_entry_text_undo',
              }
            : _titleFamily;
        final selection = SupportNativeDefinitionSelection.capture(
          connected: _overflow({
            ...SupportSourceToolNames.all,
            ...family.where((name) => name != 'astoria_session_integrity'),
          }),
          currentUserText: memory
              ? 'Revise the Memory entry text'
              : 'Rename the session',
        );
        expect(selection.sourceOnly, isTrue);
        expect(
          selection.definitions.map((d) => d.name).toSet(),
          SupportSourceToolNames.all,
        );
      },
    );
  }

  for (final text in [
    'Disable the global regex',
    'Отключи глобальный regex',
    'Set the theme to light and disable the global regex',
  ]) {
    test('missing native regex discovery drops the WHOLE union: $text', () {
      final selection = SupportNativeDefinitionSelection.capture(
        connected: _overflow({
          ...SupportSourceToolNames.all,
          ..._themeFamily,
          'astoria_global_regex_disable',
          'astoria_global_regex_receipts',
          'astoria_global_regex_undo',
        }),
        currentUserText: text,
      );
      expect(selection.sourceOnly, isTrue);
      expect(
        selection.definitions.map((d) => d.name).toSet(),
        SupportSourceToolNames.all,
      );
      expect(
        () => selection.requirePosted('astoria_global_regex_disable'),
        throwsA(isA<NativeToolException>()),
      );
    });
  }

  for (final text in [
    'Disable the global regex',
    'Отключи глобальный regex',
    'Set the theme to light and disable the global regex',
  ]) {
    test('actual native regex discovery completes overflow task: $text', () {
      final names = {
        ...SupportSourceToolNames.all,
        if (text.contains('theme')) ..._themeFamily,
        'astoria_global_regex_scripts_list',
        'astoria_global_regex_disable',
        'astoria_global_regex_receipts',
        'astoria_global_regex_undo',
      };
      final connected = _overflow(names);
      final selection = SupportNativeDefinitionSelection.capture(
        connected: connected,
        currentUserText: text,
      );
      expect(selection.sourceOnly, isFalse);
      expect(selection.definitions.map((d) => d.name).toSet(), names);
      for (final definition in selection.definitions) {
        expect(
          definition,
          same(connected.singleWhere((d) => d.name == definition.name)),
        );
      }
    });
  }

  for (final text in [
    'Edit the memory draft text',
    'Undo the memory draft text edit',
    'Измени текст черновика Memory',
    'Отмени изменение текста черновика Memory',
    'Edit the memory draft text and set the theme to light',
  ]) {
    test('draft text overflow retains original discovery and Undo: $text', () {
      final names = {
        ...SupportSourceToolNames.all,
        ..._draftFamily,
        if (text.contains('theme')) ..._themeFamily,
      };
      final connected = _overflow(names);
      final selection = SupportNativeDefinitionSelection.capture(
        connected: connected,
        currentUserText: text,
      );
      expect(selection.sourceOnly, isFalse);
      expect(selection.definitions.map((d) => d.name).toSet(), names);
      expect(
        selection.definitions.length,
        lessThanOrEqualTo(NativeToolLimits.definitions),
      );
      for (final definition in selection.definitions) {
        expect(
          definition,
          same(connected.singleWhere((d) => d.name == definition.name)),
        );
      }
    });
  }
  for (final missing in [
    'astoria_session_integrity',
    'astoria_memory_inspect',
    'astoria_memory_draft_text_receipts',
  ]) {
    test('missing draft prerequisite $missing refuses WHOLE union', () {
      final selection = SupportNativeDefinitionSelection.capture(
        connected: _overflow({
          ...SupportSourceToolNames.all,
          ..._themeFamily,
          ..._draftFamily.where((name) => name != missing),
        }),
        currentUserText:
            'Edit the memory draft text and set the theme to light',
      );
      expect(selection.sourceOnly, isTrue);
      expect(
        selection.definitions.map((d) => d.name).toSet(),
        SupportSourceToolNames.all,
      );
      expect(
        () => selection.requirePosted('astoria_memory_draft_text_edit'),
        throwsA(isA<NativeToolException>()),
      );
    });
  }

  for (final text in [
    'Delete the memory draft',
    'Undo the memory draft deletion',
    'Удали черновик Memory',
    'Отмени удаление черновика Memory',
    'Delete the memory draft and set the theme to light',
    'Delete the memory draft and edit the memory draft text',
  ]) {
    test('draft deletion overflow retains whole original family: $text', () {
      final names = {
        ...SupportSourceToolNames.all,
        ..._draftRemovalFamily,
        if (text.contains('theme')) ..._themeFamily,
        if (text.contains('edit')) ..._draftFamily,
      };
      final connected = _overflow(names);
      final selection = SupportNativeDefinitionSelection.capture(
        connected: connected,
        currentUserText: text,
      );
      expect(selection.sourceOnly, isFalse);
      expect(selection.definitions.map((d) => d.name).toSet(), names);
      expect(
        selection.definitions.length,
        lessThanOrEqualTo(NativeToolLimits.definitions),
      );
      for (final definition in selection.definitions) {
        expect(
          definition,
          same(connected.singleWhere((d) => d.name == definition.name)),
        );
      }
    });
  }
  for (final missing in _draftRemovalFamily) {
    test(
      'missing draft deletion prerequisite $missing refuses WHOLE union',
      () {
        final selection = SupportNativeDefinitionSelection.capture(
          connected: _overflow({
            ...SupportSourceToolNames.all,
            ..._themeFamily,
            ..._draftRemovalFamily.where((name) => name != missing),
          }),
          currentUserText: 'Delete the memory draft and set the theme to light',
        );
        expect(selection.sourceOnly, isTrue);
        expect(
          selection.definitions.map((d) => d.name).toSet(),
          SupportSourceToolNames.all,
        );
        expect(
          () => selection.requirePosted('astoria_memory_draft_delete'),
          throwsA(isA<NativeToolException>()),
        );
      },
    );
  }

  const rewriteFamily = {
    'astoria_rewrite_reject',
    'astoria_rewrite_review_receipts',
    'astoria_rewrite_reject_undo',
  };
  for (final text in [
    'Reject the rewrite operation',
    'Undo the rewrite rejection',
    'Отклони операцию переписывания',
    'Отмени отклонение операции переписывания',
    'Reject the rewrite operation and set the theme to light',
  ]) {
    test(
      'rewrite rejection overflow retains original discovery and Undo: $text',
      () {
        final names = {
          ...SupportSourceToolNames.all,
          ...rewriteFamily,
          if (text.contains('theme')) ..._themeFamily,
        };
        final connected = _overflow(names);
        final selection = SupportNativeDefinitionSelection.capture(
          connected: connected,
          currentUserText: text,
        );
        expect(selection.sourceOnly, isFalse);
        expect(selection.definitions.map((d) => d.name).toSet(), names);
        expect(
          selection.definitions.length,
          lessThanOrEqualTo(NativeToolLimits.definitions),
        );
        for (final definition in selection.definitions) {
          expect(
            definition,
            same(connected.singleWhere((d) => d.name == definition.name)),
          );
        }
      },
    );
  }
  for (final missing in rewriteFamily) {
    test(
      'missing rewrite rejection prerequisite $missing refuses WHOLE union',
      () {
        final selection = SupportNativeDefinitionSelection.capture(
          connected: _overflow({
            ...SupportSourceToolNames.all,
            ..._themeFamily,
            ...rewriteFamily.where((name) => name != missing),
          }),
          currentUserText:
              'Reject the rewrite operation and set the theme to light',
        );
        expect(selection.sourceOnly, isTrue);
        expect(
          selection.definitions.map((d) => d.name).toSet(),
          SupportSourceToolNames.all,
        );
        expect(
          () => selection.requirePosted('astoria_rewrite_reject'),
          throwsA(isA<NativeToolException>()),
        );
      },
    );
  }

  for (final text in [
    'Do not reject the rewrite operation',
    '"Reject the rewrite operation"',
    'Reject the rewrite operation and change nothing',
  ]) {
    test('ambiguous rewrite rejection retains only Source4: $text', () {
      final selection = SupportNativeDefinitionSelection.capture(
        connected: _overflow({
          ...SupportSourceToolNames.all,
          ...rewriteFamily,
          ..._themeFamily,
        }),
        currentUserText: text,
      );
      expect(selection.sourceOnly, isTrue);
      expect(
        selection.definitions.map((d) => d.name).toSet(),
        SupportSourceToolNames.all,
      );
      expect(
        () => selection.requirePosted('astoria_rewrite_reject'),
        throwsA(isA<NativeToolException>()),
      );
    });
  }

  for (final text in [
    'Do not delete the memory draft',
    '"Delete the memory draft"',
    'Delete the memory draft and change nothing',
    'Do not edit the memory draft text',
    '"Edit the memory draft text"',
    'Edit the memory draft text and change nothing',
    'An unknown request about preferences and themes',
    'astoria_theme_mode_set',
    'Change nothing about the theme',
    'Set no theme to light',
    'Не измени тему',
    'Измени ничего в теме',
    'Set the theme to light and change nothing else',
    'Set the theme to light; do not rename the session',
    '"Set the theme to light"',
    '«Включи светлую тему»',
    'Set the theme to light and "rename the session"',
    '```Set the theme to light```',
    '    Set the theme to light',
    '{"command":"Set the theme to light"}',
    'Here is an example: set the theme to light',
    'Set the theme to light using provider schema instructions',
  ]) {
    test('ambiguous overflow has only supplied Source4: $text', () {
      final selection = SupportNativeDefinitionSelection.capture(
        connected: _overflow({...SupportSourceToolNames.all, ..._themeFamily}),
        currentUserText: text,
      );
      expect(selection.sourceOnly, true);
      expect(
        selection.definitions.map((d) => d.name).toSet(),
        SupportSourceToolNames.all,
      );
      expect(
        () => selection.requirePosted('astoria_theme_mode_set'),
        throwsA(isA<NativeToolException>()),
      );
    });
  }

  test(
    'ambiguous overflow without COMPLETE Source4 is unavailable, not take64',
    () {
      final selection = SupportNativeDefinitionSelection.capture(
        connected: _overflow(SupportSourceToolNames.body),
        currentUserText: 'Unrecognized task',
      );
      expect(selection.available, false);
      expect(selection.definitions, isEmpty);
    },
  );

  for (final omitted in [false, true]) {
    test(
      'native overflow ${omitted ? 'refuses unposted name before preparation' : 'posts complete theme family and executes actual adapter'}',
      () async {
        final store = AppControlMemoryTheme();
        final theme = ThemeNotifier(storage: store);
        final padding = _OverflowPadding();
        try {
          await automaticSourcesTest(
            (f) async {
              f.script = (round) {
                expect(round, lessThanOrEqualTo(omitted ? 1 : 2));
                return round == 1
                    ? AutomaticSourcesFixture.calls([
                        (
                          'overflow_call',
                          omitted
                              ? 'fixture_unused_0'
                              : 'astoria_theme_mode_set',
                          omitted ? <String, Object?>{} : {'mode': 'light'},
                        ),
                      ])
                    : AutomaticSourcesFixture.answer();
              };
              final send = await f.start(text: 'Set the theme to light');
              final result = await send.finished;
              expect(await send.accepted, true);
              final posted = (f.wire.first['tools'] as List)
                  .cast<Map<String, Object?>>();
              expect(
                posted.map((t) => (t['function'] as Map)['name']).toSet(),
                {...SupportSourceToolNames.all, ..._themeFamily},
              );
              final system =
                  ((f.wire.first['messages'] as List).first as Map)['content']
                      as String;
              expect(system, contains('not connected in THIS run'));
              expect(system, isNot(contains('fixture_unused_')));
              expect(padding.preparations, 0);
              expect(f.wire, hasLength(omitted ? 1 : 2));
              if (omitted) {
                expect(
                  result.outcome?.status,
                  isNot(PrivateTextStatus.complete),
                );
                expect(f.activity, isEmpty);
                expect(
                  store.presets
                      .singleWhere((p) => p.id == store.activeId)
                      .themeMode,
                  isNot('light'),
                );
              } else {
                expect(result.outcome?.status, PrivateTextStatus.complete);
                expect(
                  store.presets
                      .singleWhere((p) => p.id == store.activeId)
                      .themeMode,
                  'light',
                );
                expect(f.result('overflow_call')['effect'], 'persisted');
                expect(f.wire[1]['tools'], f.wire[0]['tools']);
              }
              expect(jsonEncode(f.wire), isNot(contains(BackupLoopNative.key)));
            },
            nativeAdapters: () async => [
              SupportAppThemeAdapter(theme: theme),
              padding,
            ],
          );
        } finally {
          await theme.flushPersistence();
          theme.dispose();
        }
      },
      skip: !Platform.isWindows,
    );
  }
  for (final broken in [true, false]) {
    test(
      '${broken ? 'broken native registry' : 'overflow without Source4'} refuses before wire instead of claiming text-only',
      () async {
        final f = await SupportProviderModelFixture.create();
        f.service.dispose();
        final native = f.native;
        final service = SupportModelService(
          db: f.db,
          writeCipher: f.cipher,
          apiRepo: f.apiRepo,
          revisions: f.revisions,
          redaction: f.redaction,
          runtime: f.runtime,
          adapterFactory: f.adapter,
          isOwnerCurrent: () => f.rootCurrent && native.isCurrent,
          writes: f.queue,
          nativeSources: native.sources,
          nativeMetadata: native.credentialReader,
          admissionContract: SupportTextAdmissionContract
              .auditedRootSingleConnectionNoBusyHandler,
          toolTransport: NativeToolTransport(
            credentials: native.credentials,
            authIssuer: native.auth,
            mutations: native.mutations,
            routes: native.routes,
            currentRedactor: () => f.redaction.redactor,
            adapterFactory: f.adapter,
          ),
          // Its presence is required by saved native-source preparation, but no
          // transport may be constructed after the actual registry fails.
          nativeDispatcher: (_) => throw StateError('Unexpected text fallback'),
          appActionsFactory: () {
            if (broken) throw StateError('SYNTHETIC_REGISTRY_CAUSE');
            return SupportAppActionRegistry(
              adapters: [_OverflowPadding()],
              metadata: SupportAppRedactedMetadataPolicy(
                currentRedactor: () => f.redaction.redactor,
              ),
              isOriginalOwnerCurrent: () => f.rootCurrent && native.isCurrent,
            );
          },
        );
        try {
          final emission = await service.emitInput(
            controller: f.controller,
            uiLifetime: f.uiLifetime,
            draftRevision: 1,
            text: 'Смени тему.',
            isEmitterCurrent: () => true,
            isDraftCurrent: () => true,
            directConversation: true,
            visibleConversation: const [],
          );
          expect(emission.intent, isNotNull);
          final submission = service.beginSend(emission.intent!);
          final result = await submission.finished;
          expect(await submission.accepted, true);
          expect(result.reason, SupportModelRefusal.toolsUnavailable);
          expect(result.reason.label, contains('Запрос не отправлен'));
          expect(
            result.reason.label,
            isNot(contains('SYNTHETIC_REGISTRY_CAUSE')),
          );
          expect(f.adapters, isEmpty);
        } finally {
          service.dispose();
          await f.close();
        }
      },
    );
  }
}
