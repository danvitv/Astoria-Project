import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/extra_request_parameter.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/extra_request_parameters_editor.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../studio_injection_points.dart';
import 'studio_slot_inherited_values.dart';

/// Which Studio model slot is being configured.
enum StudioSlot { finalGenerator, controller, cleaner, ledger }

/// Snapshot of per-slot generation settings captured in the dialog and applied
/// back to [PipelineSettings] via [applyTo].
///
/// Every parameter carries an `*Override` flag. When it is false the parameter
/// is not written into the request at all, so the API preset selected for the
/// slot supplies the value. Temperature, max tokens and the timeout have no
/// flag of their own in [PipelineSettings] — except final-generator max tokens,
/// where `0` is a meaningful override that omits the request field.
///
/// The ledger only exposes temperature / max tokens / timeout — it has no
/// sampling or reasoning overrides in [LedgerSettings] — so the ledger dialog
/// branch hides those groups and [applyTo] writes only those three fields.
class StudioSlotSettings {
  final double temperature;
  final bool temperatureOverride;
  final double topP;
  final bool topPOverride;
  final int topK;
  final bool topKOverride;
  final double frequencyPenalty;
  final bool frequencyPenaltyOverride;
  final double presencePenalty;
  final bool presencePenaltyOverride;
  final bool requestReasoning;
  final bool requestReasoningOverride;
  final bool showNativeReasoning;
  final bool showNativeReasoningOverride;
  final bool useResponsesApi;
  final bool useResponsesApiOverride;
  final String reasoningEffort;
  final bool reasoningEffortOverride;
  final bool omitTemperature;
  final bool omitTopP;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final int reasoningHistoryCount;
  final bool excludeReasoningFromContextBudget;
  final int maxTokens;
  final bool maxTokensOverride;
  final int timeoutMs;
  final List<ExtraRequestParameter> extraRequestParameters;

  const StudioSlotSettings({
    required this.temperature,
    required this.temperatureOverride,
    required this.topP,
    required this.topPOverride,
    required this.topK,
    required this.topKOverride,
    required this.frequencyPenalty,
    required this.frequencyPenaltyOverride,
    required this.presencePenalty,
    required this.presencePenaltyOverride,
    required this.requestReasoning,
    required this.requestReasoningOverride,
    required this.showNativeReasoning,
    required this.showNativeReasoningOverride,
    required this.useResponsesApi,
    required this.useResponsesApiOverride,
    required this.reasoningEffort,
    required this.reasoningEffortOverride,
    required this.omitTemperature,
    required this.omitTopP,
    required this.omitReasoning,
    required this.omitReasoningEffort,
    this.reasoningHistoryCount = 0,
    this.excludeReasoningFromContextBudget = false,
    required this.maxTokens,
    required this.maxTokensOverride,
    required this.timeoutMs,
    required this.extraRequestParameters,
  });

  /// Temperature as stored: the sentinel `-1` means "inherit", so the slider
  /// value is only persisted while the override is on.
  double get _storedTemperature => temperatureOverride ? temperature : -1.0;

