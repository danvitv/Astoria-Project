import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_ui_bridge.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_tool_native_ui.dart';

import 'support_app_backup_loop_fixture.dart';

export 'support_app_backup_loop_fixture.dart';

// These matchers also run in native wire callbacks while a widget pump awaits.
// Flutter's official synchronous matcher preserves assertions without entering
// a second guarded widget-test operation.
final expect = expectSync;

const sourceCharacter = 'source-hotel-petersburg';
const sourceSession = 'source-hotel-latest';
const sourceOlderSession = 'source-hotel-older';
const sourceStudio = 'source-comparison-studio';
const sourceGameBody = 'MODEL_APPROVED_GAME_BODY_';
const sourceStudioBody = 'MODEL_APPROVED_STUDIO_BODY_';
const sourceExcluded = 'MODEL_SOURCE_EXCLUDED_HIDDEN_BODY';
const sourceOlderBody = 'MODEL_SOURCE_EXCLUDED_OLDER_SESSION';
const sourceInactiveStudioBody = 'MODEL_SOURCE_EXCLUDED_INACTIVE_STUDIO';

/// Only scripting/settlement around the existing FILE-owner native UI fixture.
/// No replacement service/provider, read authority, SQL interceptor or IO policy.
final class SourceLoop {
  SourceLoop(this.file);
  final BackupLoopFixture file;
  Set<String> _previous = const {};
  Object? _scriptFailure;
  StackTrace? _scriptTrace;
  final _activityTrail = <String>[];
  void Function()? _stopActivity;

  String get activityDiagnostic =>
      'Original source milestones: ${_activityTrail.join('; ')}';

  void checkScript() {
    if (_scriptFailure != null) {
      debugPrint(activityDiagnostic, wrapWidth: 160);
      Error.throwWithStackTrace(_scriptFailure!, _scriptTrace!);
    }
  }

