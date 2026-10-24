import '../../../../core/llm/transport/native_tool_types.dart';
import '../../models/support_app_action.dart';

/// Strict typed gateway. No model-supplied routes, callbacks or general commands.
final class SupportAppActionRegistry {
  SupportAppActionRegistry({
    required Iterable<SupportAppActionAdapter> adapters,
    required this.metadata,
    required this.isOriginalOwnerCurrent,
  }) {
    for (final adapter in adapters) {
      for (final definition in adapter.definitions) {
        if (_actions.containsKey(definition.name)) {
          throw ArgumentError('Duplicate application action.');
        }
        _actions[definition.name] = (adapter, definition);
      }
    }
  }

  final SupportAppMetadataPolicy metadata;
  final bool Function() isOriginalOwnerCurrent;
  final _actions =
      <String, (SupportAppActionAdapter, SupportAppActionDefinition)>{};
  bool _busy = false;

  List<NativeToolDefinition> get definitions =>
      List.unmodifiable(_actions.values.map((a) => a.$2.native));

  Future<NativeToolResult> execute(
    NativeToolCall call,
    SupportAppActionContext context,
  ) async {
    var ownerRetired = false;
    bool current() {
      if (ownerRetired || !context.current) return false;
      try {
        if (!isOriginalOwnerCurrent() || !context.current) ownerRetired = true;
      } catch (_) {
        ownerRetired = true;
      }
      return !ownerRetired;
    }

    SupportAppActionOutcome interrupted([SupportAppActionEffect? effect]) =>
        SupportAppActionOutcome(
          context.cancelToken.isCancelled
              ? SupportAppActionCode.cancelled
              : SupportAppActionCode.stale,
          effect: effect ?? SupportAppActionEffect.none,
        );
    if (_busy) throw const NativeToolException(NativeToolReason.denied);
    _busy = true; // Before any injected/reentrant callback.
    var identitySafe = false;
    var effect = SupportAppActionEffect.none;
    var effectMayHaveStarted = false;
    try {
      // Identity must be correlated OR refused without echo. A known secret
      // cannot be returned as an ID/name even with valid provider syntax.
      identitySafe =
          metadata.exactText(call.id, maxLength: 128) == call.id &&
          metadata.exactText(call.name, maxLength: 64) == call.name;
      if (!identitySafe) {
        throw const NativeToolException(NativeToolReason.denied);
      }
      if (!current()) return _result(call, interrupted());
      final registered = _actions[call.name];
      if (registered == null) {
        return _result(
          call,
          SupportAppActionOutcome(SupportAppActionCode.unknownAction),
        );
      }
      final (adapter, definition) = registered;
      if (!definition.accepts(call.arguments)) {
        return _result(
          call,
          SupportAppActionOutcome(SupportAppActionCode.invalidArguments),
        );
      }
      if (!_safeJson(call.arguments) || !current()) {
        return _result(
          call,
          current()
              ? SupportAppActionOutcome(SupportAppActionCode.unsafeMetadata)
              : interrupted(),
        );
      }
      final risk = definition.risk;
      if (risk == SupportAppActionRisk.reversiblePreference &&
          !context.allowReversibleChanges) {
        return _result(
          call,
          SupportAppActionOutcome(SupportAppActionCode.denied),
        );
      }
      if (risk == SupportAppActionRisk.bodyRead &&
              context.sourceAccess == null ||
          risk == SupportAppActionRisk.navigation &&
              context.navigation == null ||
          _needsConfirmation(risk) && context.confirmation == null) {
        return _result(
          call,
          SupportAppActionOutcome(SupportAppActionCode.unavailable),
        );
      }
      final arguments = Map<String, Object?>.unmodifiable(call.arguments);
      final prepared = await adapter.prepare(call.name, arguments, context);
      if (!current()) return _result(call, interrupted());
      if (prepared == null) {
        return _result(
          call,
          SupportAppActionOutcome(SupportAppActionCode.unavailable),
        );
      }
      if (!prepared.observationIsCurrent() || !current()) {
        return _result(
          call,
          current()
              ? SupportAppActionOutcome(SupportAppActionCode.conflict)
              : interrupted(),
        );
      }
      SupportAppConfirmationLease? lease;
      if (_needsConfirmation(risk)) {
        if (!_safeJson(prepared.preview) || !current()) {
          return _result(
            call,
            SupportAppActionOutcome(SupportAppActionCode.unsafeMetadata),
          );
        }
        final request = SupportAppConfirmationRequest(
          context: context,
          callId: call.id,
          action: call.name,
          target: prepared.target,
          arguments: arguments,
          observation: prepared.observation,
          observationIsCurrent: prepared.observationIsCurrent,
          preview: prepared.preview,
        );
        lease = await context.confirmation!.confirm(request);
        if (!current()) return _result(call, interrupted());
        if (lease == null || !lease.accept(request) || !current()) {
          return _result(
            call,
            SupportAppActionOutcome(SupportAppActionCode.denied),
          );
        }
      }
      bool admitted() =>
          current() && (lease == null || lease.current) && current();
      if (!prepared.observationIsCurrent() || !admitted()) {
        return _result(
          call,
          admitted()
              ? SupportAppActionOutcome(SupportAppActionCode.conflict)
              : interrupted(),
        );
      }
      effectMayHaveStarted = true;
      final outcome = await prepared.execute(admitted);
      effect = outcome.effect;
      // A known durable effect is not erased by Stop; no data/continuation is
      // published to a replacement run. Unknown completion is never retried.
      if (!current()) return _result(call, interrupted(effect));
      if (!_safeJson(outcome.data) || !current()) {
        return _result(
          call,
          SupportAppActionOutcome(
            SupportAppActionCode.unsafeMetadata,
            effect: effect,
          ),
        );
      }
      return _result(call, outcome);
    } on SupportAppActionRefused catch (refusal) {
      return _result(call, SupportAppActionOutcome(refusal.code));
    } catch (_) {
      if (!identitySafe) {
        throw const NativeToolException(NativeToolReason.denied);
      }
      return _result(
        call,
        SupportAppActionOutcome(
          current()
              ? SupportAppActionCode.storageUncertain
              : context.cancelToken.isCancelled
              ? SupportAppActionCode.cancelled
              : SupportAppActionCode.stale,
          effect: effect == SupportAppActionEffect.none && effectMayHaveStarted
              ? SupportAppActionEffect.uncertain
              : effect,
        ),
      );
    } finally {
      _busy = false;
    }
  }

