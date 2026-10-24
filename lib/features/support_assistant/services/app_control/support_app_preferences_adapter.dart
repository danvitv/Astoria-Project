import '../../../settings/app_settings_provider.dart';
import '../../models/support_app_action.dart';

/// Safe scalar patch only. User prompts, extraction/auth/script policy excluded.
final class SupportAppPreferencesAdapter implements SupportAppActionAdapter {
  SupportAppPreferencesAdapter({
    required this.notifier,
    required this.readReady,
    required this.currentSettings,
  });
  final AppSettingsNotifier notifier;
  final Future<AppSettings> Function() readReady;
  final AppSettings? Function() currentSettings;

  static const _boolean = SupportAppActionField.boolean();
  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_preferences_read',
      description:
          'Read safe global UI preferences, not prompts or private settings.',
      risk: SupportAppActionRisk.metadata,
    ),
    SupportAppActionDefinition(
      name: 'astoria_preferences_update',
      description:
          'Persist only supplied reversible global UI scalar preferences.',
      risk: SupportAppActionRisk.reversiblePreference,
      requireAnyField: true,
      fields: {
        'enterToSend': _boolean,
        'hideMessageId': _boolean,
        'hideGenerationTime': _boolean,
        'hideTokenCount': _boolean,
        'groupDialogs': _boolean,
        'hideTooltips': _boolean,
        'disableSwipeRegeneration': _boolean,
        'virtualKeyboardSend': _boolean,
        'forceMobileLayout': _boolean,
        'hapticFeedback': _boolean,
        'messageVibration': _boolean,
        'hideContextCard': _boolean,
        'chatMaxWidth': const SupportAppActionField.number(0, 2400),
      },
    ),
    SupportAppActionDefinition(
      name: 'astoria_battery_saver_set',
      description:
          'Persist Battery Saver UI mode: on, off, or follow the system.',
      risk: SupportAppActionRisk.reversiblePreference,
      fields: {
        'mode': SupportAppActionField.choice(['system', 'on', 'off']),
      },
      requiredFields: {'mode'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (!context.current) return null;
    try {
      await readReady();
    } catch (_) {
      return null;
    }
    if (!context.current) return null;
    final before = currentSettings();
    if (before == null || !context.current) return null;
    if (!{
      'astoria_preferences_read',
      'astoria_preferences_update',
      'astoria_battery_saver_set',
    }.contains(action)) {
      return null;
    }
    final patch = action == 'astoria_battery_saver_set'
        ? <String, Object?>{'batterySaverMode': arguments['mode']}
        : arguments;
    final observed = _project(before);
    final selected = action == 'astoria_preferences_read'
        ? observed.keys.toSet()
        : patch.keys.toSet();
    if (selected.contains('batterySaverMode')) selected.add('batterySaver');
    bool matches() {
      final actual = currentSettings();
      if (actual == null) return false;
      final projected = _project(actual);
      return selected.every((key) => projected[key] == observed[key]);
    }

    return SupportAppPreparedAction(
      target: 'global-ui-preferences',
      observation: before,
      observationIsCurrent: () =>
          context.current && matches() && context.current,
      execute: (current) async {
        if (!current() || !matches() || !current()) {
          return SupportAppActionOutcome(SupportAppActionCode.conflict);
        }
        if (action == 'astoria_preferences_read') {
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: _project(currentSettings()!),
          );
        }
        final result = await notifier.patchUiPreferences(
          expected: before,
          values: patch,
          isCurrent: current,
        );
        final effect = switch (result.effect) {
          AppSettingsPatchEffect.none => SupportAppActionEffect.none,
          AppSettingsPatchEffect.persisted => SupportAppActionEffect.persisted,
          AppSettingsPatchEffect.uncertain => SupportAppActionEffect.uncertain,
        };
        if (!current()) {
          return SupportAppActionOutcome(
            SupportAppActionCode.stale,
            effect: effect,
          );
        }
        final after = result.settings;
        return SupportAppActionOutcome(
          switch (result.code) {
            AppSettingsPatchCode.completed => SupportAppActionCode.completed,
            AppSettingsPatchCode.noChange => SupportAppActionCode.noChange,
            AppSettingsPatchCode.stale => SupportAppActionCode.stale,
            AppSettingsPatchCode.conflict => SupportAppActionCode.conflict,
            AppSettingsPatchCode.unavailable =>
              SupportAppActionCode.unavailable,
            AppSettingsPatchCode.storageUncertain =>
              SupportAppActionCode.storageUncertain,
          },
          effect: effect,
          data: after == null
              ? const {}
              : action == 'astoria_battery_saver_set'
              ? {
                  'mode': after.batterySaverMode.name,
                  'resolved': after.batterySaver,
                }
              : _project(after),
        );
      },
    );
  }

  Map<String, Object?> _project(AppSettings s) => {
    'enterToSend': s.enterToSend,
    'hideMessageId': s.hideMessageId,
    'hideGenerationTime': s.hideGenerationTime,
    'hideTokenCount': s.hideTokenCount,
    'groupDialogs': s.groupDialogs,
    'hideTooltips': s.hideTooltips,
    'disableSwipeRegeneration': s.disableSwipeRegeneration,
    'virtualKeyboardSend': s.virtualKeyboardSend,
    'forceMobileLayout': s.forceMobileLayout,
    'hapticFeedback': s.hapticFeedback,
    'messageVibration': s.messageVibration,
    'hideContextCard': s.hideContextCard,
    'chatMaxWidth': s.chatMaxWidth,
    'batterySaverMode': s.batterySaverMode.name,
    'batterySaver': s.batterySaver,
  };
}
