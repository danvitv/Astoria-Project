import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../credentials/memory_custom_api_credential_owner.dart';
import '../credentials/memory_custom_api_legacy_source.dart';
import 'credential_vault_provider.dart';
import 'shared_prefs_provider.dart';

final memoryCustomApiLegacySourceProvider =
    Provider<MemoryCustomApiLegacySource>(
      (ref) => MemoryCustomApiLegacySource(
        ref.read(sharedPreferencesProvider.future),
      ),
    );

/// Native composition only; no secret is published in this provider's state.
final memoryCustomApiCredentialOwnerProvider =
    Provider<MemoryCustomApiCredentialOwner>((ref) {
      final owner = MemoryCustomApiCredentialOwner(
        vault: ref.watch(credentialVaultProvider),
        redaction: ref.watch(secretRedactionCoordinatorProvider),
        originalPreferences: ref.read(sharedPreferencesProvider.future),
        originalSource: ref.watch(memoryCustomApiLegacySourceProvider),
      );
      ref.onDispose(owner.dispose);
      return owner;
    });
