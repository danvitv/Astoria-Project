import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/studio_controller_ontology.dart';
import '../llm/studio_turn_config_snapshot.dart';
import '../llm/native_saved_connection_source.dart';
import '../llm/studio_api_config_resolver.dart';
import '../credentials/native_provider_credentials.dart';
import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../models/studio_pregen_mode.dart';
import '../models/studio_pipeline_overrides.dart';
import 'active_studio_preset_provider.dart';
import 'db_provider.dart';

class StudioTurnConfigResolver {
  final PipelineSettings Function() readPipelineSettings;
  final bool Function() readStudioFeatureEnabled;
  final Future<void> Function() loadApiConfigs;
  final List<ApiConfig> Function() readApiConfigs;
  final ApiConfig? Function() readActiveApiConfig;
  final Future<String> Function() loadActivePresetId;
  final Future<StudioPreset?> Function(String presetId) loadPreset;
  final Future<StudioPreset?> Function() loadDefaultPreset;
  final NativeSavedConnectionSourceResolver? sources;
  final bool Function() isCurrent;

  const StudioTurnConfigResolver({
    required this.readPipelineSettings,
    required this.readStudioFeatureEnabled,
    required this.loadApiConfigs,
    required this.readApiConfigs,
    required this.readActiveApiConfig,
    required this.loadActivePresetId,
    required this.loadPreset,
    required this.loadDefaultPreset,
    this.sources,
    this.isCurrent = _alwaysCurrent,
  });

  static bool _alwaysCurrent() => true;

  Future<StudioTurnConfigSnapshot> resolve(String sessionId) async {
    final original = sources?.captureOriginalStamp();
    void requireCurrent() {
      if (!isCurrent() ||
          (original != null &&
              !sources!.isOriginalCurrent(original, isCurrent))) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
    }

    requireCurrent();
    final pipelineSettings = readPipelineSettings();
    if (!readStudioFeatureEnabled()) {
      // Native root loads the ACTUAL selected row; legacy override retains the
      // original synchronous active-config behavior.
      if (sources != null) await loadApiConfigs();
      requireCurrent();
      final active = readActiveApiConfig();
      final prepared = active == null || sources == null
          ? null
          : await sources!.prepare(
              originalStamp: original!,
              configuration: active,
              purpose: NativeProviderPurpose.roleplay,
              isCurrent: isCurrent,
            );
      requireCurrent();
      return StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: pipelineSettings,
        apiConfigs: const [],
        activeApiConfig: prepared?.configuration ?? active,
        nativeSources: prepared == null ? const {} : {active!.id: prepared},
      );
    }

    await loadApiConfigs();
    requireCurrent();
    final apiConfigs = List<ApiConfig>.unmodifiable(readApiConfigs());
    final activeApiConfig = readActiveApiConfig();

    StudioPreset? preset;
    final presetId = await loadActivePresetId();
    requireCurrent();
    preset = await loadPreset(presetId);
    requireCurrent();
    if (preset == null) {
      preset = await loadDefaultPreset();
      requireCurrent();
    }
    if (preset != null) {
      final agentEnabled = preset.agentEnabled;
      final useThink =
          studioPregenMode(preset) == StudioPregenMode.thinkReplacement;
      final agents = preset.agents.map((agent) {
        final spec = StudioControllerOntology.specForAgent(agent);
        if (spec == null) return agent.copyWith(enabled: false);
        if (spec.isFinal) return agent.copyWith(enabled: true);
        // An agent whose stored phase doesn't match its resolved spec's
        // phase is a legacy mismap (e.g. a retired "beauty" agent re-tagged
        // to post_clean but still carrying phase=pre_generation). Disable
        // it rather than letting it run in the wrong lane.
        if (agent.phase != spec.phase) {
          return agent.copyWith(enabled: false);
        }
        if (spec.id == 'think') {
          return agent.copyWith(
            enabled: useThink,
            reasoningMode: 'think-replacement',
          );
        }
        if (useThink && spec.phase == 'pre_generation') {
          return agent.copyWith(enabled: false);
        }
        // Earlier editors exposed replacement mode on every agent. Only the
        // dedicated Think lane may seed the final writer with reasoning.
        final normalized =
            spec.phase == 'pre_generation' &&
                agent.reasoningMode == 'think-replacement'
            ? agent.copyWith(reasoningMode: 'normal')
            : agent;
        return agentEnabled[spec.id] == false
            ? normalized.copyWith(enabled: false)
            : normalized;
      }).toList();
      final gated = agents.where((agent) => agent.enabled).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      if (gated.isNotEmpty) {
        preset = preset.copyWith(agents: gated);
      } else {
        // A preset without a runnable agent is not an active Studio turn.
        // Keep the old default-deny behavior for empty or corrupted presets.
        preset = null;
      }
    }

