import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../services/support_connection_metadata_service.dart';
import '../services/support_workspace_store.dart';

/// Explicit native API/settings chooser metadata, not assistant authorization.
final supportConnectionMetadataProvider = FutureProvider(
  (ref) => SupportConnectionMetadataService(
    ref.watch(apiConfigRepoProvider),
    () => ref.read(secretRedactorProvider),
  ).load(),
);
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
