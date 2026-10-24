import '../../../core/state/native_provider_runtime.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../models/support_app_action_context.dart';
import '../models/support_app_action_connections.dart';

/// Composition-owned native bridge, not a service which looks up Ref or keys.
final class SupportAppControlNativeConnections
    implements
        SupportAppConnectionNativePort,
        SupportAppConnectionTerminalPort {
  SupportAppControlNativeConnections({
    required this.runtime,
    required this.isOriginalRoot,
  });
  final NativeProviderRuntime runtime;
  final bool Function() isOriginalRoot;

  bool get _current =>
      isOriginalRoot() && runtime.isCurrent && isOriginalRoot();

  @override
  KeylessApiConfigTerminalEffectOwner? terminalEffects(
    ApiConfigRepo repo,
    SupportAppActionContext context,
  ) => _current && context.current
      ? KeylessApiConfigTerminalEffectOwner(
          repo: repo,
          admission: _NativeConnectionConfirmation(this, context),
        )
      : null;

  @override
  Future<SupportAppCredentialMetadata?> readCredentialMetadata(
    String connectionId,
    SupportAppActionContext context,
  ) async {
    bool current() => _current && context.current && _current;
    if (!current()) return null;
    final revision = observeRevision();
    if (revision == null || !current()) return null;
    final facts = await runtime.credentialReader.readConfiguration(
      connectionId: connectionId,
      isCurrent: () => current() && isRevisionCurrent(revision),
    );
    if (!current() || !isRevisionCurrent(revision) || facts.metadata == null) {
      return null;
    }
    return SupportAppCredentialMetadata(
      configured: facts.metadata!.configured,
      characterCount: facts.metadata!.characterCount,
    );
  }

  @override
  Object? observeRevision() =>
      _current ? runtime.keylessMutations.revisionFor('app-control') : null;

  @override
  bool isRevisionCurrent(Object revision) =>
      _current &&
      runtime.keylessMutations.revisionFor('app-control') == revision &&
      _current;

  @override
  String? standardEndpoint(
    SupportAppConnectionTemplate template,
    String model,
  ) {
    if (!_current) return null;
    final protocol = switch (template) {
      SupportAppConnectionTemplate.openaiChat => 'openai',
      SupportAppConnectionTemplate.openaiResponses => 'openai_responses',
      SupportAppConnectionTemplate.anthropic => 'anthropic',
      SupportAppConnectionTemplate.gemini => 'gemini',
      SupportAppConnectionTemplate.openrouter => 'openrouter',
    };
    return runtime.routes.standardEndpointFor(
      protocol,
      model,
      stream: true,
      useResponsesApi: template == SupportAppConnectionTemplate.openaiResponses,
    );
  }
}

/// Known constructor-owned port. Carries the original native confirmation and
/// model ROOT only; no Ref, raw key, network authority or tool callbacks.
final class _NativeConnectionConfirmation
    implements KeylessTerminalEffectAdmissionPort {
  _NativeConnectionConfirmation(this._native, this._context);
  final SupportAppControlNativeConnections _native;
  final SupportAppActionContext _context;
  @override
  bool isCurrent(KeylessApiConfigTerminalPlan plan) =>
      _native._current &&
      _context.isConfirmedTerminalPlan(plan) &&
      _native._current;
  @override
  Future<void> admit(KeylessTerminalEffectDispatch dispatch) =>
      _context.admitConnectionTerminal(dispatch);
}
