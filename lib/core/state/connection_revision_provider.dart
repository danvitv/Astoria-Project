import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../credentials/connection_revision_registry.dart';

/// One non-auto-disposed registry per native provider-container lifetime.
final connectionRevisionRegistryProvider = Provider<ConnectionRevisionRegistry>(
  (ref) {
    final registry = ConnectionRevisionRegistry();
    ref.onDispose(registry.dispose);
    return registry;
  },
);
