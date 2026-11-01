import 'package:flutter_riverpod/misc.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_read_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_coordinator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_report_original_owner.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_report_provider.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:sodium/sodium.dart';

import '../../credentials/fake_credential_storage.dart';
import '../helpers/support_native_widget_fixture.dart';
import 'support_report_native_fixture.dart';
import 'support_report_save_probe.dart';

/// Real synthetic FILE, original native controller/global encrypted permission,
/// actual parent-issued ROOT and sodium; only vault/destination are synthetic.
final class SupportReportSheetFixture {
  static const session = 'synthetic-report-sheet';
  static const title = 'SYNTHETIC_EXACT_TITLE';
  static const body = 'SYNTHETIC_EXACT_COMMENTARY';
  final native = SupportReportNativeFixture();
  late SupportPayloadCipher cipher;
  late SupportRepo repo;
  late SupportPermissionStore permissions;
  late SupportNativeRuntime runtime;
  late SupportNativeConsentController controller;
  late SupportConsentSelectionRepo selections;
  late SupportReportCrypto crypto;
  late KeyPair keys;
  SupportReportRecipient? recipient;
  final saves = <SupportReportSaveProbe>[];
  final owners = <SupportReportOriginalOwner>[];
  bool alive = true;

  Future<void> initialize({bool configured = true}) async {
    await native.initialize();
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'synthetic-report-ui',
      ),
    );
    repo = SupportRepo(native.database, cipher);
    await repo.createSession(
      const SupportSession(
        id: session,
        title: title,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await repo.appendMessage(
      const SupportMessage(
        id: 'synthetic-report-body',
        sessionId: session,
        role: 'user',
        body: body,
        cardsJson: '[]',
        createdAt: 2,
      ),
    );
    permissions = SupportPermissionStore(repo, initializeGlobalOnRefresh: true);
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (_) async => const SupportRecipientUnavailable(
        SupportRecipientUnavailableReason.selectionMissing,
      ),
      loadSelectedConnection: (_, _) async => null,
      configurationRevision: () => 1,
      configurationStable: () => true,
    );
    runtime.selectSession(session);
    await runtime.refresh();
    selections = SupportConsentSelectionRepo(
      db: native.database,
      supportRepo: repo,
      currentRedactor: () => native.redactor,
    );
    controller = SupportNativeConsentController(
      runtime: runtime,
      readMessages: (_, id, offset) =>
          selections.listSupportMessages(sessionId: id, offset: offset),
    );
    final sodium = await SodiumInit.init();
    crypto = SupportReportCrypto(sodium);
    keys = sodium.crypto.box.keyPair(); // Synthetic transient keys ONLY.
    if (configured) {
      recipient = SupportReportRecipient(
        keyId: 'synthetic-sheet',
        publicKey: keys.publicKey,
      );
    }
  }

  SupportReportNativeOperation capture() {
    final owner = SupportReportOriginalOwner(
      database: native.database,
      nativeSource: native.nativeSource,
      runtime: runtime,
      originalCipher: cipher,
      redactor: native.redactor,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
      originalProvidersCurrent: () => alive,
    );
    owners.add(owner);
    final save = SupportReportSaveProbe();
    saves.add(save);
    return SupportReportNativeOperation(
      ownership: owner,
      disposeOwner: owner.dispose,
      createCoordinator: () async => SupportReportCoordinator(
        readRepo: SupportReportReadRepo(native.database),
        ownership: owner,
        loadRecipient: () async => recipient,
        crypto: crypto,
        savePort: save,
      ),
    );
  }

  List<Override> get overrides => [
    appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
    supportNativeRuntimeProvider.overrideWithValue(runtime),
    supportNativeConsentControllerProvider.overrideWithValue(controller),
    supportConsentSelectionRepoProvider.overrideWithValue(selections),
    supportReportNativeFactoryProvider.overrideWithValue(capture),
  ];

  Future<void> close() async {
    alive = false;
    for (final owner in owners) {
      owner.dispose();
    }
    runtime.dispose();
    keys.secretKey.dispose();
    await native.close();
  }
}
