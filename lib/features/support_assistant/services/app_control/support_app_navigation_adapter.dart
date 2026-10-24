import '../../models/support_app_action.dart';

/// Navigation is explicitly not a domain mutation or a completed user task.
final class SupportAppNavigationAdapter implements SupportAppActionAdapter {
  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_navigate',
      description:
          'Open a finite application destination; navigation does not edit its data.',
      risk: SupportAppActionRisk.navigation,
      fields: {
        'destination': SupportAppActionField.choice(
          SupportAppDestination.values.map((d) => d.name),
        ),
      },
      requiredFields: {'destination'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final port = context.navigation;
    if (port == null || !context.current) return null;
    final destination = SupportAppDestination.values.byName(
      arguments['destination']! as String,
    );
    return SupportAppPreparedAction(
      target: destination.name,
      observation: port,
      observationIsCurrent: () => context.current,
      execute: (current) async {
        if (!current()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        final opened = await port.open(destination, context);
        if (!current()) {
          return SupportAppActionOutcome(
            SupportAppActionCode.stale,
            effect: opened
                ? SupportAppActionEffect.navigation
                : SupportAppActionEffect.none,
          );
        }
        return SupportAppActionOutcome(
          opened ? SupportAppActionCode.completed : SupportAppActionCode.denied,
          effect: opened
              ? SupportAppActionEffect.navigation
              : SupportAppActionEffect.none,
          data: opened ? {'destination': destination.name} : const {},
        );
      },
    );
  }
}
