import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../services/support_theme_action_service.dart';
import 'support_theme_original_handles.dart';

/// One original repository/cipher and live-job registry for this DB lifetime.
/// Reading the repo here deliberately does NOT subscribe to cipher replacement.
/// Admission providers do subscribe and retire; started jobs retain this owner.
final supportThemeActionCustodyProvider = Provider((ref) {
  ref.watch(appDbProvider);
  var originalDbAlive = true;
  final custody = SupportThemeActionCustody(
    repo: ref.read(supportRepoProvider),
    hasOriginalDbCustody: () => originalDbAlive,
  );
  ref.onDispose(() => originalDbAlive = false);
  return custody;
});

final supportThemeOriginalHandlesProvider = Provider((ref) {
  ref.watch(supportThemeActionCustodyProvider);
  final handles = SupportThemeOriginalHandles();
  ref.onDispose(handles.dispose);
  return handles;
});
