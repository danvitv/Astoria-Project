import '../../../../../core/db/models/database_maintenance.dart';
import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../models/support_app_action.dart';
import '../support_app_integrity_adapter.dart';
import '../support_app_session_repair_adapter.dart';

/// Opaque native selection custody is created from actual repository discovery,
/// not from a JSON target/plan importer or synthetic hardcoded session binding.
final class SupportNativeRepairDiscovery implements SupportAppActionAdapter {
  SupportNativeRepairDiscovery({
    required this.integrity,
    required this.sessions,
    required this.chats,
    required this.databaseTargets,
  });
  final SupportAppIntegrityAdapter integrity;
  final SupportAppSessionRepairAdapter sessions;
  final ChatRepo chats;
  final Future<List<DatabaseMaintenanceTarget>> Function() databaseTargets;
  final _sessions = <String, (SupportAppActionContext, String)>{};
  final _targets = <String, (SupportAppActionContext, String)>{};
  final _receipts = <String, (String, String)>{};
  final _databaseReceipts = <String, String>{};

  @override
  List<SupportAppActionDefinition> get definitions => [
    for (final definition in [
      ...integrity.definitions,
      ...sessions.definitions,
    ])
      if (definition.name == 'astoria_database_health')
        SupportAppActionDefinition(
          name: definition.name,
          description:
              '${definition.description} operation=discover returns native opaque eligible scalar targets; follow nextOffset for the next bounded page. Inspection retains its own offset limit.',
          risk: definition.risk,
          fields: {
            ...definition.fields,
            'offset': const SupportAppActionField.integer(
              0,
              ChatRepo.maxControlMetadataOffset,
            ),
            'operation': SupportAppActionField.choice([
              'inspect',
              'discover',
              'receipts',
            ]),
          },
        )
      else if (definition.name == 'astoria_session_integrity')
        SupportAppActionDefinition(
          name: definition.name,
          description:
              '${definition.description} Use operation=discover first for original-bound session handles; follow nextOffset for the next bounded page. Inspection offsets remain 0–63.',
          risk: definition.risk,
          fields: {
            ...definition.fields,
            'offset': const SupportAppActionField.integer(
              0,
              ChatRepo.maxControlMetadataOffset,
            ),
            'operation': SupportAppActionField.choice([
              'discover',
              'receipts',
              'inspect',
              'recordedHashes',
              'analyzeLedger',
            ]),
          },
          requiredFields: {'operation'},
        )
      else
        definition,
  ];

  String? targetSession(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) {
    if (action == 'astoria_session_repair') {
      final saved = _targets[arguments['target']];
      return saved != null && identical(saved.$1, context) ? saved.$2 : null;
    }
    if (action == 'astoria_session_repair_undo') {
      final saved = _receipts[arguments['receipt']];
      return saved != null && saved.$1 == context.sessionId ? saved.$2 : null;
    }
    return null;
  }

