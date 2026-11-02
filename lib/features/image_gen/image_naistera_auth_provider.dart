import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/image_naistera_credential_owner.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';

final imageNaisteraCredentialOwnerProvider =
    Provider<ImageNaisteraCredentialOwner>((ref) {
      final owner = ImageNaisteraCredentialOwner(
        vault: ref.watch(credentialVaultProvider),
        redaction: ref.watch(secretRedactionCoordinatorProvider),
        originalPreferences: ref.read(sharedPreferencesProvider.future),
      );
      ref.onDispose(owner.dispose);
      return owner;
    });
final imageNaisteraAuthProvider =
    AsyncNotifierProvider<ImageNaisteraAuthNotifier, ImageNaisteraAuthSummary>(
      ImageNaisteraAuthNotifier.new,
    );

class ImageNaisteraAuthNotifier
    extends AsyncNotifier<ImageNaisteraAuthSummary> {
  int _intent = 0;
  @override
  Future<ImageNaisteraAuthSummary> build() =>
      ref.watch(imageNaisteraCredentialOwnerProvider).load();
  Future<void> setApiKey(String input) async {
    final owner = ref.read(imageNaisteraCredentialOwnerProvider);
    final intent = ++_intent;
    final pending = owner.setApiKey(input);
    final current = owner.captureAuthPublicationGuard();
    final summary = await pending;
    if (ref.mounted &&
        intent == _intent &&
        current() &&
        owner.isCurrentSummary(summary)) {
      state = AsyncData(summary);
    }
  }
}