  bool _safeJson(Object? value, [int depth = 0]) {
    if (depth > 4) return false;
    if (value == null || value is bool || value is int) return true;
    if (value is num) return value.isFinite;
    if (value is String) {
      return value.length <= 256 &&
          metadata.exactText(value, maxLength: 256) == value;
    }
    if (value is List) {
      return value.length <= 32 && value.every((v) => _safeJson(v, depth + 1));
    }
    if (value is Map<String, Object?>) {
      return value.length <= 32 &&
          value.entries.every(
            (e) => _safeJson(e.key, depth + 1) && _safeJson(e.value, depth + 1),
          );
    }
    return false;
  }

  bool _needsConfirmation(SupportAppActionRisk risk) => switch (risk) {
    SupportAppActionRisk.metadata ||
    SupportAppActionRisk.reversiblePreference ||
    SupportAppActionRisk.navigation ||
    SupportAppActionRisk.bodyRead => false,
    _ => true,
  };

  NativeToolResult _result(
    NativeToolCall call,
    SupportAppActionOutcome outcome,
  ) {
    // Native metadata reads can register new secrets after initial admission.
    if (metadata.exactText(call.id, maxLength: 128) != call.id ||
        metadata.exactText(call.name, maxLength: 64) != call.name) {
      throw const NativeToolException(NativeToolReason.denied);
    }
    if (!_safeJson(outcome.data)) {
      outcome = SupportAppActionOutcome(
        SupportAppActionCode.unsafeMetadata,
        effect: outcome.effect,
      );
    }
    return NativeToolResult(
      callId: call.id,
      name: call.name,
      content: {
        'ok':
            outcome.code == SupportAppActionCode.completed ||
            outcome.code == SupportAppActionCode.noChange,
        'code': outcome.code.name,
        'effect': outcome.effect.name,
        'data': outcome.data,
      },
    );
  }
}
