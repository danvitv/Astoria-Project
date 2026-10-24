import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../../../core/db/repositories/memory_catalog_repo.dart';
import '../../../../../core/db/repositories/session_canon_checkpoint_repo.dart';
import '../../../models/support_app_action.dart';
import 'session_memory_guard.dart';

/// Bounded actual repo reads. Captures, prose, errors and integrity hashes never
/// enter the tool projection; checkpoint inspection never runs reconciliation.
final class SupportAppSessionDiagnosticsAdapter
    implements SupportAppActionAdapter {
  SupportAppSessionDiagnosticsAdapter({
    required this.chats,
    required this.captures,
    required this.catalog,
    required this.checkpoints,
    required this.reconciliation,
    required this.guard,
  });
  final ChatRepo chats;
  final LlmRequestCaptureRepo captures;
  final MemoryCatalogRepo catalog;
  final SessionCanonCheckpointRepo checkpoints;
  final LedgerReconciliationCheckpointRepo reconciliation;
  final SessionMemoryGuard guard;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_session_diagnostics',
      description:
          'Read safe session diagnostic counts: at most 32 newest '
          'request captures/events, local catalog rows, or canon/reconciliation '
          'checkpoint counts. No captures, prose, hashes, errors, repair or reset.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'view': SupportAppActionField.choice([
          'requests',
          'catalog',
          'checkpoints',
        ]),
      },
      requiredFields: {'sessionId', 'view'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != definitions.single.name ||
        !definitions.single.accepts(arguments))
      return null;
    final id = arguments['sessionId']! as String;
    final valid = guard.observe(id, context);
    if (valid == null) return null;
    final session = await chats.getById(id);
    if (session == null || !valid()) return null;
    Map<String, Object?> data;
    switch (arguments['view']) {
      case 'requests':
        final rows = await captures.newestForSession(id, limit: 32);
        if (!valid()) return null;
        final events = await captures.newestCallEventsForSession(id, limit: 32);
        if (!valid()) return null;
        data = {
          'captureSampleCount': rows.length,
          'truncatedSampleCount': rows.where((r) => r.truncated).length,
          'eventSampleCount': events.length,
          'sampleLimit': 32,
        };
        break;
      case 'catalog':
        final rows = await catalog.getBySessionId(id);
        if (!valid()) return null;
        data = {
          'catalogRowCount': rows.length,
          'staleRowCount': rows.where((r) => r.stale).length,
        };
        break;
      case 'checkpoints':
        final rows = await checkpoints.getForSession(id);
        if (!valid()) return null;
        final checkpoint = await reconciliation.get(id);
        if (!valid()) return null;
        data = {
          'canonCheckpointCount': rows.length,
          'hasReconciliationCheckpoint': checkpoint != null,
          'reconciliationSourceCount': checkpoint?.messageIds.length ?? 0,
        };
        break;
      default:
        return null;
    }
    return SupportAppPreparedAction(
      target: id,
      observation: Object(),
      observationIsCurrent: valid,
      execute: (current) async => current() && valid()
          ? SupportAppActionOutcome(SupportAppActionCode.completed, data: data)
          : SessionMemoryGuard.interrupted(context),
    );
  }
}
