import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/controller_batcher.dart';
import 'package:glaze_flutter/core/llm/diagnostics/studio_runtime_diagnostics.dart';
import 'package:glaze_flutter/core/llm/diagnostics/studio_runtime_call_facts.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio/controller_phase_runner.dart';
import 'package:glaze_flutter/core/llm/studio/controller_result_mapper.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_agent_executor.dart';
import 'package:glaze_flutter/core/llm/studio_batch_coordinator.dart';
import 'package:glaze_flutter/core/llm/studio_brief_cache.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

import '../helpers/support_automatic_sources_fixture.dart';
import '../support_app_backup_loop_fixture.dart';

const _session = 'runtime-private-game';
const _prompt = 'RUNTIME_PRIVATE_PROMPT';
const _output = 'RUNTIME_PRIVATE_OUTPUT';

// Inherits the existing fixture's file/native/socket tripwires. No dispatcher,
// broker, probe or HTTP request is invoked by this synthetic original transport.
final class _Transport implements ChatTransport {
  _Transport(this.fail, {this.failuresBeforeSuccess, this.streamScenario});
  final bool fail;
  final int? failuresBeforeSuccess;
  final String? streamScenario;
  final calls = <ChatTransportRequest>[];

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    calls.add(request);
    expect(request.apiKey, isEmpty);
    expect(request.savedConnectionAuth, isNotNull);
    expect(request.nativeSourceIsCurrent?.call(), true);
    if (fail || calls.length <= (failuresBeforeSuccess ?? 0)) {
      onError?.call(TimeoutException('RAW_RUNTIME_ERROR_PROSE'));
    } else if (streamScenario != null) {
      onUpdate?.call('A', 'RC');
      onUpdate?.call('😀', null);
      if (streamScenario == 'child_partial') {
        cancelToken!.cancel('PRIVATE_CHILD_CANCEL_REASON');
        onError?.call(cancelToken.cancelError!);
      } else {
        onComplete?.call(
          _output,
          'PRIVATE_FINAL_REASONING_NOT_A_DELTA',
          rawResponseJson: jsonEncode({
            'astoria_stream_termination': streamScenario == 'unknown_finish'
                ? 'PRIVATE_TERMINATION'
                : 'terminal',
            'choices': [
              {
                'finish_reason': streamScenario == 'unknown_finish'
                    ? 'PRIVATE_FINISH_REASON'
                    : 'stop',
                'message': {'content': _output},
              },
            ],
          }),
        );
      }
    } else {
      onComplete?.call(
        request.captureContext?.stage == 'studio.post_processing'
            ? _output
            : '<result agent="continuity">Focus: $_output</result>',
        null,
      );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => throw StateError('Model discovery is not authorized by this test');
}

Future<void> _seed(BackupLoopNative native) async {
  await native.db.customStatement(
    "INSERT INTO characters(char_id,name) VALUES('runtime-character','Runtime evidence')",
  );
  await native.db.customStatement(
    'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES(?,?,0,?)',
    [_session, 'runtime-character', '[]'],
  );
  // FIRST entry for a separate synthetic Studio connection. Existing native
  // credentials deliberately cannot acquire additional purposes by re-entry.
  final api = native.api.copyWith(
    id: 'runtime-studio-api',
    name: 'Synthetic runtime Studio connection',
    requestReasoning: false,
    omitReasoning: true,
    reasoningTagStart: '',
    reasoningTagEnd: '',
  );
  await native.apiRepo.put(api);
  final reference = native.native.auth.referenceFor(
    api,
    NativeProviderPurpose.studio,
  )!;
  final review = await native.native.secretEntry.review(
    connection: reference,
    purposes: const {NativeProviderPurpose.studio},
    lifetime: NativeProviderViewLifetime(isCurrent: () => native.rootCurrent),
  );
  await native.native.credentials.storeFromNativeEntry(
    permit: native.native.secretEntry.confirmNativeEntry(review),
    secret: BackupLoopNative.key,
  );
  await native.reconfirm();
}

Future<(PreGenPhaseResult, List<ChatTransportRequest>)> _recordPhase(
  BackupLoopNative native, {
  required bool fail,
  bool disabled = false,
  StudioAgent? tracker,
  bool postProcessing = false,
  int? failuresBeforeSuccess,
  String? streamScenario,
  bool finalResponse = false,
}) async {
  final api = (await native.apiRepo.getById('runtime-studio-api'))!;
  final transport = _Transport(
    fail,
    failuresBeforeSuccess: failuresBeforeSuccess,
    streamScenario: streamScenario,
  );
  final parser = StudioBriefParser((_) {});
  final cache = StudioBriefCache(parser);
  final builder = StudioMessageBuilder(
    const StudioPromptText(),
    StudioBriefDeduper(parser),
  );
  final runner = AgentRunner(
    configResolver: AgentConfigResolver(
      loadApiConfigs: () async => [api],
      readActiveApiConfig: () => api,
      readPipelineSettings: () => const PipelineSettings(),
      sources: native.native.sources,
      isCurrent: () => native.rootCurrent,
    ),
    readPipelineSettings: () => const PipelineSettings(),
    transportPicker: (_) => transport,
  );
  final executor = StudioAgentExecutor(
    runner,
    builder,
    parser,
    () => const PipelineSettings(),
  );
  final batcher = ControllerBatcher(runner);
  final phase = ControllerPhaseRunner(
    presetRepo: StudioPresetRepo(native.db),
    batcher: batcher,
    briefCache: cache,
    briefParser: parser,
    batchCoordinator: StudioBatchCoordinator(batcher, runner, builder, (_) {}),
    executor: executor,
    resultMapper: StudioTrackerResultMapper(parser, cache),
    readPipelineSettings: () => const PipelineSettings(),
    readStudioRegexes: () => const [],
    log: (_) {},
  );
  final preset = StudioPreset(
    id: 'runtime-preset',
    agents: disabled
        ? const []
        : [
            tracker ??
                const StudioAgent(
                  id: 'continuity',
                  controllerId: 'continuity',
                  order: 0,
                ),
            const StudioAgent(id: 'final', controllerId: 'final', order: 1),
          ],
  );
  const context = StudioContext(
    slots: {},
    history: [],
    sessionVars: {},
    globalVars: {},
    macroContext: MacroContext(
      charName: _prompt,
      charId: 'runtime-character',
      sessionId: _session,
    ),
    diagnostics: StudioContextDiagnostics(),
  );
  final sink = LlmRequestCaptureRepo(native.db);
  final previous = LlmCallEventCapture.sink;
  final requests = LlmRequestCapture.sink;
  LlmCallEventCapture.sink = sink;
  LlmRequestCapture.sink = sink;
  try {
    final token = CancelToken();
    final PreGenPhaseResult result;
    if (finalResponse) {
      final output = await runner.runAgent(
        agent: const StudioAgent(id: 'final', controllerId: 'final', order: 1),
        messages: const [
          {'role': 'user', 'content': '<think>$_prompt</think>'},
        ],
        apiConfig: api,
        sessionId: _session,
        isFinalResponse: true,
        cancelToken: token,
        batchMaxTokens: 1234,
        batchTemperature: 0,
      );
      result = PreGenPhaseResult(
        status: 'ok',
        briefs: [
          StudioStageBrief(agentId: 'final', agentName: '', brief: output.text),
        ],
      );
    } else if (postProcessing) {
      final brief = await executor.runPostProcessingTracker(
        agent: const StudioAgent(
          id: 'post-runtime',
          controllerId: 'continuity',
          phase: 'post_processing',
        ),
        mainResponse: _prompt,
        context: context,
        apiConfig: api,
        config: const StudioConfig(sessionId: _session),
        studioPreset: preset,
        sessionId: _session,
        cancelToken: token,
      );
      // Adapt the helper's result only; this path does not execute or record a
      // pre-generation phase decision or a final generator.
      result = PreGenPhaseResult(
        status: brief.status,
        briefs: [brief],
        error: brief.error,
      );
    } else {
      result = await phase.run(
        config: const StudioConfig(sessionId: _session),
        presetId: 'runtime-preset',
        studioPreset: preset,
        inputs: GenerationContextInputs(
          character: const Character(id: 'runtime-character', name: _prompt),
          history: const [],
          apiConfig: api,
        ),
        context: context,
        finalContext: context,
        apiConfig: api,
        sessionId: _session,
        token: token,
      );
    }
    await sink.close();
    return (result, transport.calls);
  } finally {
    LlmCallEventCapture.sink = previous;
    LlmRequestCapture.sink = requests;
    await sink.close();
  }
}

Future<
  (
    SupportSourceNavigationRepo,
    nav.SourceObservation,
    List<nav.SectionDescriptor>,
  )
>
_summaries(AutomaticSourcesFixture f) async {
  final reader = SupportSourceNavigationRepo(
    boundary: SupportSourceTextRepo(
      db: f.native.db,
      cipher: f.native.cipher,
      currentRedactor: () => f.native.redaction.redactor,
    ),
    isCurrent: () => f.native.rootCurrent,
    ownSupportSessionId: f.native.session,
  );
  final source = (await reader.discover(
    nav.SourceDomain.applicationData,
    null,
    null,
    const nav.WorkBound(),
  )).items.singleWhere((s) => s.key.nativeId == 'requestDiagnostics');
  final scope = reader.approvalScope(source)!;
  final roots = await reader.contents(
    source,
    scope,
    null,
    null,
    const nav.WorkBound(),
  );
  final selection = roots.items
      .singleWhere((r) => r.selection.sectionId == 'calls')
      .selection;
  final observations = <nav.SectionDescriptor>[];
  Object? cursor;
  for (var pageNumber = 0; pageNumber < 12; pageNumber++) {
    final page = await reader.contents(
      source,
      scope,
      selection,
      cursor,
      const nav.WorkBound(),
    );
    observations.addAll(
      page.items.where((r) => r.label!.endsWith('recordedStudioRuntime')),
    );
    if (page.complete) return (reader, source, observations);
    expect(page.next, isNotNull, reason: 'Bounded saved-call enumeration');
    cursor = page.next;
  }
  throw TestFailure('Synthetic event enumeration exceeded twelve pages');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (lane, fail, disabled, tracker, status, outcome, calls) in [
    ('batch success', false, false, null, 'ok', 'executed', 1),
    ('batch retries', true, false, null, 'error', 'blocking_failure', 3),
    ('disabled', false, true, null, 'disabled', 'skipped', 0),
    (
      'individual retries',
      true,
      false,
      const StudioAgent(
        id: 'continuity',
        controllerId: 'continuity',
        name: 'Runtime lorebook',
      ),
      'error',
      'blocking_failure',
      3,
    ),
    (
      'Think single paid attempt',
      true,
      false,
      const StudioAgent(
        id: 'think',
        controllerId: 'think',
        reasoningMode: 'think-replacement',
      ),
      'error',
      'blocking_failure',
      1,
    ),
  ]) {
    test(
      'actual native $lane persists $outcome without raw capture',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f.native);
          final writes = f.native.storage.writeKeys.length;
          final (result, sent) = await _recordPhase(
            f.native,
            fail: fail,
            disabled: disabled,
            tracker: tracker,
          );
          expect(result.status, status);
          expect(sent, hasLength(calls));
          if (fail) expect(result.split, isNull);
          expect(f.native.storage.writeKeys.length, writes);
          final repo = LlmRequestCaptureRepo(f.native.db);
          try {
            expect(await repo.newestForSession(_session), isEmpty);
            final events = await repo.newestCallEventsForSession(_session);
            expect(events, isNotEmpty);
            expect(events.map((e) => e.pipelineRunId).toSet(), hasLength(1));
            for (final event in events) {
              expect(event.responseText, isNull);
              expect(event.error, isNull);
              if (const {
                'transport_failed',
                'transport_completed',
              }.contains(event.parserCode)) {
                expect(
                  StudioRuntimeCallFacts.fromSavedPayload(event.payloadJson),
                  isNotNull,
                );
              } else {
                expect(event.payloadJson, '{}');
              }
            }
            if (!disabled) {
              expect(
                sent.map((r) => r.captureContext!.callId).toSet(),
                hasLength(1),
              );
              expect(sent.map((r) => r.captureContext!.stage).toSet(), {
                'studio.controller',
              });
              expect(
                sent.map((r) => r.captureContext!.attempt),
                List.generate(calls, (i) => i + 1),
              );
              final completions =
                  events
                      .where(
                        (e) =>
                            e.parserCode == 'transport_failed' ||
                            e.parserCode == 'transport_completed',
                      )
                      .toList()
                    ..sort((a, b) => a.attempt!.compareTo(b.attempt!));
              expect(completions, hasLength(calls));
              expect(
                completions.map((e) => e.attempt),
                List.generate(calls, (i) => i + 1),
              );
              expect(completions.map((e) => e.callId).toSet(), {
                sent.first.captureContext!.callId,
              });
              expect(completions.map((e) => e.stage).toSet(), {
                'studio.controller',
              });
              expect(completions.map((e) => e.status).toSet(), {
                fail ? 'failed' : 'executed',
              });
              final invocation = events.singleWhere(
                (e) =>
                    e.stage == 'studio.controller' &&
                    e.parserCode ==
                        (fail
                            ? 'required_tracker_failed'
                            : 'controller_results_accepted'),
              );
              expect(invocation.callId, sent.first.captureContext!.callId);
              expect(invocation.attempt, calls);
              expect(invocation.status, outcome);
            }
          } finally {
            await repo.close();
          }
          final (reader, source, fields) = await _summaries(f);
          try {
            final observations = <Map<String, Object?>>[];
            for (final field in fields) {
              final page = await reader.read(
                source,
                reader.approvalScope(source)!,
                nav.ReadQuery(field.selection, 0, 0),
                const nav.WorkBound(),
              );
              observations.add(
                page.items.single.payload as Map<String, Object?>,
              );
            }
            expect(observations, hasLength(disabled ? 1 : calls + 2));
            final phase = observations.singleWhere(
              (o) => o['stage'] == 'studio.pre_generation.phase',
            );
            expect(phase['outcome'], outcome);
            expect(
              phase['identityLink'],
              'native_exact_session_run_call_attempt',
            );
            expect(phase['requestLink'], 'missing_or_ambiguous');
            expect(phase['runCompleteness'], 'not_proven_by_retained_events');
            if (!disabled) {
              final completions =
                  observations
                      .where(
                        (o) => o['eventUnit'] == 'transport_completion_outcome',
                      )
                      .toList()
                    ..sort(
                      (a, b) =>
                          (a['attempt'] as int).compareTo(b['attempt'] as int),
                    );
              expect(completions, hasLength(calls));
              expect(
                completions.map((o) => o['attempt']),
                List.generate(calls, (i) => i + 1),
              );
              expect(completions.map((o) => o['outcome']).toSet(), {
                fail ? 'failed' : 'executed',
              });
              final invocation = observations.singleWhere(
                (o) => o['eventUnit'] == 'controller_invocation_outcome',
              );
              expect(invocation['attempt'], calls);
              expect(invocation['outcome'], outcome);
            }
            for (final observation in observations.where(
              (o) => o['stage'] == 'studio.controller',
            )) {
              expect(observation['phaseLink'], 'exact_session_run_parent_call');
              expect(observation['phaseReference'], phase['eventReference']);
              expect(observation['requestLink'], 'missing_or_ambiguous');
              expect(observation['scope'], 'this_saved_runtime_event_only');
              expect(observation['causalDiagnosis'], 'insufficient_data');
              expect(
                observation['runCompleteness'],
                'not_proven_by_retained_events',
              );
            }
            final encoded = jsonEncode(observations);
            for (final private in [
              _session,
              _prompt,
              _output,
              BackupLoopNative.key,
              'RAW_RUNTIME_ERROR_PROSE',
              'studio-pipeline-',
              'studio-call-',
              'studio-phase-',
            ]) {
              expect(encoded, isNot(contains(private)));
            }
          } finally {
            reader.retire();
          }
        });
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'native post-processing retries keep one call through two failures and success',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        final writes = f.native.storage.writeKeys.length;
        final (result, sent) = await _recordPhase(
          f.native,
          fail: false,
          postProcessing: true,
          failuresBeforeSuccess: 2,
        );
        expect(result.status, 'ok');
        expect(result.briefs.single.brief, _output);
        expect(sent, hasLength(3));
        expect(sent.map((r) => r.captureContext!.attempt), [1, 2, 3]);
        expect(sent.map((r) => r.captureContext!.callId).toSet(), hasLength(1));
        expect(
          sent.map((r) => r.captureContext!.parentCallId).toSet(),
          hasLength(1),
        );
        final identity = sent.first.captureContext!;
        expect(identity.callId, isNotNull);
        expect(identity.pipelineRunId, isNotNull);
        expect(identity.parentCallId, isNotNull);
        expect(sent.map((r) => r.captureContext!.stage).toSet(), {
          'studio.post_processing',
        });
        expect(sent.map((r) => r.captureContext!.pipelineRunId).toSet(), {
          identity.pipelineRunId,
        });
        final repo = LlmRequestCaptureRepo(f.native.db);
        final privateIds = <String>[];
        try {
          expect(await repo.newestForSession(_session), isEmpty);
          final events = (await repo.newestCallEventsForSession(_session))
            ..sort((a, b) => a.attempt!.compareTo(b.attempt!));
          expect(events, hasLength(3));
          expect(events.map((e) => e.attempt), [1, 2, 3]);
          expect(events.map((e) => e.status), ['failed', 'failed', 'executed']);
          expect(events.map((e) => e.parserCode), [
            'transport_failed',
            'transport_failed',
            'transport_completed',
          ]);
          for (final event in events) {
            expect(event.stage, 'studio.post_processing');
            expect(event.callId, identity.callId);
            expect(event.pipelineRunId, identity.pipelineRunId);
            expect(event.parentCallId, identity.parentCallId);
            expect(event.sessionId, _session);
            expect(event.kind, 'result_selected');
            expect(event.parserName, 'studio_runtime_v1');
            expect(event.responseText, isNull);
            expect(event.error, isNull);
            expect(
              StudioRuntimeCallFacts.fromSavedPayload(event.payloadJson),
              isNotNull,
            );
            privateIds.addAll([
              event.id,
              event.callId,
              event.pipelineRunId,
              event.parentCallId!,
            ]);
          }
        } finally {
          await repo.close();
        }
        final (reader, source, fields) = await _summaries(f);
        try {
          expect(fields, hasLength(3));
          final observations = <Map<String, Object?>>[];
          for (final field in fields) {
            final page = await reader.read(
              source,
              reader.approvalScope(source)!,
              nav.ReadQuery(field.selection, 0, 0),
              const nav.WorkBound(),
            );
            observations.add(page.items.single.payload as Map<String, Object?>);
          }
          observations.sort(
            (a, b) => (a['attempt'] as int).compareTo(b['attempt'] as int),
          );
          expect(observations.map((o) => o['attempt']), [1, 2, 3]);
          expect(observations.map((o) => o['outcome']), [
            'failed',
            'failed',
            'executed',
          ]);
          expect(observations.map((o) => o['reason']), [
            'transport_failed',
            'transport_failed',
            'transport_completed',
          ]);
          for (final observation in observations) {
            expect(observation['stage'], 'studio.post_processing');
            expect(observation['eventUnit'], 'transport_completion_outcome');
            expect(
              observation['identityLink'],
              'native_exact_session_run_call_attempt',
            );
            expect(observation['requestLink'], 'missing_or_ambiguous');
            expect(observation['phaseLink'], 'missing_or_ambiguous');
            expect(observation.containsKey('phaseReference'), false);
            expect(observation['scope'], 'this_saved_runtime_event_only');
            expect(observation['causalDiagnosis'], 'insufficient_data');
            expect(
              observation['runCompleteness'],
              'not_proven_by_retained_events',
            );
          }
          final encoded = jsonEncode(observations);
          for (final private in [
            _session,
            _prompt,
            _output,
            BackupLoopNative.key,
            'RAW_RUNTIME_ERROR_PROSE',
            ...privateIds,
          ]) {
            expect(encoded, isNot(contains(private)));
          }
        } finally {
          reader.retire();
        }
        expect(f.native.storage.writeKeys.length, writes);
        expect(f.wire, isEmpty);
        expect(f.requests, isEmpty);
      });
    },
    skip: !Platform.isWindows,
  );

  for (final scenario in [
    'complete',
    'unknown_finish',
    'child_partial',
    'final',
  ]) {
    test(
      'actual native constructed request and $scenario callback counters stay in ONE event',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f.native);
          final writes = f.native.storage.writeKeys.length;
          final (result, sent) = await _recordPhase(
            f.native,
            fail: false,
            postProcessing: true,
            streamScenario: scenario,
            finalResponse: scenario == 'final',
          );
          expect(result.status, 'ok');
          expect(sent, hasLength(1));
          final request = sent.single;
          final repo = LlmRequestCaptureRepo(f.native.db);
          try {
            expect(await repo.newestForSession(_session), isEmpty);
            final events = await repo.newestCallEventsForSession(_session);
            expect(events, hasLength(1));
            final event = events.single;
            expect(event.callId, request.captureContext!.callId);
            expect(event.attempt, request.captureContext!.attempt);
            expect(event.pipelineRunId, request.captureContext!.pipelineRunId);
            expect(event.parentCallId, request.captureContext!.parentCallId);
            expect(event.responseText, isNull);
            expect(event.error, isNull);
            final persisted =
                jsonDecode(event.payloadJson) as Map<String, Object?>;
            expect(persisted['studioCallFactsVersion'], 1);
            final built =
                persisted['constructedRequest'] as Map<String, Object?>;
            expect(built['messageCount'], request.messages.length);
            expect(built['maxTokens'], request.maxTokens);
            expect(built['temperature'], request.temperature);
            expect(built['topP'], request.topP);
            expect(built['omitReasoning'], request.omitReasoning);
            expect(built['requestReasoning'], request.requestReasoning);
            if (scenario == 'final') {
              expect(request.captureContext!.stage, 'studio.final');
              expect(
                request.messages.single['content'],
                'hidden reasoning${_prompt}hidden reasoning',
              );
              expect(
                built['textContentCodeUnits'],
                (request.messages.single['content'] as String).length,
              );
              expect(
                built['textContentCodeUnits'],
                isNot('<think>$_prompt</think>'.length),
              );
              expect(built['maxTokens'], 1234);
              expect(built['temperature'], 0);
            }
            final stream =
                persisted['streamObservation'] as Map<String, Object?>;
            final elapsed = stream['elapsedMs'] as int;
            expect(stream['chunkCount'], 2);
            expect(stream['contentDeltaCodeUnits'], 3); // A + surrogate pair.
            expect(
              stream['reasoningDeltaCodeUnits'],
              2,
            ); // Callback deltas only.
            expect(stream['elapsedMs'], inInclusiveRange(0, 86400000));
            expect(stream['firstChunkMs'], inInclusiveRange(0, elapsed));
            expect(stream['maxChunkGapMs'], inInclusiveRange(0, elapsed));
            expect(
              stream['completionBranch'],
              scenario == 'child_partial'
                  ? 'cancel_with_streamed_text'
                  : 'complete',
            );
            final completed = scenario == 'complete' || scenario == 'final';
            expect(stream['callbackFinishReason'], completed ? 'stop' : null);
            expect(stream['streamTermination'], completed ? 'terminal' : null);
          } finally {
            await repo.close();
          }
          final (reader, source, fields) = await _summaries(f);
          try {
            expect(fields, hasLength(1));
            final page = await reader.read(
              source,
              reader.approvalScope(source)!,
              nav.ReadQuery(fields.single.selection, 0, 0),
              const nav.WorkBound(),
            );
            final observation =
                page.items.single.payload as Map<String, Object?>;
            expect(
              observation['outcome'],
              scenario == 'child_partial' ? 'fallback' : 'executed',
            );
            expect(observation['requestLink'], 'missing_or_ambiguous');
            expect(
              observation['identityLink'],
              'native_exact_session_run_call_attempt',
            );
            expect(
              observation['runCompleteness'],
              'not_proven_by_retained_events',
            );
            final call = observation['callFacts'] as Map<String, Object?>;
            expect(call['providerWireNormalization'], 'unknown_not_observed');
            expect(call['providerSamplerBehavior'], 'unknown_not_observed');
            expect(call['providerFinishReason'], 'unknown_not_attested');
            expect(call['lengthUnit'], 'utf16_code_units_not_tokens');
            final encoded = jsonEncode(observation);
            for (final private in [
              _prompt,
              _output,
              _session,
              BackupLoopNative.key,
              request.endpoint,
              request.model,
              request.captureContext!.callId!,
              'PRIVATE_FINISH_REASON',
              'PRIVATE_TERMINATION',
              'PRIVATE_FINAL_REASONING_NOT_A_DELTA',
              'PRIVATE_CHILD_CANCEL_REASON',
            ]) {
              if (private.isNotEmpty) expect(encoded, isNot(contains(private)));
            }
          } finally {
            reader.retire();
          }
          expect(f.native.storage.writeKeys.length, writes);
          expect(f.wire, isEmpty);
          expect(f.requests, isEmpty);
        });
      },
      skip: !Platform.isWindows,
    );
  }

  for (final ambiguity in ['duplicate parent', 'wrong session', 'wrong run']) {
    test(
      'native runtime source refuses $ambiguity phase linkage without raw IDs',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f.native);
          final writes = f.native.storage.writeKeys.length;
          await _recordPhase(f.native, fail: false);
          final repo = LlmRequestCaptureRepo(f.native.db);
          final privateIds = <String>[];
          try {
            final events = await repo.newestCallEventsForSession(_session);
            final phase = events.singleWhere(
              (e) => e.stage == 'studio.pre_generation.phase',
            );
            final parentCallId = ambiguity == 'duplicate parent'
                ? phase.callId
                : 'RAW_RUNTIME_PARENT_CALL';
            final parentSession = ambiguity == 'wrong session'
                ? 'RAW_RUNTIME_OTHER_SESSION'
                : _session;
            final parentRun = ambiguity == 'wrong run'
                ? 'RAW_RUNTIME_OTHER_RUN'
                : phase.pipelineRunId;
            // Adversarial retained metadata, not a claimed execution. Preserve
            // the actual unique phase; add a duplicate or a foreign candidate
            // and a child whose parent lookup must not guess across identities.
            await repo.recordCallEvent(
              LlmCallEvent(
                id: 'RAW_RUNTIME_PARENT_EVENT',
                createdAt: DateTime.now().toUtc(),
                context: LlmCaptureContext(
                  stage: 'studio.pre_generation.phase',
                  sessionId: parentSession,
                  pipelineRunId: parentRun,
                  callId: parentCallId,
                  attempt: 1,
                ),
                kind: phase.kind,
                status: phase.status,
                parserName: phase.parserName,
                parserCode: phase.parserCode,
              ),
            );
            await repo.recordCallEvent(
              LlmCallEvent(
                id: 'RAW_RUNTIME_CHILD_EVENT',
                createdAt: DateTime.now().toUtc(),
                context: LlmCaptureContext(
                  stage: 'studio.post_processing',
                  sessionId: _session,
                  pipelineRunId: phase.pipelineRunId,
                  callId: 'RAW_RUNTIME_CHILD_CALL',
                  parentCallId: parentCallId,
                  attempt: 1,
                ),
                kind: 'result_selected',
                status: 'executed',
                parserName: 'studio_runtime_v1',
                parserCode: 'transport_completed',
              ),
            );
            expect(
              await repo.callEvents(parentCallId),
              hasLength(ambiguity == 'duplicate parent' ? 2 : 1),
            );
            expect(await repo.newestForSession(_session), isEmpty);
            privateIds.addAll([
              phase.id,
              phase.callId,
              phase.pipelineRunId,
              parentCallId,
              parentSession,
              parentRun,
              'RAW_RUNTIME_PARENT_EVENT',
              'RAW_RUNTIME_CHILD_EVENT',
              'RAW_RUNTIME_CHILD_CALL',
            ]);
          } finally {
            await repo.close();
          }
          final (reader, source, fields) = await _summaries(f);
          try {
            final observations = <Map<String, Object?>>[];
            for (final field in fields) {
              final page = await reader.read(
                source,
                reader.approvalScope(source)!,
                nav.ReadQuery(field.selection, 0, 0),
                const nav.WorkBound(),
              );
              observations.add(
                page.items.single.payload as Map<String, Object?>,
              );
            }
            final child = observations.singleWhere(
              (o) => o['stage'] == 'studio.post_processing',
            );
            expect(child['outcome'], 'executed');
            expect(child['attempt'], 1);
            expect(
              child['identityLink'],
              'native_exact_session_run_call_attempt',
            );
            expect(child['phaseLink'], 'missing_or_ambiguous');
            expect(child.containsKey('phaseReference'), false);
            expect(child['requestLink'], 'missing_or_ambiguous');
            expect(child['scope'], 'this_saved_runtime_event_only');
            expect(child['causalDiagnosis'], 'insufficient_data');
            expect(child['runCompleteness'], 'not_proven_by_retained_events');
            final encoded = jsonEncode(observations);
            for (final private in [
              _session,
              _prompt,
              _output,
              BackupLoopNative.key,
              'RAW_RUNTIME_ERROR_PROSE',
              'studio-call-',
              'studio-phase-',
              'studio-pipeline-',
              ...privateIds,
            ]) {
              expect(encoded, isNot(contains(private)));
            }
          } finally {
            reader.retire();
          }
          expect(f.native.storage.writeKeys.length, writes);
          expect(f.wire, isEmpty);
          expect(f.requests, isEmpty);
        });
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'original diagnostic sink switch retires old token and keeps finite budget',
    () {
      final old = _Sink(), replacement = _Sink();
      final previous = LlmCallEventCapture.sink;
      try {
        final token = CancelToken();
        LlmCallEventCapture.sink = old;
        final run = StudioRuntimeDiagnostics.forRun(token, _session)!;
        expect(
          StudioRuntimeDiagnostics.forRun(token, 'different-session'),
          isNull,
        );
        for (var i = 0; i < 200; i++) {
          run.record(
            run.phaseContext,
            StudioRuntimeOutcome.executed,
            StudioRuntimeReason.phaseCompleted,
          );
        }
        expect(old.events, hasLength(128));
        LlmCallEventCapture.sink = replacement;
        expect(StudioRuntimeDiagnostics.forRun(token, _session), isNull);
        run.record(
          run.phaseContext,
          StudioRuntimeOutcome.blockingFailure,
          StudioRuntimeReason.requiredTrackerFailed,
        );
        expect(replacement.events, isEmpty);
        expect(old.events, hasLength(128));
      } finally {
        LlmCallEventCapture.sink = previous;
      }
    },
  );

  test('unobserved sink ABA cannot revive original diagnostic token', () {
    final old = _Sink(), replacement = _Sink();
    final previous = LlmCallEventCapture.sink;
    try {
      final token = CancelToken();
      LlmCallEventCapture.sink = old;
      final run = StudioRuntimeDiagnostics.forRun(token, _session)!;
      LlmCallEventCapture.sink = replacement;
      LlmCallEventCapture.sink = old;
      expect(run.isCurrent, false);
      expect(StudioRuntimeDiagnostics.forRun(token, _session), isNull);
      run.record(
        run.phaseContext,
        StudioRuntimeOutcome.executed,
        StudioRuntimeReason.phaseCompleted,
      );
      expect(old.events, isEmpty);
      expect(replacement.events, isEmpty);
    } finally {
      LlmCallEventCapture.sink = previous;
    }
  });

  test(
    'new runtime observation refuses a current secret collision',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        await _recordPhase(f.native, fail: false, disabled: true);
        f.native.redaction.registerSecret('recorded_studio_runtime_outcome');
        final (reader, _, fields) = await _summaries(f);
        try {
          expect(fields, isEmpty);
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'native call facts current-secret collision omits WHOLE unit, not substrings',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        await _recordPhase(
          f.native,
          fail: false,
          postProcessing: true,
          streamScenario: 'complete',
        );
        f.native.redaction.registerSecret('reasoningDeltaCodeUnits');
        final (reader, source, fields) = await _summaries(f);
        try {
          expect(fields, isEmpty);
          final found = <nav.DataRecord>[];
          Object? cursor;
          for (var i = 0; i < 12; i++) {
            final page = await reader.search(
              source,
              reader.approvalScope(source)!,
              'constructedRequest',
              null,
              cursor,
              const nav.WorkBound(),
            );
            found.addAll(page.items);
            if (page.complete) break;
            expect(page.next, isNotNull);
            cursor = page.next;
            if (i == 11) throw TestFailure('Call fact search exceeded budget');
          }
          expect(found, isEmpty);
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'native source invalid optional payload keeps outcome; truncated payload is never attested or flattened',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        final (_, sent) = await _recordPhase(
          f.native,
          fail: false,
          postProcessing: true,
          streamScenario: 'complete',
        );
        final request = sent.single;
        final repo = LlmRequestCaptureRepo(f.native.db);
        try {
          for (final truncated in [false, true]) {
            await repo.recordCallEvent(
              LlmCallEvent(
                id: truncated
                    ? 'private-truncated-runtime'
                    : 'private-invalid-runtime',
                createdAt: DateTime.now().toUtc(),
                context: request.captureContext!.withCallIdentity(
                  pipelineRunId: request.captureContext!.pipelineRunId!,
                  callId: truncated
                      ? 'private-truncated-call'
                      : 'private-invalid-call',
                ),
                kind: 'result_selected',
                status: 'executed',
                parserName: 'studio_runtime_v1',
                parserCode: 'transport_completed',
                payload: {
                  'studioCallFactsVersion': 1,
                  'constructedRequest': {'route': 'INVALID_PAYLOAD_SENTINEL'},
                  'streamObservation': {'reasoningDeltaCodeUnits': -1},
                },
                truncated: truncated,
              ),
            );
          }
        } finally {
          await repo.close();
        }
        final (reader, source, fields) = await _summaries(f);
        try {
          expect(
            fields,
            hasLength(2),
          ); // Actual call + independently known outcome.
          final observations = <Map<String, Object?>>[];
          for (final field in fields) {
            final page = await reader.read(
              source,
              reader.approvalScope(source)!,
              nav.ReadQuery(field.selection, 0, 0),
              const nav.WorkBound(),
            );
            observations.add(page.items.single.payload as Map<String, Object?>);
          }
          expect(
            observations.where((o) => o.containsKey('callFacts')),
            hasLength(1),
          );
          expect(observations.map((o) => o['outcome']).toSet(), {'executed'});
          Object? cursor;
          for (var i = 0; i < 12; i++) {
            final page = await reader.search(
              source,
              reader.approvalScope(source)!,
              'INVALID_PAYLOAD_SENTINEL',
              null,
              cursor,
              const nav.WorkBound(),
            );
            expect(page.items, isEmpty);
            if (page.complete) break;
            expect(page.next, isNotNull);
            cursor = page.next;
            if (i == 11)
              throw TestFailure('Invalid payload search exceeded budget');
          }
          expect(f.wire, isEmpty);
          expect(f.requests, isEmpty);
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test('diagnostic sink failure cannot change generation control flow', () {
    final previous = LlmCallEventCapture.sink;
    try {
      LlmCallEventCapture.sink = _ThrowingSink();
      final run = StudioRuntimeDiagnostics.forRun(CancelToken(), _session)!;
      expect(
        () => run.record(
          run.phaseContext,
          StudioRuntimeOutcome.blockingFailure,
          StudioRuntimeReason.requiredTrackerFailed,
        ),
        returnsNormally,
      );
    } finally {
      LlmCallEventCapture.sink = previous;
    }
  });

  backupLoopTest(
    'native Send reads ONE actual recorded Studio phase decision',
    (tester, f) async {
      await backupLoopReal(tester, () async {
        await _seed(f.native);
        final (result, sent) = await _recordPhase(
          f.native,
          fail: false,
          disabled: true,
        );
        expect(result.status, 'disabled');
        expect(sent, isEmpty);
        await f.native.permissions.initializeGlobalFromNative(
          f.native.session,
          isCurrent: () => f.native.rootCurrent,
        );
        await f.native.permissions.setGrantFromNative(
          f.native.session,
          SupportPermission.readApplicationData,
          true,
          isCurrent: () => f.native.rootCurrent,
        );
        await f.native.runtime.refresh(resolve: true);
      });
      final writes = f.native.storage.writeKeys.length;
      f.replies.addAll(
        List.generate(5, (_) => AutomaticSourcesFixture.answer()),
      );
      Map<String, dynamic> result(String id) =>
          jsonDecode(
                ((f.wire.last['messages'] as List).lastWhere(
                      (m) => m['role'] == 'tool' && m['tool_call_id'] == id,
                    ))['content']
                    as String,
              )
              as Map<String, dynamic>;
      Map<String, dynamic> body(String id) =>
          jsonDecode(result(id)['data']['sourceText'] as String)
              as Map<String, dynamic>;
      late String source, section, selector;
      f.onFetch = (round) async {
        f.replies[round - 1] = switch (round) {
          1 => AutomaticSourcesFixture.calls([
            ('catalog', 'astoria_sources_list', {'domain': 'applicationData'}),
          ]),
          2 => (() {
            source =
                (result('catalog')['data']['pieces'] as List).singleWhere(
                      (p) =>
                          p['label'] ==
                          'Retained transport requests and call diagnostics',
                    )['source']
                    as String;
            return AutomaticSourcesFixture.calls([
              ('roots', 'astoria_source_contents', {'source': source}),
            ]);
          })(),
          3 => (() {
            section =
                (body('roots')['pieces'] as List).singleWhere(
                      (p) =>
                          p['label'] ==
                          'Retained transport and parser outcomes',
                    )['selector']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'calls',
                'astoria_source_contents',
                {'source': source, 'section': section},
              ),
            ]);
          })(),
          4 => (() {
            selector =
                (body('calls')['pieces'] as List).singleWhere(
                      (p) => (p['label'] as String).endsWith(
                        'recordedStudioRuntime',
                      ),
                    )['selector']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'phase',
                'astoria_source_read',
                {'source': source, 'selector': selector},
              ),
            ]);
          })(),
          5 => (() {
            final evidence = jsonEncode(body('phase'));
            expect(evidence, contains('recorded_studio_runtime_outcome'));
            expect(evidence, contains('no_enabled_agents'));
            expect(evidence, contains('pre_generation_phase_decision'));
            expect(evidence, contains('native_exact_session_run_call_attempt'));
            expect(evidence, contains('not_proven_by_retained_events'));
            return AutomaticSourcesFixture.answer();
          })(),
          _ => throw TestFailure('Unexpected extra POST'),
        };
      };
      await f.start(
        tester,
        picker: false,
        text: 'Проверь записанный исход фазы Studio, не запускай генерацию.',
      );
      final finished = await f.finish(tester);
      expect(finished.status, 'complete');
      expect(f.wire, hasLength(5));
      expect(f.native.storage.writeKeys.length, writes);
      final outward = jsonEncode(f.wire);
      for (final private in [
        _session,
        _prompt,
        _output,
        BackupLoopNative.key,
        'studio-pipeline-',
        'studio-call-',
        'RAW_RUNTIME_ERROR_PROSE',
      ]) {
        expect(outward, isNot(contains(private)));
      }
      f.noEgress();
    },
  );
}

final class _Sink implements LlmCallEventSink {
  final events = <LlmCallEvent>[];
  @override
  void recordCallEvent(LlmCallEvent event) => events.add(event);
}

final class _ThrowingSink implements LlmCallEventSink {
  @override
  void recordCallEvent(LlmCallEvent event) => throw StateError('synthetic');
}
