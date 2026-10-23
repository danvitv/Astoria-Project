import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../services/support_connection_metadata_service.dart';
import '../services/support_workspace_store.dart';

/// Explicit native API/settings chooser metadata, not assistant authorization.
final supportConnectionMetadataProvider = FutureProvider((ref) {
  final api = ref.watch(apiConfigRepoProvider);
  final native = ref.watch(nativeProviderRuntimeProvider);
  bool current() =>
      ref.mounted &&
      (native == null ||
          (native.isCurrent &&
              identical(native, ref.read(nativeProviderRuntimeProvider))));
  return SupportConnectionMetadataService(
    api,
    () => ref.read(secretRedactorProvider),
    nativeMetadata: native?.credentialReader,
    nativeMetadataIsCurrent: current,
  ).load(isCurrent: current);
});
final supportConnectionsProvider = Provider<List<ApiConnectionMetadata>>(
  (ref) =>
      ref.watch(supportConnectionMetadataProvider).asData?.value ?? const [],
);
final supportSessionStoreProvider = Provider(
  (ref) => SupportWorkspaceStore(
    ref.watch(supportRepoProvider),
    () => ref.read(secretRedactorProvider),
  ),
);
