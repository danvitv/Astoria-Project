import 'package:easy_localization/easy_localization.dart';

import '../../../core/models/api_config.dart';

/// Formats what a slot inherits while a Studio-level parameter is disabled.
///
/// Sampling and reasoning parameters come from the API preset selected for the
/// slot, so their concrete values can be shown. Temperature, max tokens and the
/// timeout may fall back to different per-agent specs, so [agentDefault] is used
/// where there is no single inherited number.
class StudioSlotInheritedValues {
  final ApiConfig? preset;

  const StudioSlotInheritedValues(this.preset);

  String get agentDefault => 'studio_slot_override_agent_default'.tr();

  String _wrap(String value) =>
      'studio_slot_override_preset_value'.tr(namedArgs: {'value': value});

  String _omitted() => 'studio_slot_override_preset_omitted'.tr();

  String _number(double value, {int decimals = 2}) {
    final text = value.toStringAsFixed(decimals);
    if (decimals == 0) return text;
    final trimmed = text.replaceAll(RegExp(r'0+$'), '');
    return trimmed.endsWith('.') ? '${trimmed}0' : trimmed;
  }

  String _resolve(
    String Function(ApiConfig config) read, {
    bool omitted = false,
  }) {
    final config = preset;
    if (config == null) return 'studio_slot_override_preset_missing'.tr();
    if (omitted) return _omitted();
    return _wrap(read(config));
  }

  String get topP =>
      _resolve((c) => _number(c.topP), omitted: preset?.omitTopP ?? false);

  String get topK => _resolve(
    (c) => _number(c.topK.toDouble(), decimals: 0),
    omitted: preset?.omitTopK ?? false,
  );

  String get frequencyPenalty => _resolve(
    (c) => _number(c.frequencyPenalty),
    omitted: preset?.omitFrequencyPenalty ?? false,
  );

  String get presencePenalty => _resolve(
    (c) => _number(c.presencePenalty),
    omitted: preset?.omitPresencePenalty ?? false,
  );
}
