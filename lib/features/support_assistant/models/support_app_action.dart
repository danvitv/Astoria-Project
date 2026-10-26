import 'support_app_action_context.dart';
import 'support_app_action_definition.dart';
import '../../../core/llm/transport/native_tool_types.dart';

export 'support_app_action_context.dart';
export 'support_app_action_definition.dart';
export 'support_source_tool_names.dart';

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

/// Optional exact projection only for explicitly declared supplied-new-content
/// strings. Metadata-only implementations remain valid and fail closed for bodies.
abstract interface class SupportAppBodyMetadataPolicy {
  String? exactBodyText(String value, {required int maxLength});
}

/// Exact approved body outcome only. The original model source run implements
/// this port; generic adapters and metadata policy cannot widen result strings.
abstract interface class SupportAppSourceBodyResultPort {
  bool acceptsSourceBodyOutcome(
    NativeToolCall call,
    SupportAppActionOutcome outcome,
  );
}

/// Original-run source adapters may own the native scope dialogue themselves.
/// The registry accepts this only from its identical registered source port;
/// model arguments cannot implement it or waive native UI/result custody.
abstract interface class SupportAppNativeSourceApprovalPort {
  bool ownsOriginalSourceApproval(
    String action,
    SupportAppActionContext original,
  );
}
