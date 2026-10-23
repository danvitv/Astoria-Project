import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_game_source_observer.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import 'helpers/support_permission_database_fixture.dart' show PermissionPausedRepo;
import 'synthetic_consent_selection_fixture.dart';

/// Declared createAll memory SQLite, fake vault and real AEAD ONLY. Neither App,
/// default migrations, environment, platform storage nor provider bootstrap.
final class SessionConsentFixture {
  SessionConsentFixture() {
    repo = PermissionPausedRepo(data.db, data.cipher);
    permissions = SupportPermissionStore(
      repo,
      newIdentity: () => 'synthetic-session-policy',
      now: () => 10,
    );
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (_) async {
        recipientReads++;
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.selectionMissing,
        );
      },
      loadSelectedConnection: (_, _) async {
        connectionReads++;
        return null;
      },
      configurationRevision: () => configuration,
      configurationStable: () => true,
      gameSourceCheckpoint: () => observer?.reconcile(),
      gameSourceStable: () => observer?.isStable ?? true,
    );
    observer = SupportGameSourceObserver(
      registry: sources,
      runtime: runtime,
      invalidateGameSource: ({required sessionId, messageIds}) {
        retiredSources.add(sessionId);
      },
    );
    controller = newController();
    _unlisten = runtime.listenGameSourceRetirement(
      controller.invalidateDisplayedIntents,
    );
  }
  static const own = 'session-consent-own';
  static const foreign = 'session-consent-foreign';
  static const game = 'session-consent-game';
  final data = SyntheticConsentSelectionFixture();
  final sources = ChatSourceMutationRegistry();
  final retiredSources = <String>[];
  late final PermissionPausedRepo repo;
  late final SupportPermissionStore permissions;
  late final SupportNativeRuntime runtime;
  late final SupportNativeConsentController controller;
  late final void Function() _unlisten;
  SupportGameSourceObserver? observer;
  Future<void> Function()? beforeSession;
  int sessionReads = 0, messageReads = 0;
  int recipientReads = 0, connectionReads = 0, configuration = 1;

  SupportNativeConsentController newController() => SupportNativeConsentController(
    runtime: runtime,
    sessionSources: sources,
    readSession: (source, id) async {
      sessionReads++;
      await beforeSession?.call();
      return data.repo.readSessionMetadata(source: source, sessionId: id);
    },
    readMessages: (source, id, offset) {
      messageReads++;
      return source == SupportConsentSelectionSource.roleplay
          ? data.repo.listRoleplayMessages(sessionId: id, offset: offset)
          : data.repo.listSupportMessages(sessionId: id, offset: offset);
    },
  );

  Future<void> seed({String messages = '[]'}) async {
    await data.character('session-consent-character');
    await data.roleplay(game, 'session-consent-character', messages, updatedAt: 3);
    await data.supportSession(own);
    await data.supportSession(foreign);
    runtime.selectSession(own);
    await runtime.refresh();
  }

  Future<SupportNativeReview> review() async =>
      (await controller.prepareReview(resolveRecipient: false))!;
  Future<SupportPermissionPreferences> policy() async =>
      (await permissions.readForNative(own)).preferences!;

  Future<void> close() async {
    _unlisten();
    controller.invalidateDisplayedIntents();
    observer?.dispose();
    runtime.dispose();
    sources.dispose();
    await data.close();
  }
}
