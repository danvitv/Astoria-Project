import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_repair_provider.dart';

import '../../db/database_maintenance/maintenance_fixture.dart';
import '../../db/session_repair/session_repair_fixture.dart';

export 'package:glaze_flutter/core/db/models/database_maintenance.dart';
export 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
export '../../db/database_maintenance/maintenance_fixture.dart';
export '../../db/session_repair/session_repair_fixture.dart';

final repairGatewayNativeStateProvider =
    NotifierProvider<RepairGatewayNativeState, int>(
      () => throw StateError(
        'Synthetic native state must be explicitly injected.',
      ),
    );

/// Existing production memory SQLite + FakeVault + real AEAD + native/file/HTTP
/// tripwires. This cohort does not start the app, preferences or default graph.
void repairGatewayTest(
  String name,
  Future<void> Function(RepairGatewayFixture) body,
) {
  repairTest(name, (f) async {
    final gateway = RepairGatewayFixture(f);
    try {
      await body(gateway);
    } finally {
      gateway.close();
    }
  });
}

final class RepairGatewayFixture {
  RepairGatewayFixture(this.repair) {
    native = RepairGatewayNativeState(mutations, () => rootCurrent);
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(base.db),
        supportRepoProvider.overrideWithValue(base.support),
        chatSourceMutationRegistryProvider.overrideWithValue(mutations),
        supportAppRepairNativePortProvider.overrideWithValue(native),
        repairGatewayNativeStateProvider.overrideWith(() => native),
      ],
    );
    container.read(repairGatewayNativeStateProvider);
    final adapters = container.read(supportAppControlRepairAdaptersProvider);
    sessionAdapter = adapters
        .whereType<SupportAppSessionRepairAdapter>()
        .single;
    integrityAdapter = adapters.whereType<SupportAppIntegrityAdapter>().single;
    original = context();
    sessionHandle = sessionAdapter.bindSession(RepairFixture.session, original);
    groupHandle = integrityAdapter.bindTarget(
      const DatabaseMaintenanceTarget.characterGroup('legacy'),
      original,
    );
    registry = SupportAppActionRegistry(
      adapters: adapters,
      isOriginalOwnerCurrent: () => rootCurrent,
      metadata: SupportAppRedactedMetadataPolicy(
        currentRedactor: () => redactor,
      ),
    );
  }
  final RepairFixture repair;
  MaintenanceFixture get base => repair.base;
  final mutations = ChatSourceMutationRegistry();
  final token = CancelToken();
  final confirmation = RepairGatewayConfirmation();
  // Exact metadata policy checks one immutable snapshot before AND after each
  // projection. A factory here falsely signals policy replacement on every ID.
  final redactor = SecretRedactor(
    knownSecrets: const ['SYNTHETIC_SECRET_CANARY'],
  );
  late final RepairGatewayNativeState native;
  late final ProviderContainer container;
  late final SupportAppSessionRepairAdapter sessionAdapter;
  late final SupportAppIntegrityAdapter integrityAdapter;
  late final SupportAppActionRegistry registry;
  late final SupportAppActionContext original;
  late final String sessionHandle, groupHandle;
  bool rootCurrent = true, runCurrent = true;
  int calls = 0;
  SupportAppActionContext context({
    String? parent,
    String run = 'synthetic-repair-run',
    bool confirm = true,
    CancelToken? cancel,
  }) => SupportAppActionContext(
    runId: run,
    sessionId: parent ?? MaintenanceFixture.sessionId,
    cancelToken: cancel ?? token,
    isCurrent: () => runCurrent,
    allowReversibleChanges: false,
    confirmation: confirm ? confirmation : null,
  );
  Future<NativeToolResult> call(
    String name, [
    Map<String, Object?> args = const {},
    SupportAppActionContext? context,
  ]) async {
    final id = 'synthetic-repair-call-${++calls}';
    final result = await registry.execute(
      NativeToolCall(id: id, name: name, arguments: args),
      context ?? original,
    );
    expect(result.callId, id);
    expect(result.name, name);
    return result;
  }

  Future<NativeToolResult> inspect({int offset = 0}) => call(
    'astoria_session_integrity',
    {'session': sessionHandle, 'operation': 'inspect', 'offset': offset},
  );
  Future<String> target(String kind) async {
    final result = await inspect();
    expect(result.content['code'], 'completed');
    return (data(result)['records'] as List)
            .cast<Map<dynamic, dynamic>>()
            .firstWhere((r) => r['kind'] == kind)['id']
        as String;
  }

  static Map<dynamic, dynamic> data(NativeToolResult result) =>
      result.content['data'] as Map<dynamic, dynamic>;
  void safe(NativeToolResult result) {
    final json = jsonEncode(result.content);
    for (final forbidden in [
      RepairFixture.canary,
      MaintenanceFixture.canary,
      'world:location',
      'world:active_threats',
      'synthetic-failed-collector',
      'synthetic-canon-hash',
      'SqlError',
      'before_ciphertext',
      'SELECT ',
      'SYNTHETIC_SECRET_CANARY',
    ]) {
      expect(json, isNot(contains(forbidden)));
    }
    expect(result.callId, startsWith('synthetic-repair-call-'));
  }

  void close() {
    container.dispose();
    native.dispose();
    mutations.dispose();
  }
}

final class RepairGatewayConfirmation implements SupportAppConfirmationPort {
  final requests = <SupportAppConfirmationRequest>[];
  bool approved = true, uiCurrent = true;
  SupportAppConfirmationRequest? substituted;
  Future<void> Function(SupportAppConfirmationRequest)? beforeDecision;
  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    requests.add(request);
    await beforeDecision?.call(request);
    if (!approved) return null;
    return SupportAppConfirmationLease(
      request: substituted ?? request,
      isOriginalUiCurrent: () => uiCurrent,
    );
  }
}

/// Actual queue/notifier lifetime is native DI, not an action callback. Production
/// repositories still perform every target/journal effect in this fixture.
final class RepairGatewayNativeState extends Notifier<int>
    implements SupportAppRepairNativePort {
  RepairGatewayNativeState(this.mutations, this.isOriginalOwnerCurrent);
  final ChatSourceMutationRegistry mutations;
  final bool Function() isOriginalOwnerCurrent;
  final queue = ChatSessionWriteQueue();
  final invalidated = <String>[];
  bool alive = true, queueAvailable = true;
  bool throwRefresh = false;
  void Function()? afterInvalidate;
  @override
  int build() => 0;
  @override
  bool get isCurrent => alive && ref.mounted && isOriginalOwnerCurrent();
  @override
  ChatSessionWriteQueue? existingQueue(String targetSessionId) =>
      alive && queueAvailable && targetSessionId == RepairFixture.session
      ? queue
      : null;
  @override
  bool invalidateLatestSession(String targetSessionId) {
    if (throwRefresh) throw StateError('SYNTHETIC_PRIVATE_REFRESH_FAILURE');
    expect(mutations.isSessionPending(targetSessionId), isTrue);
    ChatSessionService.clearCache(charId: 'legacy');
    invalidated.add(targetSessionId);
    state++;
    afterInvalidate?.call();
    return true;
  }

  @override
  bool invalidateLatestDatabaseRepair() {
    if (throwRefresh) throw StateError('SYNTHETIC_PRIVATE_REFRESH_FAILURE');
    invalidated.add('database');
    state++;
    afterInvalidate?.call();
    return true;
  }

  void dispose() {
    alive = false;
  }
}
