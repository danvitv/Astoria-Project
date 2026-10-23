import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/api_config_repo.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../services/support_provider_action_service.dart';
import '../services/support_native_runtime.dart';
import 'support_native_provider.dart';

/// The actual injected API repository's native owner, not a second DB/vault.
/// Watching stable owners deliberately excludes this action's own key/config
/// fence and redactor snapshot; every variable projection still reads CURRENT.
final supportProviderActionServiceProvider =
    Provider<SupportProviderActionService?>((ref) {
      final native = ref.watch(nativeProviderRuntimeProvider);
      if (native == null) return null;
      final api = ref.watch(apiConfigRepoProvider);
      final controller = ref.watch(supportNativeConsentControllerProvider);
      final support = ref.watch(supportRepoProvider);
      final setup = SupportProviderSetupRepo(
        db: ref.watch(appDbProvider),
        apiRepo: api,
        supportRepo: support,
      );
      var alive = true;
      bool current() =>
          alive && ref.mounted && native.isCurrent && controller.runtime.alive;
      final service = SupportProviderActionService(
        apiRepo: api,
        setupRepo: setup,
        routePolicy: native.routes,
        currentPermissions: () => controller.runtime.localPermissionSnapshot,
        currentLocalContext: () => controller.runtime.localContext,
        readPermissions: controller.runtime.permissions.readForNative,
        currentRedactor: () => ref.read(secretRedactorProvider),
        isOriginalScopeCurrent: current,
        readConnectionIds: (guard) async {
          if (!current() || !guard()) return const [];
          final ids = await api.getConfigIds();
          return current() && guard() ? ids : const [];
        },
        readReadiness: (id, purpose, guard) async {
          bool original() => current() && guard() && current();
          if (!original()) return null;
          // Native key registration precedes EVERY saved-label projection. This
          // is metadata truth, not a granted purpose, model test or network job.
          final facts = await native.credentialReader.readConfiguration(
            connectionId: id,
            isCurrent: original,
          );
          if (!original() || facts.metadata == null) return null;
          final saved = await api.getById(id);
          if (!original() || saved == null) return null;
          return SupportProviderReadiness(
            configurationSaved: true,
            credentialConfigured: facts.metadata!.configured,
            characterCount: facts.metadata!.characterCount,
          );
        },
      );
      ref.onDispose(() {
        alive = false;
        service.dispose();
      });
      return service;
    });
