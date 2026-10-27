import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
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
  final _dispatchAuthorizations = <String>[];
  List<String> get dispatchAuthorizations =>
      List.unmodifiable(_dispatchAuthorizations);
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
      call('astoria_sources_list', {'domain': domain}, id: id);
  Map<String, Object?> contents(String source, String id, {String? section}) =>
      call('astoria_source_contents', {
        'source': source,
        if (section != null) 'section': section,
      }, id: id);
  Map<String, Object?> search(
    String source,
    String literal,
    String id, {
    String? section,
    String? cursor,
  }) => call('astoria_source_search', {
    'source': source,
    'literal': literal,
    if (section != null) 'section': section,
    if (cursor != null) 'cursor': cursor,
  }, id: id);
  Map<String, Object?> read(
    String source,
    String selector,
    String id, {
    int before = 0,
    int after = 0,
  }) => call('astoria_source_read', {
    'source': source,
    'selector': selector,
    if (before != 0) 'before': before,
    if (after != 0) 'after': after,
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
      try {
        observerZone.run(() {
          // Observe the original options before NativeToolWire scrubs headers.
          // Keep only the immutable synthetic value, never the mutable map.
          final authorization =
              file.requests[absolute - 1].headers['Authorization'];
          expect(authorization, 'Bearer ${BackupLoopNative.key}');
          _dispatchAuthorizations.add(authorization as String);
        });
        final round = absolute - start;
        if (round < 1 || round > rounds) throw TestFailure('Extra source POST');
        if (round > 1) {
          if (next == null) throw TestFailure('Unscripted source POST');
          file.replies[absolute - 1] = await observerZone.run(
            () => next(round),
          );
        }
      } catch (error, trace) {
        _scriptFailure = error;
        _scriptTrace = trace;
        rethrow;
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

  String handle() {
    final entries = (lastData()['pieces'] as List)
        .cast<Map<dynamic, dynamic>>();
    return entries.single['source'] as String;
  }

  String activeStudioHandle() {
    final entries = (lastData()['pieces'] as List)
        .cast<Map<dynamic, dynamic>>();
    return entries.singleWhere((e) => e['activeAtListing'] == true)['source']
        as String;
  }

  Map<String, dynamic> body() => Map<String, dynamic>.from(
    jsonDecode(lastData()['sourceText'] as String) as Map,
  );

  String selector() => (body()['pieces'] as List).first['selector'] as String;

  Future<void> start(
    WidgetTester tester, {
    bool confirmation = true,
    String text =
        'Сравни последнюю игру «Отель Петербург» с текущим сохранённым Studio.',
  }) async {
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
    await tester.enterText(find.byType(TextField).first, text);
    // Empty -> draft schedules the real composer's availability rebuild. The
    // gesture must target its emitted enabled button, not the previous frame.
    await tester.pump();
    final send = find.byKey(const ValueKey('support_composer_send_btn'));
    expect(send.hitTestable(), findsOneWidget);
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    await backupLoopReal(tester, () => tester.tap(send));
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

  Future<void> modal(
    WidgetTester tester, {
    BackupLoopSignal<dynamic>? signal,
  }) => sourceLoopModal(tester, signal ?? file.settlement, loop: this);

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
  BackupLoopSignal<dynamic>? signal, {
  required SourceLoop loop,
}) async {
  final accept = find.byKey(const ValueKey('support_tool_confirmation_accept'));
  final picker = find.byKey(const ValueKey('support_source_target_0'));
  bool mounted() {
    loop.checkScript();
    final ready = accept.evaluate().isNotEmpty || picker.evaluate().isNotEmpty;
    if (signal?.done == true && !ready) {
      throw TestFailure(
        'Source settled before confirmation: '
        '${loop.file.bridge.view.reason}/${loop.file.bridge.view.transportReason}; '
        'POSTs=${loop.file.wire.length}; '
        '${loop.activityDiagnostic}',
      );
    }
    return ready;
  }

  await backupLoopUntil(tester, mounted, signal: signal);
  while (picker.evaluate().isNotEmpty) {
    await sourceLoopChooseTarget(tester);
    await backupLoopUntil(tester, mounted, signal: signal);
  }
  await sourceLoopReadyRoute(tester, accept);
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

/// Retain and finish the ORIGINAL forward transition before a native decision.
Future<ModalRoute<void>> sourceLoopReadyRoute(
  WidgetTester tester,
  Finder control,
) async {
  final route = ModalRoute.of<void>(tester.element(control))!;
  await tester.pump();
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.isCurrent, isTrue);
  expect(route.animation!.status, AnimationStatus.completed);
  expect(control.hitTestable(), findsOneWidget);
  return route;
}

/// Join the same route's real disposal, never a substitute completion signal.
Future<void> sourceLoopRouteClosed(
  WidgetTester tester,
  ModalRoute<void> route,
) async {
  final closed = BackupLoopSignal(route.completed);
  await tester.pump();
  await tester.pump(route.reverseTransitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  await backupLoopUntil(tester, () => closed.done, signal: closed);
  await backupLoopReal(tester, () => route.completed);
  expect(route.isActive, isFalse);
}

/// An actual local selection gesture, not model title matching or a grant.
Future<void> sourceLoopChooseTarget(WidgetTester tester) async {
  final first = find.byKey(const ValueKey('support_source_target_0'));
  final route = await sourceLoopReadyRoute(tester, first);
  final candidates = find.byWidgetPredicate(
    (w) =>
        w is GlazeActionButton &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('support_source_target_'),
  );
  final chosen = candidates.evaluate().singleWhere((e) {
    final label = (e.widget as GlazeActionButton).label;
    return label.contains('Сессия 2 ·') || label.contains('Выбран сейчас ·');
  });
  final button = find.byWidget(chosen.widget);
  await tester.ensureVisible(button);
  await tester.pump();
  expect(button.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(button));
  await sourceLoopRouteClosed(tester, route);
}

Future<void> sourceLoopDecision(WidgetTester tester, String decision) async {
  final button = find.byKey(ValueKey('support_tool_confirmation_$decision'));
  final route = await sourceLoopReadyRoute(tester, button);
  await backupLoopReal(tester, () => tester.tap(button));
  await sourceLoopRouteClosed(tester, route);
}

Future<void> seedModelSources(
  WidgetTester tester,
  BackupLoopFixture f, {
  String? studioJson,
  String? gameJson,
  int messages = 20,
  bool prepareHistory = true,
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
  if (prepareHistory) {
    final prepared = await db.historySourceIndex.maintain(
      sessionId: sourceSession,
      isCurrent: () => true,
    );
    expect(prepared.state, HistoryIndexMaintenanceState.ready);
  }
  await f.container.read(supportWorkspaceProvider.notifier).refresh();
  await f.container.pump();
  // Synthetic seeding legitimately decrypts its own putMessage return values.
  // Observe subsequent model runs, not those declared setup operations.
  f.native.primitive.decryptAads.clear();
});

/// Small actual saved rows for independent FILE/provider MODEL runs. These are
/// setup writers only: model tools continue through the production native repo.
Future<void> seedSavedModelDomains(
  WidgetTester tester,
  BackupLoopFixture f,
) => backupLoopReal(tester, () async {
  final db = f.native.db;
  await db.customStatement('DELETE FROM presets WHERE preset_id <> ?', [
    sourceStudio,
  ]);
  await db.customStatement(
    'DELETE FROM studio_preset_rows WHERE preset_id <> ?',
    [sourceStudio],
  );
  await db.customStatement(
    'UPDATE presets SET name = ?, data_json = ? WHERE preset_id = ?',
    [
      'LOCAL_ORDINARY_AUTHORED_TITLE',
      jsonEncode({
        'id': sourceStudio,
        'name': 'LOCAL_ORDINARY_AUTHORED_TITLE',
        'imagePath': BackupLoopNative.private,
        'blocks': [
          {
            'id': 'private-ordinary-block',
            'name': 'Block',
            'role': 'system',
            'content': 'MODEL_NINE_ordinaryPreset_BODY ${BackupLoopNative.key}',
            'enabled': true,
          },
        ],
        'regexes': <Object?>[],
        'summaryPrompt': 'MODEL_NINE_ordinaryPreset_TEMPLATE',
      }),
      sourceStudio,
    ],
  );
  await db.customStatement(
    'UPDATE studio_preset_rows SET expensive_api_config_id = ?, cheap_api_config_id = ? WHERE preset_id = ?',
    ['private-studio-expensive', 'private-studio-cheap', sourceStudio],
  );
  await db.customStatement(
    'INSERT INTO memory_book_rows(session_id,entries_json,pending_drafts_json,settings_json) VALUES(?,?,?,?)',
    [
      sourceSession,
      jsonEncode([
        {
          'id': 'private-memory-entry',
          'title': 'Entry',
          'content': 'MODEL_NINE_memory_BODY',
          'status': 'active',
          'activeRevisionId': 'private-revision',
          'revisions': [
            {
              'id': 'private-revision',
              'version': 1,
              'content': 'MODEL_NINE_memory_REVISION',
              'createdAt': 1,
            },
          ],
          'sourceManifest': {
            'version': 0,
            'originSessionId': '',
            'messages': <Object?>[],
            'invalidated': true,
          },
        },
      ]),
      jsonEncode([
        {
          'id': 'private-draft',
          'content': 'MODEL_NINE_memory_DRAFT',
          'status': 'pending_approval',
        },
      ]),
      '{}',
    ],
  );
  await db.customStatement(
    'INSERT INTO memory_catalog_rows(id,chat_session_id,memory_entry_id,abstract_text) VALUES(?,?,?,?)',
    [
      'private-catalog',
      sourceSession,
      'private-memory-entry',
      'MODEL_NINE_memory_DERIVED',
    ],
  );
  await db.customStatement(
    'INSERT INTO chat_summaries(session_id,content,message_count,prompt) VALUES(?,?,?,?)',
    [
      sourceSession,
      'MODEL_NINE_savedSummary_BODY',
      4,
      'MODEL_NINE_savedSummary_TEMPLATE',
    ],
  );
  await db.customStatement(
    'INSERT INTO tracker_rows(session_id,name,value,scope,provenance) VALUES(?,?,?,?,?)',
    [
      sourceSession,
      'scene.location',
      'MODEL_NINE_ledgerState_BODY',
      'ledger',
      'saved',
    ],
  );
  await db.customStatement(
    'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
    [
      sourceSession,
      'diagnostic',
      'MODEL_NINE_EXCLUDED_DIAGNOSTIC',
      'diagnostic',
    ],
  );
  final snapshot = [
    {
      'sessionId': sourceSession,
      'name': 'scene.location',
      'value': 'MODEL_NINE_ledgerSnapshot_BODY',
      'scope': 'ledger',
      'provenance': 'saved',
    },
  ];
  await db.customStatement(
    'INSERT INTO tracker_snapshots(session_id,message_id,swipe_id,agent_swipe_id,trackers_json,committed) VALUES(?,?,?,?,?,?)',
    [sourceSession, 'model-source-2', 0, 0, jsonEncode(snapshot), 1],
  );
  await db.customStatement(
    'INSERT INTO ledger_reconciliation_checkpoints(session_id,start_message_id,end_message_id,end_swipe_id,end_agent_swipe_id,message_ids_json,range_hash) VALUES(?,?,?,?,?,?,?)',
    [
      sourceSession,
      'model-source-1',
      'model-source-2',
      0,
      0,
      jsonEncode(['model-source-1', 'model-source-2']),
      'private-checkpoint-range',
    ],
  );
  final run = LedgerReconciliationRun(
    id: 'private-saved-run',
    sessionId: sourceSession,
    ordinal: 1,
    anchors: const [
      ReconciliationAnchor(
        messageId: 'model-source-2',
        swipeId: 0,
        agentSwipeId: 0,
        role: 'assistant',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    ],
    acceptedManifestRefs: const [],
    effectiveCanonStamp: 'private-canon',
    effectiveCanonRevision: 0,
    effectiveCanonHash:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    canonicalResult: {
      'cleanupOps': <Object?>[],
      'export': {
        'ops': [
          {
            'op': 'set',
            'key': 'scene.location',
            'value': 'MODEL_NINE_reconciliation_BODY',
            'evidence': 'saved range',
            'eventState': '',
          },
        ],
        'sceneState': null,
        'entities': <Object?>[],
        'arcState': <Object?>[],
        'knowledgeFacts': <Object?>[],
      },
    },
    predecessorChainHash: '',
    contractVersion: 1,
    opsApplied: const ['tracker:set:scene.location'],
    createdAt: 1,
  );
  await db
      .into(db.ledgerReconciliationSuccessfulRuns)
      .insert(
        LedgerReconciliationSuccessfulRunsCompanion.insert(
          id: run.id,
          sessionId: run.sessionId,
          ordinal: run.ordinal,
          startMessageId: run.start.messageId,
          startSwipeId: run.start.swipeId,
          startAgentSwipeId: run.start.agentSwipeId,
          endMessageId: run.end.messageId,
          endSwipeId: run.end.swipeId,
          endAgentSwipeId: run.end.agentSwipeId,
          anchorsJson: run.anchorsJson,
          rangeHash: run.rangeHash,
          acceptedManifestRefsJson: run.manifestsJson,
          effectiveCanonStamp: run.effectiveCanonStamp,
          effectiveCanonRevision: run.effectiveCanonRevision,
          effectiveCanonHash: run.effectiveCanonHash,
          canonicalResultJson: run.resultJson,
          contentHash: run.contentHash,
          predecessorChainHash: run.predecessorChainHash,
          chainHash: run.chainHash,
          contractVersion: run.contractVersion,
          opsAppliedJson: run.opsJson,
          createdAt: run.createdAt,
        ),
      );
  Object? canonical(Object? value) {
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  await LedgerReconciliationRunRepo(db).recordEffect(
    runId: run.id,
    sessionId: sourceSession,
    before: ReconciliationStateSnapshot(ledgerJson: '[]', knowledgeJson: '[]'),
    after: ReconciliationStateSnapshot(
      ledgerJson: jsonEncode(
        canonical([
          {
            'sessionId': sourceSession,
            'name': 'scene.location',
            'value': 'MODEL_NINE_reconciliation_EFFECT',
            'scope': 'ledger',
            'provenance': 'saved',
            'basisRevision': 0,
            'basisRevisionHash': '',
            'updatedAt': 1,
          },
        ]),
      ),
      knowledgeJson: '[]',
    ),
    createdAt: 1,
  );
  await db.customStatement(
    '''INSERT INTO character_knowledge_fact_rows(
    id,chat_session_id,knower_key,subject_key,fact_class,predicate,object,epistemic_state,
    confidence,importance,source_message_id,source_swipe_id,source_agent_swipe_id,lifecycle)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
    [
      'private-knowledge',
      sourceSession,
      'private-knower',
      'private-subject',
      'knowledge',
      'knows',
      'MODEL_NINE_characterKnowledge_BODY',
      'confirmed',
      0.7,
      0.5,
      'model-source-2',
      0,
      0,
      'active',
    ],
  );
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