    final prepared = <String, NativePreparedSavedConnection>{};
    ApiConfig? projectedActive = activeApiConfig;
    if (sources != null) {
      final resolver = StudioApiConfigResolver(
        apiConfigs: apiConfigs,
        activeConfig: activeApiConfig,
      );
      final effective = applyStudioPresetOverrides(pipelineSettings, preset);
      final slots = preset == null
          ? const <String>[]
          : [
              preset.expensiveApiConfigId,
              if (preset.agents.any((agent) => agent.phase == 'pre_generation'))
                preset.cheapApiConfigId,
              if (preset.agentEnabled['post_clean'] != false &&
                  effective.cleaner.postCleanerEnabled)
                preset.cleanerApiConfigId,
              if (preset.agentEnabled['ledger'] != false)
                preset.ledgerApiConfigId.isNotEmpty
                    ? preset.ledgerApiConfigId
                    : preset.cleanerApiConfigId,
            ];
      final ids = <String>{
        if (preset == null && activeApiConfig != null) activeApiConfig.id,
        for (final slot in slots)
          if (resolver.resolveRunConfig(slot) != null)
            resolver.resolveRunConfig(slot)!.id,
      };
      for (final id in ids) {
        final row =
            apiConfigs.where((config) => config.id == id).firstOrNull ??
            (activeApiConfig?.id == id ? activeApiConfig : null);
        if (row == null) continue;
        prepared[id] = await sources!.prepare(
          originalStamp: original!,
          configuration: row,
          purpose: preset == null
              ? NativeProviderPurpose.roleplay
              : NativeProviderPurpose.studio,
          isCurrent: isCurrent,
        );
        requireCurrent();
      }
      if (activeApiConfig != null &&
          !prepared.containsKey(activeApiConfig.id)) {
        projectedActive = await sources!.projectSavedSnapshot(
          originalStamp: original!,
          configuration: activeApiConfig,
          isCurrent: isCurrent,
        );
        requireCurrent();
      }
    }
    return StudioTurnConfigSnapshot(
      // Studio is global once an agentic preset is selected. The config still
      // carries the session identity required by the execution pipeline, but
      // must not restore the retired per-chat enable switch.
      config: preset == null
          ? null
          : StudioConfig(sessionId: sessionId, enabled: true),
      preset: preset,
      pipelineSettings: pipelineSettings,
      apiConfigs: List.unmodifiable(
        apiConfigs.map((row) => prepared[row.id]?.configuration ?? row),
      ),
      activeApiConfig:
          prepared[activeApiConfig?.id]?.configuration ?? projectedActive,
      nativeSources: Map.unmodifiable(prepared),
    );
  }
}

final studioTurnConfigResolverProvider = Provider<StudioTurnConfigResolver>((
  ref,
) {
  return StudioTurnConfigResolver(
    sources: ref.watch(nativeProviderRuntimeProvider)?.sources,
    isCurrent: () => ref.mounted,
    readPipelineSettings: () => ref.read(pipelineSettingsProvider),
    readStudioFeatureEnabled: () => ref.read(studioFeatureEnabledProvider),
    loadApiConfigs: () async {
      await ref.read(apiListProvider.future);
    },
    readApiConfigs: () =>
        ref.read(apiListProvider).value ?? const <ApiConfig>[],
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    loadActivePresetId: () => ref.read(activeStudioPresetProvider.future),
    loadPreset: (presetId) =>
        ref.read(studioPresetRepoProvider).getById(presetId),
    loadDefaultPreset: () => ref.read(studioPresetRepoProvider).getDefault(),
  );
});
