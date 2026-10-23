import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import 'support_model_workspace_binding.dart';
import 'support_model_write_custody.dart';

/// These ports have NO default DB/bootstrap dependencies. Existing local-only
/// workspaces can attach deletion/display barriers without appDb/credential startup.
final supportModelDurableWritesProvider = Provider(
  (ref) => SupportModelDurableWrites(),
);
final supportModelWorkspaceBindingProvider = Provider((ref) {
  final binding = SupportModelWorkspaceBinding();
  ref.onDispose(binding.dispose);
  return binding;
});

/// appDb destruction/replacement is the ONLY reactive settlement revocation.
/// Cipher, API, registry, selected workspace and UI issuer rebuilds are not it.
final supportModelDatabaseCustodyProvider = Provider((ref) {
  ref.watch(appDbProvider);
  final custody = SupportModelDatabaseCustody(
    ref.watch(supportModelDurableWritesProvider),
  );
  ref.onDispose(custody.revoke);
  return custody;
});
