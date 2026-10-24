import 'support_app_action_context.dart';
import '../../../core/db/repositories/api_config_repo.dart';

/// Fixed standard native destinations, not arbitrary URL/protocol inputs.
enum SupportAppConnectionTemplate {
  openaiChat,
  openaiResponses,
  anthropic,
  gemini,
  openrouter,
}

/// Metadata truth only; never proof of valid authentication or network success.
final class SupportAppCredentialMetadata {
  const SupportAppCredentialMetadata({
    required this.configured,
    required this.characterCount,
  });
  final bool configured;
  final int characterCount;
}

/// Root registers current secrets before any saved-label projection. Reads must
/// guard each await; null means unavailable, NEVER fabricated key absence.
abstract interface class SupportAppConnectionNativePort {
  Future<SupportAppCredentialMetadata?> readCredentialMetadata(
    String connectionId,
    SupportAppActionContext context,
  );
  Object? observeRevision();
  bool isRevisionCurrent(Object revision);
  String? standardEndpoint(SupportAppConnectionTemplate template, String model);
}

/// Separately available only from the actual native ROOT composition.
abstract interface class SupportAppConnectionTerminalPort {
  KeylessApiConfigTerminalEffectOwner? terminalEffects(
    ApiConfigRepo repo,
    SupportAppActionContext context,
  );
}
