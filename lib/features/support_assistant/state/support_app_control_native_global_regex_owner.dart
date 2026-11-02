import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/native_global_regex_port.dart';

/// Synchronous capture of existing producers only. Never bootstrap regex build
/// (which normalizes/persists), hydrate prefs, or adopt a replacement controller.
NativeGlobalRegexPort? captureSupportNativeGlobalRegex(
  Ref ref,
  bool Function() current,
) {
  // exists(regex) also includes invalidated elements; reading either its value,
  // notifier or notifier.state would flush build and normalize private JSON.
  // This registry has no producer dependencies and contains only original build
  // callbacks whose onDispose guards have already retired invalidated owners.
  if (!ref.exists(nativeGlobalRegexOwnerRegistryProvider)) return null;
  final registry = ref.watch(nativeGlobalRegexOwnerRegistryProvider);
  // Exact originating-container equality only. An inherited registry/controller
  // is not authority for this graph; do not look up or read producers to renew it.
  final port = registry.capture(ref.container, current);
  if (port != null) ref.onDispose(port.dispose);
  return port;
}
