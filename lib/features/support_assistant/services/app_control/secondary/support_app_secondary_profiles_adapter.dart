import '../../../models/support_app_action.dart';

enum SupportAppSecondaryProfileDomain { globalRegex, studioRegex, image }

/// Finite projection of already-loaded native state; no text, patterns,
/// workflows, prompts, labels, image paths, provider endpoints or credentials.
final class SupportAppSecondaryProfileFacts {
  const SupportAppSecondaryProfileFacts({
    required this.domain,
    required this.nativeObservation,
    required this.count,
    required this.enabledCount,
    this.bindingCount = 0,
    this.styles = 0,
    this.workflows = 0,
    this.enabled = false,
    this.concurrent = false,
  });
  final SupportAppSecondaryProfileDomain domain;
  final Object nativeObservation;
  final int count, enabledCount, bindingCount, styles, workflows;
  final bool enabled, concurrent;
}

abstract interface class SupportAppSecondaryProfilesPort {
  SupportAppSecondaryProfileFacts? observe(
    SupportAppSecondaryProfileDomain domain,
  );
  bool isCurrent(SupportAppSecondaryProfileFacts facts);
}

/// No editing/activation definitions: existing regex/image preference owners
/// do not yet provide durable latest-state CAS. Do not emulate it here.
final class SupportAppSecondaryProfilesAdapter
    implements SupportAppActionAdapter {
  const SupportAppSecondaryProfilesAdapter(this.native);
  final SupportAppSecondaryProfilesPort native;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_secondary_profiles_read',
      description:
          'Read finite counts from already-loaded global regex, Studio '
          'regex or image profiles. No private text, source, paths or keys. '
          'This does not enable, execute, generate, probe or edit anything.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'domain': SupportAppActionField.choice(
          SupportAppSecondaryProfileDomain.values.map((v) => v.name),
        ),
      },
      requiredFields: {'domain'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != 'astoria_secondary_profiles_read' || !context.current) {
      return null;
    }
    if (!definitions.single.accepts(arguments)) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final domain = SupportAppSecondaryProfileDomain.values.singleWhere(
      (v) => v.name == arguments['domain'],
    );
    final facts = native.observe(domain);
    if (facts == null || facts.domain != domain || !context.current) {
      return null;
    }
    return SupportAppPreparedAction(
      target: 'secondary-${domain.name}-metadata',
      observation: facts.nativeObservation,
      observationIsCurrent: () => context.current && native.isCurrent(facts),
      execute: (current) async {
        if (!current() || !native.isCurrent(facts) || !current()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        return SupportAppActionOutcome(
          SupportAppActionCode.completed,
          data: {
            'domain': domain.name,
            if (domain != SupportAppSecondaryProfileDomain.image) ...{
              'scriptCount': facts.count,
              'enabledCount': facts.enabledCount,
              'stageBindingCount': facts.bindingCount,
            } else ...{
              'enabled': facts.enabled,
              'concurrentGeneration': facts.concurrent,
              'referenceCount': facts.count,
              'enabledReferenceCount': facts.enabledCount,
              'styleCount': facts.styles,
              'workflowCount': facts.workflows,
              'credentialValidity': 'unknown',
            },
            'activationControlAvailable': false,
            'generationAvailable': false,
          },
        );
      },
    );
  }
}
