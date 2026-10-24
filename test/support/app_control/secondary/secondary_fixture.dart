import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_secondary_provider.dart';

const secondaryPrivateCanary = 'OWNED_SECONDARY_PRIVATE_CANARY';

/// Created/run only by the parent verification lane. Uses in-memory SQLite and
/// mock preferences; no native filesystem, network, user DB or key custody.
final class SecondaryFixture {
  SecondaryFixture._(this.db, this.prefs, this.container);
  final AppDatabase db;
  final SharedPreferences prefs;
  final ProviderContainer container;
  bool sourceCurrent = true;
  bool _nativeOwnersDisposed = false;

  static Future<SecondaryFixture> create({
    Map<String, Object> initial = const {},
    Future<SharedPreferences>? preferencesReady,
  }) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWith((ref) {
          if (preferencesReady != null) return preferencesReady;
          return prefs;
        }),
      ],
    );
    return SecondaryFixture._(db, prefs, container);
  }

  SupportAppActionRegistry registry() => SupportAppActionRegistry(
    adapters: container.read(supportAppControlSecondaryAdaptersProvider),
    metadata: const _SyntheticMetadata(),
    isOriginalOwnerCurrent: () => sourceCurrent,
  );

  SupportAppActionContext context({
    SupportAppConfirmationPort? confirmation,
    SupportAppTerminalRootPort? terminalRoot,
    bool Function()? current,
  }) => SupportAppActionContext(
    runId: 'owned-secondary-run',
    sessionId: 'owned-secondary-session',
    cancelToken: CancelToken(),
    isCurrent: current ?? () => sourceCurrent,
    allowReversibleChanges: false,
    confirmation: confirmation,
    terminalRoot: terminalRoot,
  );

  /// Explicit fixture port for disposal while a real native read is pending.
  /// Database teardown remains separate so that read can finish after disposal.
  void disposeNativeOwners() {
    sourceCurrent = false;
    if (_nativeOwnersDisposed) return;
    _nativeOwnersDisposed = true;
    container.dispose();
  }

  Future<void> close() async {
    disposeNativeOwners();
    await db.close();
  }
}

/// Test-only original native gesture. It authorizes the exact retained request,
/// not a bool in tool arguments; actual effects remain in real repositories.
final class SyntheticOriginalConfirmation
    implements SupportAppConfirmationPort {
  bool nativeCurrent = true;
  bool accept = true;
  bool replaceRequest = false;
  int calls = 0;
  SupportAppConfirmationRequest? request;
  Future<void> Function(SupportAppConfirmationRequest)? beforeGesture;
  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest original,
  ) async {
    calls++;
    request = original;
    await beforeGesture?.call(original);
    if (!accept) return null;
    return SupportAppConfirmationLease(
      request: replaceRequest
          ? SupportAppConfirmationRequest(
              context: original.context,
              callId: original.callId,
              action: original.action,
              target: original.target,
              arguments: original.arguments,
              observation: original.observation,
              observationIsCurrent: original.observationIsCurrent,
              preview: original.preview,
            )
          : original,
      isOriginalUiCurrent: () => nativeCurrent,
    );
  }
}

final class SyntheticConnectionOnlyRoot implements SupportAppTerminalRootPort {
  int calls = 0;
  @override
  Future<void> admit(KeylessTerminalEffectDispatch dispatch) async {
    calls++;
    throw StateError('This synthetic connection-only ROOT must not be called.');
  }
}

final class _SyntheticMetadata implements SupportAppMetadataPolicy {
  const _SyntheticMetadata();
  @override
  String? exactText(String value, {required int maxLength}) =>
      value.length <= maxLength &&
          !value.contains(secondaryPrivateCanary) &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
      ? value
      : null;
}

NativeToolCall secondaryCall(
  String name, [
  Map<String, Object?> arguments = const {},
]) => NativeToolCall(
  id: 'owned-secondary-call',
  name: name,
  arguments: arguments,
);

Map<String, Object?> secondaryData(NativeToolResult result) =>
    Map<String, Object?>.from(result.content['data']! as Map);