  PipelineSettings applyTo(PipelineSettings pipeline, StudioSlot slot) {
    switch (slot) {
      case StudioSlot.finalGenerator:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioFinalTemperature: _storedTemperature,
            studioFinalTopP: topP,
            studioFinalTopPOverride: topPOverride,
            studioFinalTopK: topK,
            studioFinalTopKOverride: topKOverride,
            studioFinalFrequencyPenalty: frequencyPenalty,
            studioFinalFrequencyPenaltyOverride: frequencyPenaltyOverride,
            studioFinalPresencePenalty: presencePenalty,
            studioFinalPresencePenaltyOverride: presencePenaltyOverride,
            studioFinalRequestReasoning: requestReasoning,
            studioFinalRequestReasoningOverride: requestReasoningOverride,
            studioFinalShowNativeReasoning: showNativeReasoning,
            studioFinalShowNativeReasoningOverride: showNativeReasoningOverride,
            studioFinalUseResponsesApi: useResponsesApi,
            studioFinalUseResponsesApiOverride: useResponsesApiOverride,
            studioFinalReasoningEffort: reasoningEffort,
            studioFinalReasoningEffortOverride: reasoningEffortOverride,
            studioFinalOmitTemperature: omitTemperature,
            studioFinalOmitTopP: omitTopP,
            studioFinalOmitReasoning: omitReasoning,
            studioFinalOmitReasoningEffort: omitReasoningEffort,
            studioFinalReasoningHistoryCount: reasoningHistoryCount,
            studioFinalExcludeReasoningFromContextBudget:
                excludeReasoningFromContextBudget,
            studioFinalMaxTokens: maxTokens,
            studioFinalMaxTokensOverride: maxTokensOverride,
            studioFinalTimeoutMs: timeoutMs,
            studioFinalExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.controller:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioControllerTemperature: _storedTemperature,
            studioControllerTopP: topP,
            studioControllerTopPOverride: topPOverride,
            studioControllerTopK: topK,
            studioControllerTopKOverride: topKOverride,
            studioControllerFrequencyPenalty: frequencyPenalty,
            studioControllerFrequencyPenaltyOverride: frequencyPenaltyOverride,
            studioControllerPresencePenalty: presencePenalty,
            studioControllerPresencePenaltyOverride: presencePenaltyOverride,
            studioControllerRequestReasoning: requestReasoning,
            studioControllerRequestReasoningOverride: requestReasoningOverride,
            studioControllerShowNativeReasoning: showNativeReasoning,
            studioControllerShowNativeReasoningOverride:
                showNativeReasoningOverride,
            studioControllerUseResponsesApi: useResponsesApi,
            studioControllerUseResponsesApiOverride: useResponsesApiOverride,
            studioControllerReasoningEffort: reasoningEffort,
            studioControllerReasoningEffortOverride: reasoningEffortOverride,
            studioControllerOmitTemperature: omitTemperature,
            studioControllerOmitTopP: omitTopP,
            studioControllerOmitReasoning: omitReasoning,
            studioControllerOmitReasoningEffort: omitReasoningEffort,
            studioControllerMaxTokens: maxTokens,
            studioControllerTimeoutMs: timeoutMs,
            studioControllerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.cleaner:
        return pipeline.copyWith(
          cleaner: pipeline.cleaner.copyWith(
            postCleanerTemperature: _storedTemperature,
            postCleanerTopP: topP,
            postCleanerTopPOverride: topPOverride,
            postCleanerTopK: topK,
            postCleanerTopKOverride: topKOverride,
            postCleanerFrequencyPenalty: frequencyPenalty,
            postCleanerFrequencyPenaltyOverride: frequencyPenaltyOverride,
            postCleanerPresencePenalty: presencePenalty,
            postCleanerPresencePenaltyOverride: presencePenaltyOverride,
            postCleanerRequestReasoning: requestReasoning,
            postCleanerRequestReasoningOverride: requestReasoningOverride,
            postCleanerShowNativeReasoning: showNativeReasoning,
            postCleanerShowNativeReasoningOverride: showNativeReasoningOverride,
            postCleanerUseResponsesApi: useResponsesApi,
            postCleanerUseResponsesApiOverride: useResponsesApiOverride,
            postCleanerReasoningEffort: reasoningEffort,
            postCleanerReasoningEffortOverride: reasoningEffortOverride,
            postCleanerOmitTemperature: omitTemperature,
            postCleanerOmitTopP: omitTopP,
            postCleanerOmitReasoning: omitReasoning,
            postCleanerOmitReasoningEffort: omitReasoningEffort,
            postCleanerMaxTokens: maxTokens,
            postCleanerTimeoutMs: timeoutMs,
            postCleanerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.ledger:
        return pipeline.copyWith(
          ledger: pipeline.ledger.copyWith(
            studioLedgerTemperature: _storedTemperature,
            studioLedgerMaxTokens: maxTokens,
            studioLedgerTimeoutMs: timeoutMs,
          ),
        );
    }
  }
}

/// Per-slot generation settings, laid out like the LLM connection sheet:
/// generation parameters, sampling, reasoning, extra request parameters.
///
/// Slider switches mean "set this value in Studio"; off means inherit. Fields
/// use an empty value for inheritance, while boolean and reasoning settings use
/// explicit selectors so there is no second layer of override switches.
///
/// Presented via [showModalBottomSheet] with [SheetView]; pops a
/// [StudioSlotSettings] the caller applies through the pipeline notifier.
class StudioSlotSettingsDialog extends StatefulWidget {
  final StudioSlot slot;
  final PipelineSettings pipeline;

  /// The API preset this slot resolves to, used to show inherited values.
  /// Null when neither the slot nor the LLM tab has a connection selected.
  final ApiConfig? presetConfig;

  const StudioSlotSettingsDialog({
    super.key,
    required this.slot,
    required this.pipeline,
    this.presetConfig,
  });

  @override
  State<StudioSlotSettingsDialog> createState() =>
      _StudioSlotSettingsDialogState();
}

class _StudioSlotSettingsDialogState extends State<StudioSlotSettingsDialog> {
  late double _temperature;
  late bool _temperatureOverride;
  late double _topP;
  late bool _topPOverride;
  late int _topK;
  late bool _topKOverride;
  late double _frequencyPenalty;
  late bool _frequencyPenaltyOverride;
  late double _presencePenalty;
  late bool _presencePenaltyOverride;
  late bool _requestReasoning;
  late bool _requestReasoningOverride;
  late bool _showNativeReasoning;
  late bool _showNativeReasoningOverride;
  late bool _useResponsesApi;
  late bool _useResponsesApiOverride;
  late String _reasoningEffort;
  late bool _reasoningEffortOverride;
  late bool _omitTemperature;
  late bool _omitTopP;
  late bool _omitReasoning;
  late bool _omitReasoningEffort;
  late bool _excludeReasoningFromContextBudget;
  late bool _maxTokensOverride;
  late bool _timeoutOverride;
  late TextEditingController _reasoningHistoryCountCtrl;
  late TextEditingController _maxTokensCtrl;
  late TextEditingController _timeoutCtrl;
  late List<ExtraRequestParameter> _extraRequestParameters;

  bool get _isLedger => widget.slot == StudioSlot.ledger;
  bool get _isFinal => widget.slot == StudioSlot.finalGenerator;

  late final StudioSlotInheritedValues _inherited = StudioSlotInheritedValues(
    widget.presetConfig,
  );

  /// Temperature falls back to this while the override is off, so re-enabling
  /// the switch restores a usable slider position instead of the sentinel.
  static const double _temperatureFallback = 0.7;

  @override
  void initState() {
    super.initState();
    final p = widget.pipeline;
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        final a = p.studioAgent;
        _initTemperature(a.studioFinalTemperature);
        _topP = a.studioFinalTopP;
        _topPOverride = a.studioFinalTopPOverride;
        _topK = a.studioFinalTopK;
        _topKOverride = a.studioFinalTopKOverride;
        _frequencyPenalty = a.studioFinalFrequencyPenalty;
        _frequencyPenaltyOverride = a.studioFinalFrequencyPenaltyOverride;
        _presencePenalty = a.studioFinalPresencePenalty;
        _presencePenaltyOverride = a.studioFinalPresencePenaltyOverride;
        _requestReasoning = a.studioFinalRequestReasoning;
        _requestReasoningOverride = a.studioFinalRequestReasoningOverride;
        _showNativeReasoning = a.studioFinalShowNativeReasoning;
        _showNativeReasoningOverride = a.studioFinalShowNativeReasoningOverride;
        _useResponsesApi = a.studioFinalUseResponsesApi;
        _useResponsesApiOverride = a.studioFinalUseResponsesApiOverride;
        _reasoningEffort = a.studioFinalReasoningEffort;
        _reasoningEffortOverride = a.studioFinalReasoningEffortOverride;
        _omitTemperature = a.studioFinalOmitTemperature;
        _omitTopP = a.studioFinalOmitTopP;
        _omitReasoning = a.studioFinalOmitReasoning;
        _omitReasoningEffort = a.studioFinalOmitReasoningEffort;
        _excludeReasoningFromContextBudget =
            a.studioFinalExcludeReasoningFromContextBudget;
        _reasoningHistoryCountCtrl = TextEditingController(
          text: '${a.studioFinalReasoningHistoryCount}',
        );
        _initTokensAndTimeout(
          a.studioFinalMaxTokens,
          a.studioFinalTimeoutMs,
          maxTokensOverride: a.studioFinalMaxTokensOverride,
        );
        _extraRequestParameters = a.studioFinalExtraRequestParameters;
      case StudioSlot.controller:
        final a = p.studioAgent;
        _initTemperature(a.studioControllerTemperature);
        _topP = a.studioControllerTopP;
        _topPOverride = a.studioControllerTopPOverride;
        _topK = a.studioControllerTopK;
        _topKOverride = a.studioControllerTopKOverride;
        _frequencyPenalty = a.studioControllerFrequencyPenalty;
        _frequencyPenaltyOverride = a.studioControllerFrequencyPenaltyOverride;
        _presencePenalty = a.studioControllerPresencePenalty;
        _presencePenaltyOverride = a.studioControllerPresencePenaltyOverride;
        _requestReasoning = a.studioControllerRequestReasoning;
        _requestReasoningOverride = a.studioControllerRequestReasoningOverride;
        _showNativeReasoning = a.studioControllerShowNativeReasoning;
        _showNativeReasoningOverride =
            a.studioControllerShowNativeReasoningOverride;
        _useResponsesApi = a.studioControllerUseResponsesApi;
        _useResponsesApiOverride = a.studioControllerUseResponsesApiOverride;
        _reasoningEffort = a.studioControllerReasoningEffort;
        _reasoningEffortOverride = a.studioControllerReasoningEffortOverride;
        _omitTemperature = a.studioControllerOmitTemperature;
        _omitTopP = a.studioControllerOmitTopP;
        _omitReasoning = a.studioControllerOmitReasoning;
        _omitReasoningEffort = a.studioControllerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(
          a.studioControllerMaxTokens,
          a.studioControllerTimeoutMs,
        );
        _extraRequestParameters = a.studioControllerExtraRequestParameters;
      case StudioSlot.cleaner:
        final c = p.cleaner;
        _initTemperature(c.postCleanerTemperature);
        _topP = c.postCleanerTopP;
        _topPOverride = c.postCleanerTopPOverride;
        _topK = c.postCleanerTopK;
        _topKOverride = c.postCleanerTopKOverride;
        _frequencyPenalty = c.postCleanerFrequencyPenalty;
        _frequencyPenaltyOverride = c.postCleanerFrequencyPenaltyOverride;
        _presencePenalty = c.postCleanerPresencePenalty;
        _presencePenaltyOverride = c.postCleanerPresencePenaltyOverride;
        _requestReasoning = c.postCleanerRequestReasoning;
        _requestReasoningOverride = c.postCleanerRequestReasoningOverride;
        _showNativeReasoning = c.postCleanerShowNativeReasoning;
        _showNativeReasoningOverride = c.postCleanerShowNativeReasoningOverride;
        _useResponsesApi = c.postCleanerUseResponsesApi;
        _useResponsesApiOverride = c.postCleanerUseResponsesApiOverride;
        _reasoningEffort = c.postCleanerReasoningEffort;
        _reasoningEffortOverride = c.postCleanerReasoningEffortOverride;
        _omitTemperature = c.postCleanerOmitTemperature;
        _omitTopP = c.postCleanerOmitTopP;
        _omitReasoning = c.postCleanerOmitReasoning;
        _omitReasoningEffort = c.postCleanerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(c.postCleanerMaxTokens, c.postCleanerTimeoutMs);
        _extraRequestParameters = c.postCleanerExtraRequestParameters;
      case StudioSlot.ledger:
        final l = p.ledger;
        _initTemperature(l.studioLedgerTemperature);
        _topP = 0.9;
        _topPOverride = false;
        _topK = 0;
        _topKOverride = false;
        _frequencyPenalty = 0;
        _frequencyPenaltyOverride = false;
        _presencePenalty = 0;
        _presencePenaltyOverride = false;
        _requestReasoning = false;
        _requestReasoningOverride = false;
        _showNativeReasoning = false;
        _showNativeReasoningOverride = false;
        _useResponsesApi = false;
        _useResponsesApiOverride = false;
        _reasoningEffort = 'auto';
        _reasoningEffortOverride = false;
        _omitTemperature = false;
        _omitTopP = false;
        _omitReasoning = true;
        _omitReasoningEffort = true;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(l.studioLedgerMaxTokens, l.studioLedgerTimeoutMs);
        _extraRequestParameters = const [];
    }
  }

  /// A negative stored temperature is the "inherit" sentinel.
  void _initTemperature(double stored) {
    _temperatureOverride = stored >= 0;
    _temperature = stored >= 0 ? stored.clamp(0.0, 2.0) : _temperatureFallback;
  }

  /// Other slots retain the legacy `0 = inherit` sentinel. The final generator
  /// supplies an explicit flag so `0` can mean "omit the request field".
  void _initTokensAndTimeout(
    int maxTokens,
    int timeoutMs, {
    bool? maxTokensOverride,
  }) {
    _maxTokensOverride = maxTokensOverride ?? maxTokens > 0;
    _maxTokensCtrl = TextEditingController(
      text: _maxTokensOverride ? '$maxTokens' : '',
    );
    _timeoutOverride = timeoutMs > 0;
    _timeoutCtrl = TextEditingController(
      text: timeoutMs > 0 ? '${timeoutMs ~/ 1000}' : '',
    );
  }

  @override
  void dispose() {
    _maxTokensCtrl.dispose();
    _timeoutCtrl.dispose();
    _reasoningHistoryCountCtrl.dispose();
    super.dispose();
  }

  String get _slotTitle {
    final String point = switch (widget.slot) {
      StudioSlot.finalGenerator => 'final',
      StudioSlot.controller => 'pregen',
      StudioSlot.cleaner => 'cleaner',
      StudioSlot.ledger => 'ledger',
    };
    return '${studioInjectionPointLabel(point)} ${'studio_slot_settings_title'.tr()}';
  }

  String _reasoningEffortLabel(String effort) => switch (effort) {
    'auto' => 'reasoning_effort_auto'.tr(),
    'min' => 'reasoning_effort_min'.tr(),
    'low' => 'reasoning_effort_low'.tr(),
    'medium' => 'reasoning_effort_medium'.tr(),
    'high' => 'reasoning_effort_high'.tr(),
    'max' => 'reasoning_effort_max'.tr(),
    _ => effort,
  };

  String get _reasoningSelection {
    if (!_requestReasoningOverride) return 'inherit';
    if (!_requestReasoning || _omitReasoning) return 'off';
    if (!_reasoningEffortOverride ||
        _omitReasoningEffort ||
        _reasoningEffort == 'auto') {
      return 'auto';
    }
    return const {
          'min',
          'low',
          'medium',
          'high',
          'max',
        }.contains(_reasoningEffort)
        ? _reasoningEffort
        : 'auto';
  }

  String get _responsesSelection => !_useResponsesApiOverride
      ? 'inherit'
      : (_useResponsesApi ? 'responses' : 'chat');

  String get _showReasoningSelection => !_showNativeReasoningOverride
      ? 'inherit'
      : (_showNativeReasoning ? 'show' : 'hide');

  String _inheritLabel() => 'studio_slot_value_inherit'.tr();

  String _inheritedLabel() => 'studio_slot_value_inherited'.tr();

  String _reasoningSelectionLabel(String value) => switch (value) {
    'inherit' => _inheritLabel(),
    'off' => 'studio_slot_reasoning_off'.tr(),
    _ => _reasoningEffortLabel(value),
  };

  Future<void> _openSelector({
    required String title,
    required String selected,
    required List<({String value, String label})> options,
    required ValueChanged<String> onSelected,
  }) async {
    await GlazeBottomSheet.show<void>(
      context,
      title: title,
      items: options.map((option) {
        final active = option.value == selected;
        return BottomSheetItem(
          label: option.label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => onSelected(option.value));
          },
        );
      }).toList(),
    );
  }

  Future<void> _openReasoningSelector() => _openSelector(
    title: 'studio_slot_settings_request_reasoning'.tr(),
    selected: _reasoningSelection,
    options: [
      (value: 'inherit', label: _inheritLabel()),
      (value: 'off', label: 'studio_slot_reasoning_off'.tr()),
      for (final effort in const [
        'auto',
        'min',
        'low',
        'medium',
        'high',
        'max',
      ])
        (value: effort, label: _reasoningEffortLabel(effort)),
    ],
    onSelected: _setReasoningSelection,
  );

  void _setReasoningSelection(String value) {
    if (value == 'inherit') {
      _requestReasoningOverride = false;
      _reasoningEffortOverride = false;
      return;
    }

    _requestReasoningOverride = true;
    _omitReasoning = false;
    if (value == 'off') {
      _requestReasoning = false;
      _reasoningEffortOverride = false;
      return;
    }

    _requestReasoning = true;
    _reasoningEffortOverride = true;
    _reasoningEffort = value;
    _omitReasoningEffort = value == 'auto';
  }

  Future<void> _openResponsesSelector() => _openSelector(
    title: 'label_use_responses_api'.tr(),
    selected: _responsesSelection,
    options: [
      (value: 'inherit', label: _inheritLabel()),
      (value: 'chat', label: 'studio_slot_transport_chat'.tr()),
      (value: 'responses', label: 'studio_slot_transport_responses'.tr()),
    ],
    onSelected: (value) {
      _useResponsesApiOverride = value != 'inherit';
      if (_useResponsesApiOverride) _useResponsesApi = value == 'responses';
    },
  );

  Future<void> _openShowReasoningSelector() => _openSelector(
    title: 'label_reasoning'.tr(),
    selected: _showReasoningSelection,
    options: [
      (value: 'inherit', label: _inheritLabel()),
      (value: 'hide', label: 'studio_slot_reasoning_hide'.tr()),
      (value: 'show', label: 'studio_slot_reasoning_show'.tr()),
    ],
    onSelected: (value) {
      _showNativeReasoningOverride = value != 'inherit';
      if (_showNativeReasoningOverride) {
        _showNativeReasoning = value == 'show';
      }
    },
  );

  void _save() {
    final maxTokens = _maxTokensOverride
        ? (int.tryParse(_maxTokensCtrl.text.trim()) ?? 0)
        : 0;
    final reasoningHistoryCount =
        int.tryParse(_reasoningHistoryCountCtrl.text.trim()) ?? 0;
    final seconds = _timeoutOverride
        ? (int.tryParse(_timeoutCtrl.text.trim()) ?? 0)
        : 0;
    Navigator.of(context, rootNavigator: true).pop(
      StudioSlotSettings(
        temperature: _temperature,
        temperatureOverride: _temperatureOverride,
        topP: _topP,
        topPOverride: _topPOverride,
        topK: _topK,
        topKOverride: _topKOverride,
        frequencyPenalty: _frequencyPenalty,
        frequencyPenaltyOverride: _frequencyPenaltyOverride,
        presencePenalty: _presencePenalty,
        presencePenaltyOverride: _presencePenaltyOverride,
        requestReasoning: _requestReasoning,
        requestReasoningOverride: _requestReasoningOverride,
        showNativeReasoning: _showNativeReasoning,
        showNativeReasoningOverride: _showNativeReasoningOverride,
        useResponsesApi: _useResponsesApi,
        useResponsesApiOverride: _useResponsesApiOverride,
        reasoningEffort: _reasoningEffort,
        reasoningEffortOverride: _reasoningEffortOverride,
        // The compact Studio switches now select override vs inheritance.
        // Explicit field omission remains an API-preset concern.
        omitTemperature: _temperatureOverride ? false : _omitTemperature,
        omitTopP: _topPOverride ? false : _omitTopP,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        reasoningHistoryCount: reasoningHistoryCount < -1
            ? 0
            : reasoningHistoryCount,
        excludeReasoningFromContextBudget: _excludeReasoningFromContextBudget,
        maxTokens: maxTokens,
        maxTokensOverride: _maxTokensOverride,
        timeoutMs: seconds > 0 ? seconds * 1000 : 0,
        extraRequestParameters: _extraRequestParameters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: _slotTitle,
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'studio_slot_settings_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _buildGenerationGroup(),
          if (!_isLedger) ...[
            _buildSamplingGroup(),
            ExtraRequestParametersEditor(
              parameters: _extraRequestParameters,
              title: 'extra_request_parameters'.tr(),
              description: 'extra_request_parameters_studio_desc'.tr(),
              keyLabel: 'extra_request_parameter_key'.tr(),
              valueLabel: 'extra_request_parameter_value'.tr(),
              addLabel: 'extra_request_parameter_add'.tr(),
              onChanged: (parameters) {
                _extraRequestParameters = parameters;
              },
            ),
            const SizedBox(height: 8),
            _buildReasoningGroup(),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text('studio_slot_settings_save'.tr()),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerationGroup() {
    return MenuGroup(
      compact: true,
      header: 'studio_slot_settings_generation'.tr(),
      description: 'studio_slot_settings_inherit_hint'.tr(),
      items: [
        MenuRangeItem(
          label: 'studio_slot_settings_temperature'.tr(),
          description: _temperatureOverride ? null : _inherited.agentDefault,
          value: _temperature,
          min: 0,
          max: 2,
          divisions: 200,
          editableValue: true,
          included: _temperatureOverride,
          onIncludedChanged: (v) => setState(() {
            _temperatureOverride = v;
            if (v) _omitTemperature = false;
          }),
          onChanged: (v) => setState(() => _temperature = v),
        ),
        MenuFieldItem(
          label: 'studio_slot_settings_max_tokens'.tr(),
          controller: _maxTokensCtrl,
          placeholder: _inheritedLabel(),
          keyboardType: TextInputType.number,
          onChanged: (value) =>
              setState(() => _maxTokensOverride = value.trim().isNotEmpty),
        ),
        MenuFieldItem(
          label: 'studio_slot_settings_timeout'.tr(),
          controller: _timeoutCtrl,
          placeholder: _inheritedLabel(),
          keyboardType: TextInputType.number,
          onChanged: (value) =>
              setState(() => _timeoutOverride = value.trim().isNotEmpty),
        ),
      ],
    );
  }

  Widget _buildSamplingGroup() {
    return MenuGroup(
      compact: true,
      header: 'section_sampling'.tr(),
      description: 'studio_slot_settings_slider_hint'.tr(),
      items: [
        MenuRangeItem(
          label: 'studio_slot_settings_top_p'.tr(),
          description: _topPOverride ? null : _inherited.topP,
          value: _topP,
          min: 0,
          max: 1,
          divisions: 100,
          editableValue: true,
          included: _topPOverride,
          onIncludedChanged: (v) => setState(() {
            _topPOverride = v;
            if (v) _omitTopP = false;
          }),
          onChanged: (v) => setState(() => _topP = v),
        ),
        MenuRangeItem(
          label: 'studio_slot_settings_top_k'.tr(),
          description: _topKOverride ? null : _inherited.topK,
          value: _topK.toDouble(),
          min: 0,
          max: 200,
          divisions: 200,
          editableValue: true,
          decimalPlaces: 0,
          included: _topKOverride,
          onIncludedChanged: (v) => setState(() => _topKOverride = v),
          onChanged: (v) => setState(() => _topK = v.round()),
        ),
        MenuRangeItem(
          label: 'studio_slot_settings_frequency_penalty'.tr(),
          description: _frequencyPenaltyOverride
              ? null
              : _inherited.frequencyPenalty,
          value: _frequencyPenalty,
          min: -2,
          max: 2,
          divisions: 80,
          editableValue: true,
          included: _frequencyPenaltyOverride,
          onIncludedChanged: (v) =>
              setState(() => _frequencyPenaltyOverride = v),
          onChanged: (v) => setState(() => _frequencyPenalty = v),
        ),
        MenuRangeItem(
          label: 'studio_slot_settings_presence_penalty'.tr(),
          description: _presencePenaltyOverride
              ? null
              : _inherited.presencePenalty,
          value: _presencePenalty,
          min: -2,
          max: 2,
          divisions: 80,
          editableValue: true,
          included: _presencePenaltyOverride,
          onIncludedChanged: (v) =>
              setState(() => _presencePenaltyOverride = v),
          onChanged: (v) => setState(() => _presencePenalty = v),
        ),
      ],
    );
  }

  Widget _buildReasoningGroup() {
    return MenuGroup(
      compact: true,
      header: 'studio_slot_settings_reasoning'.tr(),
      items: [
        MenuSelectorItem(
          label: 'label_use_responses_api'.tr(),
          description: 'desc_use_responses_api'.tr(),
          currentValue: switch (_responsesSelection) {
            'chat' => 'studio_slot_transport_chat'.tr(),
            'responses' => 'studio_slot_transport_responses'.tr(),
            _ => _inheritLabel(),
          },
          onTap: _openResponsesSelector,
        ),
        MenuSelectorItem(
          label: 'studio_slot_settings_request_reasoning'.tr(),
          description: 'studio_slot_settings_request_reasoning_desc'.tr(),
          currentValue: _reasoningSelectionLabel(_reasoningSelection),
          onTap: _openReasoningSelector,
        ),
        MenuSelectorItem(
          label: 'label_reasoning'.tr(),
          description: 'desc_reasoning'.tr(),
          currentValue: switch (_showReasoningSelection) {
            'show' => 'studio_slot_reasoning_show'.tr(),
            'hide' => 'studio_slot_reasoning_hide'.tr(),
            _ => _inheritLabel(),
          },
          onTap: _openShowReasoningSelector,
        ),
        // Studio-only knobs: they shape the prompt this slot builds rather than
        // a request field the API preset could supply, so they carry no
        // override switch.
        if (_isFinal) ...[
          MenuFieldItem(
            label: 'studio_slot_settings_reasoning_history_count'.tr(),
            controller: _reasoningHistoryCountCtrl,
            placeholder: '0',
            keyboardType: const TextInputType.numberWithOptions(signed: true),
          ),
          MenuSwitchItem(
            label: 'label_exclude_reasoning_from_budget'.tr(),
            description: 'desc_exclude_reasoning_from_budget'.tr(),
            value: _excludeReasoningFromContextBudget,
            onChanged: (v) =>
                setState(() => _excludeReasoningFromContextBudget = v),
          ),
        ],
      ],
    );
  }
}
