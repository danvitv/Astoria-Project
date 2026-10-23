import 'package:flutter/foundation.dart';

import 'support_provider_values.dart';

/// Fixed native facts. Uncertain delivery is not proof that no row was saved.
enum SupportProviderActionCode {
  applied,
  undone,
  undoConflict,
  refused,
  storageUncertain,
}

@immutable
final class SupportProviderActionView {
  const SupportProviderActionView({required this.code, required this.preview});
  final SupportProviderActionCode code;
  final SupportProviderSetupPreview? preview;
}
