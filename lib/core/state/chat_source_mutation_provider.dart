import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_source_mutation_registry.dart';

/// Primitive owner only: evaluating this provider never evaluates a feature,
/// database, credential, configuration, or model provider.
final chatSourceMutationRegistryProvider = Provider<ChatSourceMutationRegistry>(
  (ref) {
    final registry = ChatSourceMutationRegistry();
    ref.onDispose(registry.dispose);
    return registry;
  },
);
