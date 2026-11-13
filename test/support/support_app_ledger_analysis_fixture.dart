import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_provenance.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_export_parser.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_prompt.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/ledger_preset_instruction_defaults.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_debug_run_repo.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'support_app_domain_loop_fixture.dart';

export 'support_app_domain_loop_fixture.dart';

const analysisPrivate = 'SYNTHETIC_LEDGER_ANALYSIS_PRIVATE';
const analysisMessage = 'analysis-selected-message';
const analysisPipeline = 'ledger:$analysisMessage:0:0';
const analysisClock = '10:27';
const analysisDate = '17.03.2042';

enum AnalysisSeed {
  omitted,
  same,
  rejected,
  changed,
  noOps,
  noDebug,
  noCapture,
  noSnapshot,
  truncated,
  duplicateCall,
  repair,
  newerAttempt,
  newerUser,
  ambiguousBaseline,
}

enum AnalysisSelectedShape {
  validBlue,
  missingAgentContent,
  nullAgentContent,
  missingMetaIndex,
  nullMetaIndex,
  nullGreen,
  nonTextAgentContent,
}

/// Retain the complete original positive exchange/snapshot. Only selected chat
/// shape changes; malformed leaves are written as exact synthetic JSON so the
/// typed ChatMessage decoder cannot normalize missing/null fields to defaults.
Future<void> seedLedgerSelectedShape(
  DomainLoopFixture f,
  AnalysisSelectedShape shape,
) async {
  await seedLedgerAnalysis(f, AnalysisSeed.same);
  final c = f.screen.core.container;
  if (shape != AnalysisSelectedShape.nullGreen) {
    const agent = AgentSwipe(
      content: analysisPrivate,
      kind: 'final',
      parentSwipeId: 0,
    );
    final updated = await c
        .read(chatRepoProvider)
        .mutateMessage(
          sessionId: DomainLoopFixture.session,
          messageId: analysisMessage,
          updatedAt: 20,
          mutate: (message) => message.copyWith(
            agentSwipes: const [agent],
            agentSwipeId: 0,
            swipesMeta: [
              {
                'agentSwipes': [agent.toJson()],
                'agentSwipeId': 0,
              },
            ],
          ),
        );
    expect(updated, isNotNull);
  }
  if (shape == AnalysisSelectedShape.validBlue) return;
  final db = f.screen.core.native.db;
  final row = await (db.select(
    db.chatSessions,
  )..where((r) => r.sessionId.equals(DomainLoopFixture.session))).getSingle();
  final messages = jsonDecode(row.messagesJson) as List;
  final head = messages.last as Map<String, dynamic>;
  expect(head['id'], analysisMessage);
  expect(head['content'], analysisPrivate);
  if (shape == AnalysisSelectedShape.nullGreen) {
    expect(head['agentSwipes'], isEmpty);
    (head['swipes'] as List)[0] = null;
  } else {
    final agent = (head['agentSwipes'] as List).single as Map<String, dynamic>;
    final meta = (head['swipesMeta'] as List).single as Map<String, dynamic>;
    final metaAgent =
        (meta['agentSwipes'] as List).single as Map<String, dynamic>;
    switch (shape) {
      case AnalysisSelectedShape.missingAgentContent:
        agent.remove('content');
        metaAgent.remove('content');
      case AnalysisSelectedShape.nullAgentContent:
        agent['content'] = null;
        metaAgent['content'] = null;
      case AnalysisSelectedShape.missingMetaIndex:
        meta.remove('agentSwipeId');
      case AnalysisSelectedShape.nullMetaIndex:
        meta['agentSwipeId'] = null;
      case AnalysisSelectedShape.nonTextAgentContent:
        agent['content'] = 7;
        metaAgent['content'] = 7;
      case AnalysisSelectedShape.validBlue:
      case AnalysisSelectedShape.nullGreen:
        throw StateError('Unexpected selected-shape corruption branch');
    }
  }
  final damaged = jsonEncode(messages);
  expect(
    await (db.update(db.chatSessions)
          ..where((r) => r.sessionId.equals(DomainLoopFixture.session)))
        .write(ChatSessionsCompanion(messagesJson: Value(damaged))),
    1,
  );
}

