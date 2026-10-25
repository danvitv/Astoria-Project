import 'dart:io';

import '../../models/support_app_action.dart';

/// A factual offline entry hint, not restore authority or a scheduled operation.
/// This adapter has no database, file picker, vault, process or write port.
final class SupportDatabaseRestorePrepareAdapter
    implements SupportAppActionAdapter {
  const SupportDatabaseRestorePrepareAdapter();

  static const action = 'astoria_database_restore_prepare';

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: action,
      description:
          'Explain offline whole-database recovery availability. No arguments; '
          'does not restore, select a file, schedule or restart the application.',
      risk: SupportAppActionRisk.metadata,
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != SupportDatabaseRestorePrepareAdapter.action ||
        arguments.isNotEmpty ||
        !context.current) {
      return null;
    }
    return SupportAppPreparedAction(
      target: 'offlineDatabaseRecovery',
      observation: this,
      observationIsCurrent: () => context.current,
      execute: (current) async {
        if (!current()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        return SupportAppActionOutcome(
          SupportAppActionCode.unavailable,
          data: {
            'status': Platform.isWindows ? 'restartRequired' : 'unsupported',
            'restore': 'noRestore',
          },
        );
      },
    );
  }
}