  static Map<String, Object?> call(
    String name,
    Map<String, Object?> arguments, {
    required String id,
  }) => {
    'choices': [
      {
        'index': 0,
        'finish_reason': 'tool_calls',
        'message': {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'type': 'function',
              'id': id,
              'function': {'name': name, 'arguments': jsonEncode(arguments)},
            },
          ],
        },
      },
    ],
  };

  static Map<String, Object?> answer(String text) => {
    'choices': [
      {
        'index': 0,
        'finish_reason': 'stop',
        'message': {'role': 'assistant', 'content': text},
      },
    ],
  };

  Map<String, Object?> list(String domain, String id) =>
      call('astoria_sources_list', {'domain': domain, 'offset': 0}, id: id);
  Map<String, Object?> read(
    String handle,
    String id, {
    int offset = 0,
    int? studioPage,
  }) => call('astoria_source_read', {
    'opaqueHandle': handle,
    'activeMessageOffset': offset,
    if (studioPage != null) 'studioPage': studioPage,
  }, id: id);

  /// BackupLoopWire checks the declared finite reply budget BEFORE onFetch.
  /// Fill only these slots; an extra POST fails rather than inventing an answer.
  void script(
    Map<String, Object?> first, {
    required int rounds,
    FutureOr<Map<String, Object?>> Function(int)? next,
  }) {
    final start = file.wire.length;
    // Native POST is handed off from the original read-only ROOT. Its adapter
    // future inherits that transaction zone after ROOT has closed. Synthetic
    // observation/mutation callbacks must use the retained test owner zone, not
    // try to issue SQL through an already-closed transaction executor.
    final observerZone = Zone.current;
    file.replies
      ..removeRange(start, file.replies.length)
      ..addAll(List.generate(rounds, (_) => first));
    file.onFetch = (absolute) async {
      final round = absolute - start;
      if (round < 1 || round > rounds) throw TestFailure('Extra source POST');
      if (round > 1) {
        if (next == null) throw TestFailure('Unscripted source POST');
        try {
          file.replies[absolute - 1] = await observerZone.run(
            () => next(round),
          );
        } catch (error, trace) {
          _scriptFailure = error;
          _scriptTrace = trace;
          rethrow;
        }
      }
    };
  }

  Map<String, dynamic> lastResult() {
    final messages = file.wire.last['messages'] as List;
    final tool = messages.cast<Map<dynamic, dynamic>>().lastWhere(
      (m) => m['role'] == 'tool',
    );
    return Map<String, dynamic>.from(
      jsonDecode(tool['content'] as String) as Map,
    );
  }

  Map<String, dynamic> lastData() {
    final result = lastResult();
    expect(
      result['ok'],
      isTrue,
      reason: 'Native source result: ${result['code']}',
    );
    return Map<String, dynamic>.from(result['data'] as Map);
  }

  String handle(String label, {int? sessionIndex}) {
    final entries = (lastData()['entries'] as List)
        .cast<Map<dynamic, dynamic>>();
    return entries.singleWhere(
          (e) =>
              e['label'] == label &&
              (sessionIndex == null || e['sessionIndex'] == sessionIndex),
        )['opaqueHandle']
        as String;
  }

  String activeStudioHandle() {
    final entries = (lastData()['entries'] as List)
        .cast<Map<dynamic, dynamic>>();
    return entries.singleWhere(
          (e) => e['activeAtListing'] == true,
        )['opaqueHandle']
        as String;
  }

  Future<void> start(WidgetTester tester, {bool confirmation = true}) async {
    _stopActivity?.call();
    _activityTrail.clear();
    _stopActivity = file.bridge.listen(() {
      final activities = file.bridge.view.toolActivities;
      if (activities.isEmpty || _activityTrail.length >= 512) return;
      final activity = activities.last;
      // Original activity only. Never retain authored labels, IDs, arguments,
      // bodies, native captures or exceptions for diagnostics.
      final milestone =
          '${activity.sequence}/${activity.action}/${activity.stage.name}: ${activity.detail}';
      if (_activityTrail.isEmpty || _activityTrail.last != milestone) {
        _activityTrail.add(milestone);
      }
    });
    await backupLoopReal(tester, () async {
      final old = await file.native.repo.getMessagesForSession(
        file.native.session,
      );
      _previous = old.map((m) => m.id).toSet();
      file.settlement = BackupLoopSignal(
        file.native.repo
            .watchMessagesForSession(file.native.session)
            .firstWhere(
              (rows) => rows.any(
                (m) =>
                    !_previous.contains(m.id) &&
                    m.role == 'assistant' &&
                    m.runId != null &&
                    const {
                      'complete',
                      'stopped',
                      'error',
                      'limited',
                    }.contains(m.status),
              ),
            ),
      );
    });
    await tester.enterText(
      find.byType(TextField).first,
      'Сравни последнюю игру «Отель Петербург» с текущим сохранённым Studio.',
    );
    await backupLoopReal(
      tester,
      () => tester.tap(find.byKey(const ValueKey('support_composer_send_btn'))),
    );
    if (confirmation) await modal(tester);
  }

  Future<SupportMessage> finish(WidgetTester tester) async {
    try {
      final signal = file.settlement!;
      await backupLoopUntil(tester, () => signal.done, signal: signal);
      await backupLoopReal(tester, () => signal.settled);
      await idle(tester);
      checkScript();
      return signal.value.singleWhere(
        (m) =>
            !_previous.contains(m.id) &&
            m.role == 'assistant' &&
            m.runId != null,
      );
    } finally {
      _stopActivity?.call();
      _stopActivity = null;
    }
  }

  Future<T> join<T>(WidgetTester tester, BackupLoopSignal<T> signal) async {
    await backupLoopUntil(tester, () => signal.done, signal: signal);
    await backupLoopReal(tester, () => signal.settled);
    await idle(tester);
    checkScript();
    return signal.value;
  }

  Future<void> idle(WidgetTester tester) async {
    await backupLoopUntil(
      tester,
      () => !file.container.read(supportModelWorkspaceBindingProvider).busy,
    );
    expect(file.native.redaction.redactor, same(file.native.stableRedactor));
    await tester.pump();
  }

  Future<void> modal(WidgetTester tester) async {
    final accept = find.byKey(
      const ValueKey('support_tool_confirmation_accept'),
    );
    await backupLoopUntil(tester, () {
      checkScript();
      if (file.settlement?.done == true && accept.evaluate().isEmpty) {
        throw TestFailure(
          'Source settled before confirmation: '
          '${file.bridge.view.reason}/${file.bridge.view.transportReason}; '
          'POSTs=${file.wire.length}; '
          '$activityDiagnostic',
        );
      }
      return accept.evaluate().isNotEmpty;
    }, signal: file.settlement);
    await sourceLoopModal(tester, file.settlement);
  }

  Future<void> apply(WidgetTester tester) =>
      sourceLoopDecision(tester, 'accept');
  Future<void> cancel(WidgetTester tester) =>
      sourceLoopDecision(tester, 'cancel');

  SupportModelToolNativeUi nativeUi(WidgetTester tester) {
    final context = tester.element(find.byType(SupportAssistantScreen));
    return SupportModelToolNativeUi(
      context: context,
      isOriginalUiCurrent: () =>
          context.mounted &&
          file.router.routeInformationProvider.value.uri.path == '/support',
    );
  }

  SupportModelUiEmitter emitter(
    WidgetTester tester, {
    SupportModelToolNativeUi? ui,
    List<SupportModelConversationMessage> visible = const [],
  }) {
    final context = tester.element(find.byType(SupportAssistantScreen));
    return file.bridge.bindEmitter(
      controller: file.container.read(supportNativeConsentControllerProvider),
      uiLifetime: context,
      isEmitterCurrent: () => context.mounted && (ui?.isCurrent ?? true),
      visibleConversation: visible,
      toolUi: ui?.ports,
    );
  }

  void noBody() {
    for (final body in [
      sourceGameBody,
      sourceStudioBody,
      sourceExcluded,
      sourceOlderBody,
      sourceInactiveStudioBody,
    ]) {
      expect(jsonEncode(file.wire), isNot(contains(body)));
    }
    sourceNoEgress(file);
  }
}

