import '../../../../shared/theme/theme_provider.dart';
import '../../models/support_app_action.dart';

/// Uses the actual theme queue/fresh store/CAS, never the native UI approve API.
final class SupportAppThemeAdapter implements SupportAppActionAdapter {
  SupportAppThemeAdapter({required this.theme});
  final ThemeNotifier theme;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_themes_list',
      description:
          'List up to 32 installed theme IDs/names/modes and current selection.',
      risk: SupportAppActionRisk.metadata,
    ),
    SupportAppActionDefinition(
      name: 'astoria_theme_select',
      description:
          'Select an installed theme with fresh native observation and persistence.',
      risk: SupportAppActionRisk.reversiblePreference,
      fields: {'themeId': const SupportAppActionField.text(128)},
      requiredFields: {'themeId'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_theme_mode_set',
      description:
          'Persist light/dark/system mode on the current installed theme.',
      risk: SupportAppActionRisk.reversiblePreference,
      fields: {
        'mode': SupportAppActionField.choice(['light', 'dark', 'system']),
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
    final read = await theme.observeInstalledThemes(
      isCurrent: () => context.current,
    );
    if (!context.current) return null;
    final observation = read.observation;
    if (observation == null) return null;
    if (action == 'astoria_themes_list') {
      return SupportAppPreparedAction(
        target: 'installed-themes',
        observation: observation,
        observationIsCurrent: () => context.current,
        execute: (current) async => current()
            ? SupportAppActionOutcome(
                SupportAppActionCode.completed,
                data: {
                  'activeThemeId': observation.active.id,
                  'themes': observation.installed
                      .take(32)
                      .map(_project)
                      .toList(),
                  'truncated': observation.installed.length > 32,
                },
              )
            : SupportAppActionOutcome(SupportAppActionCode.stale),
      );
    }
    final plan = action == 'astoria_theme_select'
        ? observation.planFor(arguments['themeId']! as String)
        : observation.planForMode(arguments['mode']! as String);
    if (plan == null) return null;
    return SupportAppPreparedAction(
      target: plan.after.id,
      observation: plan,
      // Domain's opaque plan owns real revision, preimage and ABA checks inside
      // applyInstalledSelection, including queued writes and callback reentry.
      observationIsCurrent: () => context.current,
      execute: (current) async {
        if (!current()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        final result = await theme.applyInstalledSelection(
          plan,
          isCurrent: current,
        );
        final applied = result.code == ThemeSelectionCode.applied;
        if (!current()) {
          return SupportAppActionOutcome(
            SupportAppActionCode.stale,
            effect: applied
                ? SupportAppActionEffect.persisted
                : result.effectStarted
                ? SupportAppActionEffect.uncertain
                : SupportAppActionEffect.none,
          );
        }
        if (applied) {
          await theme.flushPersistence();
          if (!current()) {
            return SupportAppActionOutcome(
              SupportAppActionCode.stale,
              effect: SupportAppActionEffect.persisted,
            );
          }
        }
        return SupportAppActionOutcome(
          applied
              ? SupportAppActionCode.completed
              : result.code == ThemeSelectionCode.noOp
              ? SupportAppActionCode.noChange
              : result.effectStarted
              ? SupportAppActionCode.storageUncertain
              : SupportAppActionCode.conflict,
          effect: applied
              ? SupportAppActionEffect.persisted
              : result.effectStarted
              ? SupportAppActionEffect.uncertain
              : SupportAppActionEffect.none,
          data: applied || result.code == ThemeSelectionCode.noOp
              ? _project(plan.after)
              : {'themeStatus': result.code.name},
        );
      },
    );
  }

  Map<String, Object?> _project(ThemeSelectionDisplay display) => {
    'id': display.id,
    'name': display.name,
    'mode': display.mode,
  };
}
