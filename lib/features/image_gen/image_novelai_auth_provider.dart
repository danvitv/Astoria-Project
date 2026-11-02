import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/image_novelai_credential_owner.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';

final imageNovelAiCredentialOwnerProvider =
    Provider<ImageNovelAiCredentialOwner>((ref) {
      final owner = ImageNovelAiCredentialOwner(
        vault: ref.watch(credentialVaultProvider),
        redaction: ref.watch(secretRedactionCoordinatorProvider),
        originalPreferences: ref.read(sharedPreferencesProvider.future),
      );
      ref.onDispose(owner.dispose);
      return owner;
    });

final imageNovelAiAuthProvider =
    AsyncNotifierProvider<ImageNovelAiAuthNotifier, ImageNovelAiAuthSummary>(
      ImageNovelAiAuthNotifier.new,
    );

class ImageNovelAiAuthNotifier extends AsyncNotifier<ImageNovelAiAuthSummary> {
  int _intent = 0;
  @override
  Future<ImageNovelAiAuthSummary> build() =>
      ref.watch(imageNovelAiCredentialOwnerProvider).load();

  Future<void> setApiKey(
    String input, {
    required String endpoint,
    required String model,
  }) async {
    final owner = ref.read(imageNovelAiCredentialOwnerProvider);
    final intent = ++_intent;
    final pending = owner.setApiKey(input, endpoint: endpoint, model: model);
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