void sourceNoEgress(BackupLoopFixture file, [String text = '']) {
  final outward = '${jsonEncode(file.wire)}$text';
  for (final canary in [
    file.native.sourcePath,
    file.native.destinationPath,
    BackupLoopNative.private,
    BackupLoopNative.rowSecret,
    BackupLoopNative.key,
    'summary_ciphertext',
    'before_ciphertext',
    'backup_loop_extra',
  ]) {
    expectSync(outward, isNot(contains(canary)));
  }
}

Future<void> sourceLoopModal(
  WidgetTester tester,
  BackupLoopSignal<dynamic>? signal,
) async {
  final accept = find.byKey(const ValueKey('support_tool_confirmation_accept'));
  await backupLoopUntil(
    tester,
    () => accept.evaluate().isNotEmpty,
    signal: signal,
  );
  final route = ModalRoute.of<void>(tester.element(accept))!;
  await tester.pump();
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.isCurrent, isTrue);
  expect(route.animation!.status, AnimationStatus.completed);
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  for (final decision in ['accept', 'cancel']) {
    final button = find.byKey(ValueKey('support_tool_confirmation_$decision'));
    expect(button.hitTestable(), findsOneWidget);
    final rect = tester.getRect(button);
    expect(viewport.contains(rect.topLeft), isTrue);
    expect(viewport.contains(rect.bottomRight), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('support_tool_confirmation_preview')),
        matching: button,
      ),
      findsNothing,
    );
  }
}

Future<void> sourceLoopDecision(WidgetTester tester, String decision) async {
  final button = find.byKey(ValueKey('support_tool_confirmation_$decision'));
  expect(button.hitTestable(), findsOneWidget);
  final route = ModalRoute.of<void>(tester.element(button))!;
  await backupLoopReal(tester, () => tester.tap(button));
  await tester.pump();
  await tester.pump(route.reverseTransitionDuration);
  await tester.pump(const Duration(microseconds: 1));
}

