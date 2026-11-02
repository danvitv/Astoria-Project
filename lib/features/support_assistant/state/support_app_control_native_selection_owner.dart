import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/native_active_selection_port.dart';
import '../../../core/state/shared_prefs_provider.dart';

/// Capture only already-loaded producers, synchronously in the original graph.
/// Missing selections remain unavailable; asking Astoria never boots the app's
/// selection controller or plugin singleton to manufacture an owner.
Map<NativeActiveSelectionKind, NativeActiveSelectionPort>
    captureSupportNativeSelections(Ref ref, bool Function() current) {
  if (!ref.exists(sharedPreferencesProvider)) return const {};
  final loaded = ref.watch(sharedPreferencesProvider).value;
  if (loaded == null) return const {};
  final original = SavedPreferencesOwner.process.originalStore;
  final prefs = loaded is TrackedSharedPreferences ? loaded :
      original != null && original.current &&
          identical(original.actualStore, loaded)
      ? TrackedSharedPreferences.wrap(loaded) as TrackedSharedPreferences
      : null;
  if (prefs == null || !prefs.store.current) return const {};
  final ports = <NativeActiveSelectionKind, NativeActiveSelectionPort>{};
  for (final kind in NativeActiveSelectionKind.values) {
    final provider = kind == NativeActiveSelectionKind.persona
        ? activePersonaIdProvider : activePresetIdProvider;
    if (!ref.exists(provider)) continue;
    final controller = ref.read(provider.notifier);
    if (!controller.mounted) continue;
    final port = NativeActiveSelectionPort(kind: kind, controller: controller,
        preferences: prefs, isOriginalOwnerCurrent: current);
    ref.onDispose(port.dispose);
    ports[kind] = port;
  }
  return Map.unmodifiable(ports);
}
