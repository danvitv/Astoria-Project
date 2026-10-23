import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/theme_provider.dart';
import '../services/support_theme_action_service.dart';
import 'support_native_provider.dart';
import 'support_theme_custody_provider.dart';
import 'support_theme_ui_binding.dart';

export '../services/support_theme_action_service.dart';
export 'support_theme_custody_provider.dart';
export 'support_theme_ui_binding.dart';

final supportThemeActionServiceProvider = Provider((ref) {
  // A replacement cipher/repo retires admission, not original outcome custody.
  ref.watch(supportRepoProvider);
  final theme = ref.watch(themeProvider.notifier);
  var active = true;
  final service = SupportThemeActionService(
    runtime: ref.watch(supportNativeRuntimeProvider),
    theme: theme,
    custody: ref.watch(supportThemeActionCustodyProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    isOriginalThemeOwner: () => active,
  );
  ref.onDispose(() {
    active = false;
    service.dispose();
  });
  return service;
});

/// Native controller and action service are captured together before UI emission.
/// No recipient refresh, model selection or theme-value dependency here.
final supportThemeUiBindingProvider = Provider((ref) {
  final binding = SupportThemeUiBinding(
    service: ref.watch(supportThemeActionServiceProvider),
    controller: ref.watch(supportNativeConsentControllerProvider),
    handles: ref.watch(supportThemeOriginalHandlesProvider),
  );
  ref.onDispose(binding.dispose);
  return binding;
});

/// Rebuild signal ONLY. Consumers reproject their retained opaque handles on
/// every rebuild; neither values nor renewed approval are cached in this state.
final supportThemePresentationProvider =
    NotifierProvider<SupportThemePresentation, int>(
      SupportThemePresentation.new,
    );

class SupportThemePresentation extends Notifier<int> {
  @override
  int build() {
    final binding = ref.watch(supportThemeUiBindingProvider);
    var active = true, ready = false;
    void changed() {
      if (active && ready && ref.mounted) state++;
    }

    final stop = binding.listen(changed);
    ref.onDispose(() {
      active = false;
      stop();
    });
    ready = true;
    return 0;
  }
}