Future<void> seedModelSources(
  WidgetTester tester,
  BackupLoopFixture f, {
  String? studioJson,
  String? gameJson,
  int messages = 20,
}) => backupLoopReal(tester, () async {
  final db = f.native.db;
  f.isolation.extraAllowed.add(activeStudioPresetProvider);
  await f.container.read(activeStudioPresetProvider.notifier).set(sourceStudio);
  await db
      .into(db.characters)
      .insert(
        const CharactersCompanion(
          charId: Value(sourceCharacter),
          name: Value('Отель Петербург'),
          // Deliberately NOT the latest activity: source listing orders sessions.
          currentSessionIndex: Value(0),
          variantGroupId: Value(sourceCharacter),
        ),
      );
  for (final latest in [false, true]) {
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion(
            sessionId: Value(latest ? sourceSession : sourceOlderSession),
            characterId: const Value(sourceCharacter),
            sessionIndex: Value(latest ? 1 : 0),
            updatedAt: Value(latest ? 100 : 10),
            messagesJson: Value(
              latest
                  ? gameJson ??
                        jsonEncode([
                          for (var i = 0; i < messages; i++)
                            {
                              'id': 'model-source-$i',
                              'role': i.isEven ? 'user' : 'assistant',
                              'content':
                                  '$sourceGameBody$i ${List.filled(300, 'g').join()}',
                              'timestamp': i + 1,
                            },
                          {
                            'id': 'model-source-hidden',
                            'role': 'assistant',
                            'content': sourceExcluded,
                            'isHidden': true,
                          },
                        ])
                  : jsonEncode([
                      {
                        'id': 'model-older-source',
                        'role': 'assistant',
                        'content': sourceOlderBody,
                      },
                    ]),
            ),
          ),
        );
  }
  await db
      .into(db.studioPresetRows)
      .insert(
        StudioPresetRowsCompanion(
          presetId: const Value(sourceStudio),
          name: const Value('Comparison Studio'),
          blocksJson: Value(
            studioJson ??
                jsonEncode([
                  {
                    'id': 'model-instruction',
                    'type': 'instruction',
                    'locked': false,
                    'role': 'system',
                    'section': '',
                    'mode': 'direct',
                    'injectionPoint': 'final',
                    'content':
                        '$sourceStudioBody${List.filled(300, 's').join()}',
                  },
                ]),
          ),
          agentsJson: const Value('[]'),
          agentEnabledJson: const Value('{}'),
          runtimeSettingsJson: const Value(
            '{"version":1,"broadcastBlocks":[]}',
          ),
          updatedAt: const Value(100),
        ),
      );
  await db
      .into(db.studioPresetRows)
      .insert(
        StudioPresetRowsCompanion(
          presetId: const Value('source-inactive-studio'),
          name: const Value('Newer inactive Studio'),
          blocksJson: Value(
            jsonEncode([
              {
                'id': 'inactive',
                'type': 'instruction',
                'content': sourceInactiveStudioBody,
              },
            ]),
          ),
          updatedAt: const Value(1000),
        ),
      );
  // Same ID in the unrelated ordinary-preset domain must never be substituted.
  await db
      .into(db.presets)
      .insert(
        const PresetsCompanion(
          presetId: Value(sourceStudio),
          name: Value('Comparison Studio'),
          dataJson: Value('{"content":"MODEL_SOURCE_EXCLUDED_HIDDEN_BODY"}'),
        ),
      );
  for (final assistant in [false, true]) {
    await f.native.repo.putMessage(
      SupportMessage(
        id: assistant ? 'old-native-assistant' : 'old-native-user',
        sessionId: f.native.session,
        role: assistant ? 'assistant' : 'user',
        body: assistant
            ? 'Earlier own-chat answer.'
            : 'Earlier own-chat question.',
        createdAt: assistant ? 2 : 1,
      ),
    );
  }
  await f.container.read(supportWorkspaceProvider.notifier).refresh();
  await f.container.pump();
  // Synthetic seeding legitimately decrypts its own putMessage return values.
  // Observe subsequent model runs, not those declared setup operations.
  f.native.primitive.decryptAads.clear();
});

/// Read REAL encrypted persisted provenance. Call from onFetch directly, or
/// wrap with backupLoopReal in the fake-async widget test body.
Future<SupportModelProvenance> modelSourceRecipe(
  BackupLoopFixture f,
  String reply,
) async {
  final id = 'support.reply_provenance:$reply';
  final db = f.native.db;
  final stored = await (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(id))).getSingle();
  final block = (await f.native.repo.getContextBlockById(id))!;
  expect(stored.protectedFactsCiphertext, isNot(block.protectedFactsJson));
  final parsed = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
    block.protectedFactsJson,
  );
  expect(parsed.isValid, isTrue);
  expect(jsonDecode(block.protectedFactsJson)['version'], 4);
  for (final body in [
    sourceGameBody,
    sourceStudioBody,
    sourceExcluded,
    sourceOlderBody,
  ]) {
    expect(block.protectedFactsJson, isNot(contains(body)));
    expect(stored.protectedFactsCiphertext, isNot(contains(body)));
  }
  return parsed.recipe!;
}
