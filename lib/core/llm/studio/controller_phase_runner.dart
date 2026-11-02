import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/repositories/studio_preset_repo.dart';
import '../../models/api_config.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../../models/studio_regex.dart';
import '../studio_activation_gate.dart';
import '../studio_agent_executor.dart';
import '../studio_batch_coordinator.dart';
import '../studio_brief_cache.dart';
import '../studio_brief_parser.dart';
import '../studio_stage_brief.dart';
import '../studio_turn_config_snapshot.dart';
import '../generation_context_inputs.dart';
import 'studio_context.dart';
import '../controller_batcher.dart';
import 'controller_result_mapper.dart';
import '../diagnostics/studio_runtime_diagnostics.dart';

/// Result of the shared pre-gen tracker phase. Both [MemoryStudioService.runTrackerCycle]
/// and [MemoryStudioService.runTrackersOnly] call [ControllerPhaseRunner.run]
/// and receive this. `runTrackerCycle` continues with the generator + post-gen
/// trackers using [split], [turnIndex], [historyForScan], [studioPreset];
/// `runTrackersOnly` returns immediately with [briefs].
class PreGenPhaseResult {
  final String status;
  final List<StudioStageBrief> briefs;
  final String? error;
  final AgentPhaseSplit? split;
  final int turnIndex;
  final List<String> historyForScan;
  final StudioPreset? studioPreset;

  const PreGenPhaseResult({
    required this.status,
    this.briefs = const [],
    this.error,
    this.split,
    this.turnIndex = 0,
    this.historyForScan = const [],
    this.studioPreset,
  });
}

/// Runs the shared pre-gen tracker phase: preset resolution → agent split →
/// due-tracker filtering → cache probing → batched execution → brief assembly.
/// Extracted from `MemoryStudioService` (plan Phase 5a) to eliminate ~180 lines
/// of duplication between `runTrackerCycle` and `runTrackersOnly`.
///
/// Deps via constructor (no `Ref` — all repos/batcher are injected).
class ControllerPhaseRunner {
  final StudioPresetRepo _presetRepo;
  final ControllerBatcher _batcher;
  final StudioBriefCache _briefCache;
  final StudioBriefParser _briefParser;
  final StudioBatchCoordinator _batchCoordinator;
  final StudioAgentExecutor _executor;
  final StudioTrackerResultMapper _resultMapper;
  final PipelineSettings Function() _readPipelineSettings;
  final List<StudioRegex> Function() _readStudioRegexes;
  final void Function(String message) _log;

  ControllerPhaseRunner({
    required this._presetRepo,
    required this._batcher,
    required this._briefCache,
    required this._briefParser,
    required this._batchCoordinator,
    required this._executor,
    required this._resultMapper,
    required this._readPipelineSettings,
    required this._readStudioRegexes,
    required this._log,
  });

  /// Resolves the DB Studio preset for [config]. Returns the preset or an
  /// error string if no preset is found.
  Future<({StudioPreset? preset, String? error})> resolvePreset(
    String presetId,
  ) async {
    final presetRepo = _presetRepo;
    final presetById = await presetRepo.getById(presetId);
    if (presetById != null) {
      return (preset: presetById, error: null);
    }
    final presetDefault = await presetRepo.getDefault();
    if (presetDefault == null) {
      return (
        preset: null,
        error: 'No Studio preset found in DB. Rebuild Studio.',
      );
    }
    return (preset: presetDefault, error: null);
  }

