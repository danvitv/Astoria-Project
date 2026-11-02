import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/image_openrouter_credential_owner.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';

final imageOpenRouterCredentialOwnerProvider = Provider<ImageOpenRouterCredentialOwner>((ref) {
  final owner = ImageOpenRouterCredentialOwner(
    vault: ref.watch(credentialVaultProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    originalPreferences: ref.read(sharedPreferencesProvider.future),
  );
  ref.onDispose(owner.dispose);
  return owner;
});

final imageOpenRouterAuthProvider =
    AsyncNotifierProvider<ImageOpenRouterAuthNotifier, ImageOpenRouterAuthSummary>(
      ImageOpenRouterAuthNotifier.new,
    );

class ImageOpenRouterAuthNotifier extends AsyncNotifier<ImageOpenRouterAuthSummary> {
  int _intent = 0;

  @override
  Future<ImageOpenRouterAuthSummary> build() =>
      ref.watch(imageOpenRouterCredentialOwnerProvider).load();

  Future<void> setApiKey(String input, {required String endpoint}) async {
    final owner = ref.read(imageOpenRouterCredentialOwnerProvider);
    final intent = ++_intent;
    try {
      final pending = owner.setApiKey(input, endpoint: endpoint);
      final current = owner.captureAuthPublicationGuard();
      final summary = await pending;
      if (ref.mounted && intent == _intent && current() && owner.isCurrentSummary(summary)) {
        state = AsyncData(summary);
      }
    } catch (_) {
      if (ref.mounted && intent == _intent && owner.source.current) {
        state = const AsyncData(ImageOpenRouterAuthSummary(unavailable: true));
      }
    }
  }
}
