part of '../support_source_text_repo.dart';

const _studioValidationRecordId = 'settings:studioValidation';
const _studioValidationLabel = 'Current saved Studio block validation';
const _studioTopologyRecordId = 'settings:studioAgentTopology';
const _studioTopologyLabel = 'Current saved Studio agent topology';

extension _NavStudioValidation on SupportSourceNavigationRepo {
  String? _studioValidationMetadataLabel(
    _NavSource source,
    nav.DataRecord record,
  ) {
    if (source.observation.key.domain != nav.SourceDomain.studioPreset ||
        record.selection.sectionId != 'settings' ||
        record.kind != nav.SectionKind.settings ||
        !record.schemaKeysAttested) {
      return null;
    }
    return switch (record.selection.recordId) {
      _studioValidationRecordId => _studioValidationLabel,
      _studioTopologyRecordId => _studioTopologyLabel,
      _ => null,
    };
  }

  List<nav.DataRecord> _studioValidationUnits(
    _NavSource source,
    Map<String, Object?> row,
    Map<String, Object?> decoded,
  ) {
    // Shape/size/locked-data checks have already accepted the complete original
    // row. Decode locally at the app's compatibility boundary; do not persist
    // defaults/migrations or claim the runtime-normalized preset was validated.
    final runtime = _shape.map(decoded['runtime_settings_json']);
    final model = StudioPresetCodec.decodePreset({
      'id': row['preset_id'],
      'name': row['name'],
      'blocks': decoded['blocks_json'],
      'agents': decoded['agents_json'],
      'agentEnabled': decoded['agent_enabled_json'],
      'runtime': runtime,
      'agentBlockRestoreState': runtime['agentBlockRestoreState'],
      'agentEnabledBeforeDependencyOff':
          runtime['agentEnabledBeforeDependencyOff'],
      'controllerAlternativeBlockIds': runtime['controllerAlternativeBlockIds'],
      'expensiveApiConfigId': row['expensive_api_config_id'],
      'cheapApiConfigId': row['cheap_api_config_id'],
      'cleanerApiConfigId': row['cleaner_api_config_id'],
      'ledgerApiConfigId': row['ledger_api_config_id'],
      'maxFinalHistoryMessages': row['max_final_history_messages'],
      'updatedAt': row['updated_at'],
    });
    final results = <nav.DataRecord>[];
    for (final (id, label, summary) in [
      (
        _studioValidationRecordId,
        _studioValidationLabel,
        StudioPresetDiagnostics.inspect(model),
      ),
      (
        _studioTopologyRecordId,
        _studioTopologyLabel,
        StudioAgentTopologyDiagnostics.inspect(
          model,
          savedAgents: _shape
              .list(decoded['agents_json'])
              .map(_shape.map)
              .toList(),
        ),
      ),
    ]) {
      final encoded = jsonEncode(summary);
      if (_projectionPolicy!.redactText(encoded) != encoded) continue;
      results.add(
        nav.DataRecord(
          selection: nav.Selection.record('settings', id),
          kind: nav.SectionKind.settings,
          state: source.observation.state,
          binding: source.observation.binding,
          payload: summary,
          schemaKeysAttested: true,
          label: label,
        ),
      );
    }
    return results;
  }
}