Future<void> seedLedgerAnalysis(DomainLoopFixture f, AnalysisSeed mode) async {
  final c = f.screen.core.container;
  // The imported fixture already builds/registers the REAL loaded ChatNotifier.
  // Only this new diagnostic repo extends its finite, pre-evaluation graph.
  f.screen.core.isolation.extraAllowed.add(ledgerDebugRunRepoProvider);
  final time = mode == AnalysisSeed.changed
      ? '10:37'
      : mode == AnalysisSeed.rejected
      ? '09:20'
      : analysisClock;
  final clockOp = <String, Object?>{
    'op': 'set',
    'key': 'world:time',
    'value': time,
    'evidence': analysisPrivate,
    'eventState': 'completed',
  };
  final ops = <Map<String, Object?>>[
    if (mode != AnalysisSeed.omitted && mode != AnalysisSeed.noOps) clockOp,
    if (mode != AnalysisSeed.noOps)
      {
        'op': 'set',
        'key': 'world:location',
        'value': analysisPrivate,
        'evidence': analysisPrivate,
        'eventState': 'completed',
      },
  ];
  final response =
      '<glaze_memory_export>\n${jsonEncode({'ops': ops, 'knowledgeFacts': <Object?>[]})}\n</glaze_memory_export>\n<studio_ledger>$analysisPrivate</studio_ledger>';
  final baseline = [
    for (final entry in {
      'world:time': analysisClock,
      'world:date': analysisDate,
      'world:day': '11',
      'world:location': analysisPrivate,
    }.entries)
      Tracker(
        sessionId: DomainLoopFixture.session,
        name: entry.key,
        value: entry.value,
        scope: 'ledger',
      ),
  ];
  var prompt = const StudioLedgerPrompt().build(
    systemPrompt:
        '$ledgerDefaultTurnInstructions\n\n$ledgerDefaultSharedInstructions',
    finalAssistantText: analysisPrivate,
    currentUserText: analysisPrivate,
    recentHistoryText: analysisPrivate,
    currentTrackers: baseline,
    recentMemoryEntries: const [],
  );
  expect(prompt, contains(ledgerDefaultClockInstructions));
  if (mode == AnalysisSeed.ambiguousBaseline) {
    prompt = prompt.replaceFirst(
      '\n<current_state>\n',
      '\n<current_state>\nworld:time: $analysisClock\n',
    );
  }
  final parsed = const StudioLedgerExportParser().parse(
    response,
    clockPolicy: const LedgerClockPolicy.turn(
      current: GameTimeState(time: analysisClock, date: analysisDate, day: 11),
    ),
  );
  final attempt = AgentOperationAttempt(
    attempt: 1,
    statusCode: 200,
    status: 'ok',
    startedAtMs: 1000,
    elapsedMs: 23,
  );
  const context = LlmCaptureContext(
    stage: 'ledger.turn',
    sessionId: DomainLoopFixture.session,
    messageId: analysisMessage,
    pipelineRunId: analysisPipeline,
    logicalCallId: analysisPipeline,
    relatedArtifactId: analysisMessage,
    callId: 'analysis-call',
    attempt: 1,
  );
  final capture = c.read(llmRequestCaptureRepoProvider);
  Future<void> request(LlmCaptureContext original, {bool truncated = false}) =>
      capture.record(
        LlmRequestCaptureEvent(
          sequence: original.attempt!,
          createdAt: DateTime.utc(2042, 3, 17),
          protocol: 'openai',
          context: original,
          request: {
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'messageCount': 1,
            'model': analysisPrivate,
            'protocolEndpoint': 'https://synthetic.invalid/$analysisPrivate',
          },
          truncated: truncated,
        ),
      );
  if (mode != AnalysisSeed.noCapture) {
    await request(context, truncated: mode == AnalysisSeed.truncated);
  }
  await capture.recordCallEvent(
    LlmCallEvent.transport(
      context: context,
      attempt: attempt,
      responseText: response,
    ),
  );
  await capture.recordCallEvent(
    LlmCallEvent.parserVerdict(
      context: context,
      parserName: 'StudioLedgerExportParser',
      accepted: parsed.export != null && !parsed.wasRejected,
      code: parsed.failure.name,
      detail: parsed.rejectionReason,
      payload: {
        'rejectedOps': parsed.rejectedOps,
        'hasExport': parsed.hasExport,
      },
    ),
  );
  if (mode == AnalysisSeed.duplicateCall) {
    await request(
      context.withCallIdentity(
        pipelineRunId: analysisPipeline,
        callId: 'analysis-second-call',
      ),
    );
  }
  if (mode == AnalysisSeed.newerAttempt) await request(context.withAttempt(2));
  if (mode == AnalysisSeed.repair) {
    await request(
      const LlmCaptureContext(
        stage: 'ledger.turn_repair',
        sessionId: DomainLoopFixture.session,
        messageId: analysisMessage,
        pipelineRunId: analysisPipeline,
        logicalCallId: '$analysisPipeline:repair',
        callId: 'analysis-repair-call',
        relatedArtifactId: analysisMessage,
        attempt: 1,
      ),
    );
  }
  if (mode != AnalysisSeed.noDebug) {
    await c
        .read(ledgerDebugRunRepoProvider)
        .record(
          LedgerDebugRun(
            sessionId: DomainLoopFixture.session,
            kind: LedgerDebugRunKind.normal,
            messageId: analysisMessage,
            status: parsed.hasExport ? 'ok' : 'error',
            responseText: response,
            parseFailure: parsed.failure.name,
            rejectedOps: parsed.rejectedOps,
            attempts: [attempt],
            repairAttempted: mode == AnalysisSeed.repair,
            repairResponseText: mode == AnalysisSeed.repair ? response : null,
            // Deliberately positive even when the clock was omitted or rejected.
            opsApplied: parsed.export?.ops.length ?? 0,
          ),
        );
  }
  await c
      .read(chatRepoProvider)
      .mutateMessages(
        sessionId: DomainLoopFixture.session,
        updatedAt: 20,
        mutate: (messages) => [
          ...messages,
          const ChatMessage(
            id: analysisMessage,
            role: 'assistant',
            content: analysisPrivate,
            swipes: [analysisPrivate],
          ),
          if (mode == AnalysisSeed.newerUser)
            const ChatMessage(
              id: 'analysis-newer-user',
              role: 'user',
              content: analysisPrivate,
            ),
        ],
      );
  if (mode != AnalysisSeed.noSnapshot) {
    final snapshotTime = mode == AnalysisSeed.changed ? time : analysisClock;
    await c
        .read(trackerSnapshotRepoProvider)
        .upsertTrackers(
          sessionId: DomainLoopFixture.session,
          messageId: analysisMessage,
          swipeId: 0,
          agentSwipeId: 0,
          committed: false,
          trackers: [
            for (final tracker in baseline)
              tracker.name == 'world:time'
                  ? tracker.copyWith(
                      value: snapshotTime,
                      provenance: buildLedgerProvenance(
                        messageId: analysisMessage,
                        swipeId: 0,
                        agentSwipeId: 0,
                        evidence: analysisPrivate,
                      ),
                    )
                  : tracker,
          ],
        );
  }
}

