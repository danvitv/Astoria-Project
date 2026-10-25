import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../services/app_control/support_app_action_registry.dart';
import '../services/app_control/support_app_connections_adapter.dart';
import '../services/app_control/support_app_metadata_policy.dart';
import '../services/app_control/support_app_navigation_adapter.dart';
import '../services/app_control/support_app_preferences_adapter.dart';
import '../services/app_control/support_app_theme_adapter.dart';
import '../services/app_control/support_database_restore_prepare_adapter.dart';
import 'support_app_control_connections_provider.dart';
import 'support_app_control_native_domain_provider.dart';
import 'support_app_control_backup_provider.dart';

export '../models/support_app_action.dart';
export '../services/app_control/support_app_action_registry.dart';

/// Actual Ref lives only here. Per-run confirmation/navigation/source authority
/// is supplied later by the original model-run owner, never fabricated here.
final supportAppActionRegistryProvider = Provider<SupportAppActionRegistry>((
  ref,
) {
  final api = ref.watch(apiConfigRepoProvider);
  final native = ref.watch(nativeProviderRuntimeProvider);
  final settings = ref.watch(appSettingsProvider.notifier);
  final theme = ref.watch(themeProvider.notifier);
  var alive = true;
  bool current() =>
      alive && ref.mounted && (native == null || native.isCurrent);
  ref.onDispose(() => alive = false);
  return SupportAppActionRegistry(
    metadata: SupportAppRedactedMetadataPolicy(
      currentRedactor: () => ref.read(secretRedactorProvider),
    ),
    isOriginalOwnerCurrent: current,
    adapters: [
      SupportAppPreferencesAdapter(
        notifier: settings,
        readReady: () => ref.read(appSettingsProvider.future),
        currentSettings: () => ref.read(appSettingsProvider).value,
      ),
      SupportAppThemeAdapter(theme: theme),
      if (native != null)
        SupportAppConnectionsAdapter(
          repo: api,
          native: SupportAppControlNativeConnections(
            runtime: native,
            isOriginalRoot: current,
          ),
        ),
      SupportAppNavigationAdapter(),
      const SupportDatabaseRestorePrepareAdapter(),
      ...ref.watch(supportAppNativeDomainAdaptersProvider),
      // Default graph is finite but has no backup file/source authority. The
      // original service binds ONLY this adapter through withNativeBackup.
      SupportDatabaseBackupAdapter(
        native: null,
        originalSource: () => null,
        isOriginalOwnerCurrent: current,
      ),
    ],
  );
});