  /// Runs the full pre-gen tracker phase. Returns [PreGenPhaseResult] with
  /// `status == 'ok'` and [briefs] on success, or an error status.
  Future<PreGenPhaseResult> run({
    required StudioConfig config,
    required String presetId,
    required GenerationContextInputs inputs,
    required StudioContext context,
    StudioContext? finalContext,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken token,
    StudioPreset? studioPreset,
    StudioTurnConfigSnapshot? turnConfig,
    void Function(String text)? onThinkingUpdate,
  }) async {
    final diagnostics = StudioRuntimeDiagnostics.forRun(token, sessionId);
    void recordPhase(StudioRuntimeOutcome outcome, StudioRuntimeReason reason) {
      if (diagnostics != null && !token.isCancelled) {
        diagnostics.record(diagnostics.phaseContext, outcome, reason);
      }
    }

    if (token.isCancelled) {
      return const PreGenPhaseResult(status: 'aborted');
    }
    final resolvedPreset = studioPreset == null
        ? await resolvePreset(presetId)
        : (preset: studioPreset, error: null);
    if (resolvedPreset.error != null) {
      if (!token.isCancelled) {
        recordPhase(
          StudioRuntimeOutcome.blockingFailure,
          StudioRuntimeReason.missingPreset,
        );
      }
      return PreGenPhaseResult(status: 'error', error: resolvedPreset.error);
    }
    final effectivePreset = resolvedPreset.preset!;
    try {
      final agents =
          effectivePreset.agents.where((agent) => agent.enabled).toList()
            ..sort((a, b) => a.order.compareTo(b.order));
      if (agents.isEmpty) {
        recordPhase(
          StudioRuntimeOutcome.skipped,
          StudioRuntimeReason.noEnabledAgents,
        );
        return const PreGenPhaseResult(status: 'disabled');
      }
      if (token.isCancelled) return const PreGenPhaseResult(status: 'aborted');

      final split = StudioActivationGate.splitAgentsByPhase(agents);
      if (split.finalAgent == null) {
        if (agents.any((agent) => agent.reasoningMode == 'think-replacement')) {
          recordPhase(
            StudioRuntimeOutcome.blockingFailure,
            StudioRuntimeReason.thinkWriterMissing,
          );
          return const PreGenPhaseResult(
            status: 'error',
            error: 'Studio Think mode requires an enabled Main Writer agent.',
          );
        }
        recordPhase(
          StudioRuntimeOutcome.skipped,
          StudioRuntimeReason.noFinalAgent,
        );
        return const PreGenPhaseResult(status: 'disabled');
      }
      final sceneKey = _briefCache.sceneCacheKeyFromInputs(inputs);
      final turnIndex = _briefCache.assistantTurnCountFromInputs(inputs);
      final allHistory = context.history
          .map((message) => message.content)
          .toList();
      final historyForScan = allHistory.length > 8
          ? allHistory.sublist(allHistory.length - 8)
          : allHistory;
      // Every enabled controller runs every turn: the per-agent run interval
      // and keyword gate were agent-level overrides, which an agent no longer
      // carries (§4).
      final dueTrackers = split.preGenTrackers.toList();

      final cachedBriefs = <StudioStageBrief>[];
      final fetchTrackers = <StudioAgent>[];
      final cacheProbeByAgent = <String, CacheProbe>{};
      final trackerContextOverride =
          (turnConfig?.pipelineSettings ?? _readPipelineSettings())
              .studioAgent
              .studioControllerContextSize;
      final studioRegexIdentity = jsonEncode(
        _readStudioRegexes().map((entry) => entry.toJson()).toList(),
      );
      for (final agent in dueTrackers) {
        final resolvedConfig = await _executor.resolveTrackerConfig(
          agent: agent,
          apiConfig: apiConfig,
          sessionId: sessionId,
          apiConfigId: effectivePreset.cheapApiConfigId,
          turnConfig: turnConfig,
        );
        if (token.isCancelled) {
          return const PreGenPhaseResult(status: 'aborted');
        }
        final probe = _briefCache.probeCacheFromInputs(
          agent: agent,
          config: config,
          studioPreset: effectivePreset,
          sessionId: sessionId,
          resolvedConfig: resolvedConfig,
          trackerContextSize: trackerContextOverride,
          maxTokensOverride: _executor.effectiveMaxTokens(agent, turnConfig),
          temperatureOverride: _executor.effectiveTemperature(
            agent,
            turnConfig,
          ),
          inputs: inputs,
          context: context,
          sceneKey: sceneKey,
          turnIndex: turnIndex,
          studioRegexIdentity: studioRegexIdentity,
        );
        cacheProbeByAgent[agent.id] = probe;
        if (probe.hit && probe.brief != null) {
          cachedBriefs.add(probe.brief!);
          if (diagnostics != null) {
            diagnostics.record(
              diagnostics.newCall('studio.controller', agentId: agent.id),
              StudioRuntimeOutcome.skipped,
              StudioRuntimeReason.cacheHit,
            );
          }
        } else {
          fetchTrackers.add(agent);
        }
      }

      final grouping = await _batcher.groupAgents(
        agents: fetchTrackers,
        apiConfig: apiConfig,
        sessionId: sessionId,
        apiConfigId: effectivePreset.cheapApiConfigId,
        turnConfig: turnConfig,
      );
      if (token.isCancelled) return const PreGenPhaseResult(status: 'aborted');
      final fetchedResults = await _batcher.runPhase(
        batchGroups: grouping.batchGroups,
        individualAgents: grouping.individualAgents,
        runBatch: (group) => _batchCoordinator.runBatchGroup(
          group: group,
          config: config,
          studioPreset: effectivePreset,
          context: context,
          apiConfig: apiConfig,
          sessionId: sessionId,
          cancelToken: token,
          apiConfigId: effectivePreset.cheapApiConfigId,
          batchContextSize: trackerContextOverride,
          turnConfig: turnConfig,
        ),
        runIndividual: (agent) => _executor.runIndividualTracker(
          agent: agent,
          trackerContextOverride: trackerContextOverride,
          finalAgent: split.finalAgent,
          finalContext: finalContext,
          config: config,
          studioPreset: effectivePreset,
          context: context,
          apiConfig: apiConfig,
          sessionId: sessionId,
          cancelToken: token,
          apiConfigId: effectivePreset.cheapApiConfigId,
          turnConfig: turnConfig,
          onIntermediateUpdate: agent.reasoningMode == 'think-replacement'
              ? onThinkingUpdate
              : null,
        ),
      );
      if (token.isCancelled) return const PreGenPhaseResult(status: 'aborted');
      final failure = _resultMapper.firstFailedTrackerResult(fetchedResults);
      if (failure != null) {
        recordPhase(
          StudioRuntimeOutcome.blockingFailure,
          StudioRuntimeReason.requiredTrackerFailed,
        );
        final failedBriefs = _resultMapper.trackerResultsToBriefs(
          fetchedResults,
          dueTrackers,
          cacheProbeByAgent,
        );
        final error = _resultMapper.trackerFailureMessage(failure);
        _log('tracker cycle failed session=$sessionId error=$error');
        return PreGenPhaseResult(
          status: 'error',
          briefs: failedBriefs,
          error: error,
        );
      }

      final fetchedBriefs = <StudioStageBrief>[];
      for (final result in fetchedResults) {
        final probe = cacheProbeByAgent[result.agentId];
        final agent = dueTrackers.firstWhere(
          (candidate) => candidate.id == result.agentId,
        );
        final isThink = agent.reasoningMode == 'think-replacement';
        final brief = StudioStageBrief(
          agentId: result.agentId,
          agentName: result.agentName,
          brief: result.status == 'ok'
              ? (isThink
                    ? result.text
                    : _briefParser.sanitizeIntermediateAgentOutput(
                        agent,
                        result.text,
                      ))
              : result.text,
          status: result.status,
          error: result.error,
          nativeReasoning: isThink ? result.nativeReasoning : '',
          refreshPolicy: probe?.policy ?? 'turn',
          cacheKey: _briefCache.isCacheablePolicy(probe?.policy ?? 'turn')
              ? probe?.cacheKey
              : null,
          cacheHit: false,
          isThinkReplacement: isThink,
        );
        _briefCache.persistCacheIfCacheable(
          agent: agent,
          brief: brief,
          cacheKey: probe?.cacheKey ?? '',
          policy: probe?.policy ?? 'turn',
          turnIndex: turnIndex,
          cancelToken: token,
        );
        fetchedBriefs.add(brief);
      }
      final briefs = <StudioStageBrief>[];
      for (final agent in dueTrackers) {
        final cached = cachedBriefs
            .where((brief) => brief.agentId == agent.id)
            .firstOrNull;
        if (cached != null) {
          briefs.add(cached);
          continue;
        }
        final fetched = fetchedBriefs
            .where((brief) => brief.agentId == agent.id)
            .firstOrNull;
        if (fetched != null) briefs.add(fetched);
      }
      recordPhase(
        dueTrackers.isEmpty
            ? StudioRuntimeOutcome.skipped
            : StudioRuntimeOutcome.executed,
        dueTrackers.isEmpty
            ? StudioRuntimeReason.noControllers
            : StudioRuntimeReason.phaseCompleted,
      );
      return PreGenPhaseResult(
        status: 'ok',
        briefs: briefs,
        split: split,
        turnIndex: turnIndex,
        historyForScan: historyForScan,
        studioPreset: effectivePreset,
      );
    } on TimeoutException catch (error) {
      if (!token.isCancelled) {
        recordPhase(
          StudioRuntimeOutcome.blockingFailure,
          StudioRuntimeReason.phaseTimeout,
        );
      }
      return PreGenPhaseResult(
        status: 'timeout',
        error: error.message?.isNotEmpty == true
            ? error.message
            : 'Studio timed out',
      );
    } catch (error) {
      if (token.isCancelled ||
          (error is DioException && CancelToken.isCancel(error))) {
        return const PreGenPhaseResult(status: 'aborted');
      }
      recordPhase(
        StudioRuntimeOutcome.blockingFailure,
        StudioRuntimeReason.phaseException,
      );
      _log('tracker cycle error session=$sessionId error=$error');
      return PreGenPhaseResult(status: 'error', error: '$error');
    }
  }
}