  void _retain<T>(Map<String, T> values, String id, T value) {
    while (values.length >= 64) {
      values.remove(values.keys.first);
    }
    values[id] = value;
  }

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (!context.current) return null;
    final suppliedOffset = arguments['offset'];
    final discovery = arguments['operation'] == 'discover';
    final offsetLimit = discovery
        ? ChatRepo.maxControlMetadataOffset
        : action == 'astoria_database_health' &&
              arguments['operation'] != 'receipts'
        ? 1024
        : 63;
    if (suppliedOffset != null &&
        (suppliedOffset is! int ||
            suppliedOffset < 0 ||
            suppliedOffset > offsetLimit)) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    if (arguments['operation'] == 'receipts' &&
        (action == 'astoria_database_health' ||
            action == 'astoria_session_integrity')) {
      if (arguments.keys.any((k) => k != 'operation' && k != 'offset')) {
        throw const SupportAppActionRefused(
          SupportAppActionCode.invalidArguments,
        );
      }
      final offset = arguments['offset'] as int? ?? 0;
      final ids = action == 'astoria_database_health'
          ? _databaseReceipts.entries
                .where((e) => e.value == context.sessionId)
                .map((e) => e.key)
                .toList()
          : _receipts.entries
                .where((e) => e.value.$1 == context.sessionId)
                .map((e) => e.key)
                .toList();
      return SupportAppPreparedAction(
        target: 'native-retained-repair-receipts',
        observation: Object(),
        observationIsCurrent: () => context.current,
        execute: (current) async => SupportAppActionOutcome(
          current()
              ? SupportAppActionCode.completed
              : SupportAppActionCode.stale,
          data: current()
              ? {
                  'records': [
                    for (final id in ids.skip(offset).take(16))
                      {'receipt': id, 'conditional': true},
                  ],
                  'count': ids.length,
                  'nextOffset': offset + 16 < ids.length ? offset + 16 : null,
                }
              : const {},
        ),
      );
    }
    if (arguments['operation'] == 'discover' &&
        (action == 'astoria_database_health' ||
            action == 'astoria_session_integrity')) {
      if (arguments.keys.any((k) => k != 'operation' && k != 'offset')) {
        throw const SupportAppActionRefused(
          SupportAppActionCode.invalidArguments,
        );
      }
      final offset = arguments['offset'] as int? ?? 0;
      final records = <Map<String, Object?>>[];
      int count;
      if (action == 'astoria_session_integrity') {
        final page = await chats.getControlSessionMetadata(
          offset: offset,
          isCurrent: () => context.current,
        );
        if (!context.current) return null;
        count = page.count;
        for (final row in page.rows) {
          final handle = sessions.bindSession(row.sessionId, context);
          _retain(_sessions, handle, (context, row.sessionId));
          records.add({
            'session': handle,
            'sessionId': row.sessionId,
            'index': row.sessionIndex,
            'messageCount': row.messageCount,
          });
        }
      } else {
        final targets = await databaseTargets();
        if (!context.current) return null;
        count = targets.length;
        for (final target in targets.skip(offset).take(16)) {
          records.add({
            'target': integrity.bindTarget(target, context),
            'kind': target.kind.name,
          });
        }
      }
      return SupportAppPreparedAction(
        target: 'native-repair-discovery',
        observation: Object(),
        observationIsCurrent: () => context.current,
        execute: (current) async => SupportAppActionOutcome(
          current()
              ? SupportAppActionCode.completed
              : SupportAppActionCode.stale,
          data: current()
              ? {
                  'records': records,
                  'count': count,
                  'nextOffset': offset + records.length < count
                      ? offset + records.length
                      : null,
                  'bodyAccess': 'notGranted',
                  'boundedDiscovery': true,
                }
              : const {},
        ),
      );
    }
    final input = Map<String, Object?>.of(arguments);
    if (action == 'astoria_database_health') input.remove('operation');
    if (action == 'astoria_session_integrity' && input['session'] is! String) {
      return null;
    }
    final analysis =
        action == 'astoria_session_integrity' &&
        input['operation'] == 'analyzeLedger';
    final binding = analysis ? _sessions[input['session']] : null;
    bool originalBinding() {
      final retained = _sessions[input['session']];
      // Records have value semantics, not stable object identity. The actual
      // original context object and its native target are the custody anchors.
      return context.current &&
          binding != null &&
          retained != null &&
          identical(binding.$1, context) &&
          identical(retained.$1, context) &&
          retained.$2 == binding.$2;
    }

    if (analysis && !originalBinding()) return null;
    final SupportAppActionAdapter underlying =
        action.startsWith('astoria_database_') ? integrity : sessions;
    final prepared = await underlying.prepare(action, input, context);
    if (prepared == null || (analysis && !originalBinding())) return null;
    return SupportAppPreparedAction(
      target: prepared.target,
      observation: prepared.observation,
      observationIsCurrent: analysis
          ? () => originalBinding() && prepared.observationIsCurrent()
          : prepared.observationIsCurrent,
      preview: prepared.preview,
      execute: (current) async {
        final result = await prepared.execute(
          analysis ? () => current() && originalBinding() : current,
        );
        if (analysis && !originalBinding()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        if (action == 'astoria_session_integrity' &&
            input['operation'] == 'inspect') {
          final session = _sessions[input['session']];
          final records = result.data['records'];
          if (session != null &&
              identical(session.$1, context) &&
              records is List) {
            for (final record in records.whereType<Map<dynamic, dynamic>>()) {
              final id = record['id'];
              if (id is String) _retain(_targets, id, (context, session.$2));
            }
          }
        }
        final receipt = result.data['receipt'];
        final target = targetSession(action, input, context);
        if (receipt is String && target != null) {
          _retain(_receipts, receipt, (context.sessionId, target));
        }
        if (receipt is String && action == 'astoria_database_repair') {
          _retain(_databaseReceipts, receipt, context.sessionId);
        }
        if (result.effect == SupportAppActionEffect.persisted &&
            result.data['outcome'] == 'undone') {
          _receipts.remove(arguments['receipt']);
          _databaseReceipts.remove(arguments['receipt']);
        }
        return result;
      },
    );
  }
}
