import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/provider_model_catalog.dart';
import '../../../core/state/db_provider.dart';

/// The existing repository-owned native runtime; no second vault or HTTP client.
final supportModelCatalogProvider = Provider<ProviderModelCatalog?>((ref) {
  return ref.watch(nativeProviderRuntimeProvider)?.models;
});