/// Capture/assert the actual tool result at the third original delegate POST,
/// BEFORE the final reply. Assertions are rethrown outside native transport so
/// a bad expectation cannot masquerade as a successful source-guard refusal.
Future<void> runLedgerAnalysis(
  WidgetTester tester,
  DomainLoopFixture f,
  void Function(Map<String, dynamic> result) check, {
  String expectedReplyStatus = 'complete',
}) async {
  final core = f.screen.core;
  Object? failure;
  StackTrace? stack;
  var checked = false;
  Map<String, dynamic>? analysisResult;
  f.script(
    core.call('astoria_session_integrity', {'operation': 'discover'}),
    next: (round) {
      try {
        if (round == 2) {
          final definitions = core.wire.last['tools'] as List;
          expect(definitions.length, lessThanOrEqualTo(64));
          final integrity = definitions
              .cast<Map<dynamic, dynamic>>()
              .singleWhere(
                (definition) =>
                    (definition['function'] as Map)['name'] ==
                    'astoria_session_integrity',
              );
          final parameters =
              ((integrity['function'] as Map)['parameters'] as Map);
          final fields = parameters['properties'] as Map;
          expect(
            (fields['operation'] as Map)['enum'],
            contains('analyzeLedger'),
          );
          expect((fields['session'] as Map)['maxLength'], 64);
          expect(
            (fields['offset'] as Map)['maximum'],
            ChatRepo.maxControlMetadataOffset,
          );
          final records = (f.lastData()['records'] as List)
              .cast<Map<dynamic, dynamic>>();
          final record = records.singleWhere(
            (r) => r['sessionId'] == DomainLoopFixture.session,
          );
          return core.call('astoria_session_integrity', {
            'operation': 'analyzeLedger',
            'session': record['session'],
          }, id: 'analysis_call');
        }
        if (round == 3) {
          checked = true;
          final messages = (core.wire.last['messages'] as List)
              .cast<Map<dynamic, dynamic>>();
          final tool = messages.lastWhere((m) => m['role'] == 'tool');
          expect(tool['tool_call_id'], 'analysis_call');
          final assistant = messages.lastWhere(
            (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
          );
          final call = (assistant['tool_calls'] as List)
              .cast<Map<dynamic, dynamic>>()
              .single;
          expect(call['id'], 'analysis_call');
          expect(
            (call['function'] as Map)['name'],
            'astoria_session_integrity',
          );
          analysisResult = f.lastResult();
          expect(analysisResult!['ok'], expectedReplyStatus == 'complete');
          check(analysisResult!);
        } else {
          throw StateError('Unexpected analysis delegate round');
        }
      } catch (error, trace) {
        if (failure == null) {
          failure = error;
          stack = trace;
        }
      }
      return core.answer('Only bounded advisory observations.');
    },
  );
  await f.start(tester, confirmation: false);
  final reply = await f.finish(tester);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  expect(checked, true);
  expect(core.wire, hasLength(3));
  expect(reply.status, expectedReplyStatus);
  if (expectedReplyStatus == 'error') {
    expect(
      reply.body,
      'astoria_session_integrity: completed; чтение завершено или изменений нет.\n'
      'astoria_session_integrity: ${analysisResult!['code']}; успех действия не подтверждён.',
    );
    expect(reply.body, isNot(contains('Only bounded advisory observations.')));
  }
  f.noEgress(reply.body);
  final outward =
      '${jsonEncode(core.wire)}${jsonEncode(f.results)}${reply.body}';
  for (final canary in [
    analysisPrivate,
    analysisMessage,
    analysisPipeline,
    'analysis-call',
    analysisClock,
    analysisDate,
    '09:20',
    '10:37',
  ]) {
    expect(outward, isNot(contains(canary)));
  }
}

Future<String> ledgerSources(DomainLoopFixture f) async {
  final db = f.screen.core.native.db;
  return jsonEncode([
    (await db.select(db.chatSessions).get()).map((r) => r.toJson()).toList(),
    (await db.select(db.llmRequestCaptureRows).get())
        .map((r) => r.toJson())
        .toList(),
    (await db.select(db.llmCallEventRows).get())
        .map((r) => r.toJson())
        .toList(),
    (await db.select(db.ledgerDebugRuns).get()).map((r) => r.toJson()).toList(),
    (await db.select(db.trackerSnapshots).get())
        .map((r) => r.toJson())
        .toList(),
    (await db.select(db.trackerRows).get()).map((r) => r.toJson()).toList(),
    (await db.select(db.supportMutationJournal).get())
        .map((r) => r.toJson())
        .toList(),
  ]);
}
