import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/card_rewriter_settings.dart';
import '../models/cleaner_settings.dart';
import '../models/ledger_settings.dart';
import '../models/memory_book_api_settings.dart';
import '../models/memory_pipeline_settings.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_agent_settings.dart';
import '../credentials/memory_custom_api_legacy_source.dart';
import 'credential_vault_provider.dart';
import 'memory_custom_api_credentials_provider.dart';
import 'shared_prefs_provider.dart';

/// Global pipeline LLM settings, persisted in SharedPreferences under the
/// 'pipelineSettings' key. Loaded once at startup. This is a singleton global —
/// the same [PipelineSettings] instance applies to every chat session.
///
/// The JSON format changed from flat (all fields at the root level) to nested
/// (fields grouped under `studioAgent`, `cleaner`, `ledger`, `memoryPipeline`,
/// `memoryBookApi`, `cardRewriter` sub-objects). The [load] method handles both
/// formats
/// idempotently in memory. Loading never rewrites the mixed legacy document;
/// ordinary native saves patch changed leaves under original conditional custody.
final pipelineSettingsProvider =
    StateNotifierProvider<PipelineSettingsNotifier, PipelineSettings>(
      (ref) => PipelineSettingsNotifier(ref),
    );

class PipelineSettingsNotifier extends StateNotifier<PipelineSettings> {
  final Ref _ref;
  PipelineSettingsNotifier(this._ref) : super(const PipelineSettings());

  Future<void> load() async {
    final source = _ref.read(memoryCustomApiLegacySourceProvider);
    final original = source.captureSettings();
    final redaction = _ref.read(secretRedactionCoordinatorProvider);
    try {
      final prefs = await source.preferences(original, () => _ref.mounted);
      final json = MemoryCustomApiLegacySource.decode(
        prefs.get('pipelineSettings'),
      );
      source.registerAliases(json, redaction);
      final parsed = _parseSettingsJson(json);
      if (_ref.mounted && original.current) state = parsed;
      // Read-only compatibility parsing; never rewrite a mixed raw document.
    } catch (_) {}
  }

  Future<void> save(PipelineSettings settings) async {
    if (settings.memoryBookApi.generationApiKey.isNotEmpty) {
      throw const MemoryCustomApiWriteException(
        MemoryCustomApiWriteStatus.denied,
      );
    }
    // Generated toJson retains nested Freezed objects. Materialize JSON before
    // diffing, otherwise a slot replacement would erase its private raw leaves.
    final patch = _changedLeaves(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    if (patch.isEmpty) return;
    final source = _ref.read(memoryCustomApiLegacySourceProvider);
    final result = await source.savePipeline(
      patch,
      isCurrent: () => _ref.mounted,
      hasNativeRecord: (current) => _ref
          .read(memoryCustomApiCredentialOwnerProvider)
          .hasNativeRecord(current),
    );
    if (result.status != MemoryCustomApiWriteStatus.verified) {
      throw MemoryCustomApiWriteException(result.status);
    }
    if (!_ref.mounted || result.receipt?.current != true) return;
    state = _parseSettingsJson(result.ordinary!);
  }

  static Map<String, dynamic> _changedLeaves(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) => {
    for (final entry in after.entries)
      if (entry.key != 'generationApiKey' &&
          jsonEncode(before[entry.key]) != jsonEncode(entry.value))
        entry.key:
            before[entry.key] is Map<String, dynamic> &&
                entry.value is Map<String, dynamic>
            ? _changedLeaves(
                before[entry.key] as Map<String, dynamic>,
                entry.value as Map<String, dynamic>,
              )
            : entry.value,
  };

  /// The caller retains the original raw document privately and writes changed
  /// slot fields only. This publishes its acknowledged parse, not a writeback.
  bool publishNativeSaved(String raw, SavedPreferencesLease receipt) {
    if (!_ref.mounted || !receipt.current) return false;
    final parsed = _parseSettingsJson(jsonDecode(raw) as Map<String, dynamic>);
    if (!receipt.current) return false;
    state = parsed;
    return receipt.current;
  }

  /// Parses the SharedPreferences JSON into [PipelineSettings], handling both
  /// the new nested format and the legacy flat format.
  ///
  /// **Nested format** (current): JSON has `studioAgent`, `cleaner`, `ledger`,
  /// `memoryPipeline`, `memoryBookApi`, `cardRewriter` sub-objects — parsed
  /// directly via
  /// [PipelineSettings.fromJson].
  ///
  /// **Flat format** (legacy): All fields at the root level. Each sub-model's
  /// `fromJson` picks up its own fields from the flat map and uses `@Default`
  /// values for the rest — extra keys are silently ignored. The legacy
  /// `sidecar*` → `aux*` rename is applied first.
  PipelineSettings _parseSettingsJson(Map<String, dynamic> json) {
    json = MemoryCustomApiLegacySource.withoutSecret(json);
    // Already nested — parse directly.
    if (MemoryCustomApiLegacySource.isNested(json)) {
      return PipelineSettings.fromJson(json);
    }

    // Legacy flat format — migrate sidecar → aux, then partition into
    // sub-models. Each sub-model's fromJson reads only its own fields from
    // the flat map; unknown keys are ignored by freezed's generated decoder.
    final migrated = _migrateLegacySidecarJson(json);
    return PipelineSettings(
      studioAgent: StudioAgentSettings.fromJson(migrated),
      cleaner: CleanerSettings.fromJson(migrated),
      ledger: LedgerSettings.fromJson(migrated),
      memoryPipeline: MemoryPipelineSettings.fromJson(migrated),
      memoryBookApi: MemoryBookApiSettings.fromJson(migrated),
      cardRewriter: CardRewriterSettings.fromJson(migrated),
    );
  }

  /// Migrates very old installs that use `sidecar*` keys to the current
  /// `aux*` naming. Idempotent — uses `putIfAbsent` so already-migrated JSON
  /// is untouched.
  Map<String, dynamic> _migrateLegacySidecarJson(Map<String, dynamic> json) {
    final migrated = Map<String, dynamic>.from(json);
    migrated.putIfAbsent('auxSource', () => migrated['sidecarSource']);
    migrated.putIfAbsent('auxModel', () => migrated['sidecarModel']);
    migrated.putIfAbsent('auxEndpoint', () => migrated['sidecarEndpoint']);
    migrated.putIfAbsent('auxApiKey', () => migrated['sidecarApiKey']);
    migrated.putIfAbsent('auxTimeoutMs', () => migrated['sidecarTimeoutMs']);
    return migrated;
  }
}
