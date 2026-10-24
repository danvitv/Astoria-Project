import 'support_app_action_context.dart';
import 'support_app_action_definition.dart';

export 'support_app_action_context.dart';
export 'support_app_action_definition.dart';

enum SupportAppActionCode {
  completed,
  noChange,
  unknownAction,
  invalidArguments,
  denied,
  unavailable,
  cancelled,
  stale,
  conflict,
  storageUncertain,
  unsafeMetadata,
}

enum SupportAppActionEffect { none, persisted, navigation, uncertain }

/// Fixed domain refusal before admission; deliberately carries no exception text.
final class SupportAppActionRefused implements Exception {
  const SupportAppActionRefused(this.code);
  final SupportAppActionCode code;
}

/// Fixed safe outcome, never raw exceptions, repositories, handles or bodies.
final class SupportAppActionOutcome {
  SupportAppActionOutcome(
    this.code, {
    Map<String, Object?> data = const {},
    this.effect = SupportAppActionEffect.none,
  }) : data = SupportAppActionJson.immutable(data);
  final SupportAppActionCode code;
  final SupportAppActionEffect effect;
  final Map<String, Object?> data;
}

/// A domain-native precondition plus an actual implementation, not a tool DTO.
final class SupportAppPreparedAction {
  SupportAppPreparedAction({
    required this.target,
    required this.observation,
    required this.observationIsCurrent,
    required this.execute,
    Map<String, Object?> preview = const {},
  }) : preview = SupportAppActionJson.immutable(preview);
  final String target;
  final Object observation;
  final bool Function() observationIsCurrent;
  final Map<String, Object?> preview;
  final Future<SupportAppActionOutcome> Function(bool Function() isCurrent)
  execute;
}

/// Extend with cohesive domain adapters. Definitions are only real operations.
abstract interface class SupportAppActionAdapter {
  List<SupportAppActionDefinition> get definitions;
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  );
}

/// Required trusted metadata projection; missing policy never means unredacted.
abstract interface class SupportAppMetadataPolicy {
  String? exactText(String value, {required int maxLength});
}
