import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:sodium/sodium.dart';

import '../../../core/db/repositories/support_report_read_repo.dart';
import '../../../core/db/repositories/support_text_context_repo.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/support_report/support_report_crypto.dart';
import '../../../core/support_report/support_report_error.dart';
import '../../../core/support_report/support_report_recipient.dart';
import '../services/report/support_report_coordinator.dart';
import '../services/support_report_platform_save.dart';
import 'support_native_provider.dart';
import 'support_report_original_owner.dart';
import 'support_workspace_provider.dart';

typedef SupportReportNativeFactory = SupportReportNativeOperation Function();

/// Trusted production owner must supply its audited executor contract. Merely
/// having a FILE identity does NOT attest an arbitrary injected native executor.
/// No fallback grants this assertion to testing/unknown/openedNative owners.
final supportReportNativeAdmissionContractProvider =
    Provider<SupportTextAdmissionContract?>((ref) {
      final db = ref.watch(appDbProvider);
      return db.hasAuditedStockSingleConnectionExecutor
          ? SupportTextAdmissionContract
                .auditedRootSingleConnectionNoBusyHandler
          : null;
    });

/// Read ONLY on an explicit native prepare gesture; never a startup/model graph.
final supportReportNativeFactoryProvider = Provider<SupportReportNativeFactory>(
  (ref) {
    return () {
      if (!ref.exists(appDbProvider) ||
          !ref.exists(supportNativeRuntimeProvider) ||
          !ref.exists(supportWorkspaceProvider)) {
        _unavailable();
      }
      final db = ref.read(appDbProvider);
      final native = db.nativeDataSourceIdentity;
      final runtime = ref.read(supportNativeRuntimeProvider);
      final controller = ref.read(supportNativeConsentControllerProvider);
      final workspace = ref.read(supportWorkspaceProvider);
      final contract = ref.read(supportReportNativeAdmissionContractProvider);
      if (!db.hasCompletedOpening ||
          db.isClosing ||
          native == null ||
          contract == null ||
          !identical(controller.runtime, runtime) ||
          workspace.activeSessionId != runtime.sessionId ||
          workspace.activeSession?.isLocked == true) {
        _unavailable();
      }
      final cipher = ref.read(supportPayloadCipherProvider);
      final credentialOwner = ref.read(nativeProviderRuntimeProvider);
      if (credentialOwner == null || !credentialOwner.isCurrent) _unavailable();
      final redaction = ref.read(secretRedactionCoordinatorProvider);
      final redactor = ref.read(secretRedactorProvider);
      // Retirement links are installed synchronously on the original graph.
      // Current callbacks NEVER read/instantiate a replacement provider after
      // sodium, source reads, a selector or OS I/O has begun.
      var providersCurrent = true;
      final stops = <void Function()>[];
      void retain<T>(ProviderListenable<T> provider) {
        final subscription = ref.listen<T>(provider, (_, _) {
          providersCurrent = false;
        });
        stops.add(subscription.close);
      }

      retain(appDbProvider);
      retain(supportPayloadCipherProvider);
      retain(nativeProviderRuntimeProvider);
      retain(supportNativeRuntimeProvider);
      retain(supportNativeConsentControllerProvider);
      retain(secretRedactionCoordinatorProvider);
      retain(secretRedactorProvider);
      retain(
        supportWorkspaceProvider.select(
          (state) => (
            state.activeSessionId,
            state.settings,
            state.activeSession?.isLocked,
          ),
        ),
      );
      void stopProviders() {
        providersCurrent = false;
        for (final stop in stops) {
          stop();
        }
        stops.clear();
      }

      final owner = SupportReportOriginalOwner(
        database: db,
        nativeSource: native,
        runtime: runtime,
        originalCipher: cipher,
        redactor: redactor,
        admissionContract: contract,
        originalProvidersCurrent: () =>
            ref.mounted &&
            providersCurrent &&
            credentialOwner.isCurrent &&
            identical(controller.runtime, runtime) &&
            identical(redactor, redaction.redactor),
      );
      if (!owner.isCurrent) {
        stopProviders();
        owner.dispose();
        _unavailable();
      }
      return SupportReportNativeOperation(
        ownership: owner,
        saveSupported: Platform.isWindows || Platform.isAndroid,
        createCoordinator: () async {
          final crypto = SupportReportCrypto(await SodiumInit.init());
          if (!owner.isCurrent) _unavailable();
          return SupportReportCoordinator(
            readRepo: SupportReportReadRepo(db),
            ownership: owner,
            crypto: crypto,
            loadRecipient: () async {
              if (!owner.isCurrent) _unavailable();
              final text = await rootBundle.loadString(
                'assets/support_report/recipient.json',
              );
              if (!owner.isCurrent) _unavailable();
              return SupportReportRecipient.parse(text);
            },
            savePort: SupportReportPlatformSave(
              validateCiphertext: crypto.isWellFormedPacket,
            ),
          );
        },
        disposeOwner: () {
          stopProviders();
          owner.dispose();
        },
      );
    };
  },
);

/// Public synthetic injection seam still receives a REAL coordinator, ROOT and
/// cipher. It cannot mint previews, ROOT proof, approvals or forged encryption.
final class SupportReportNativeOperation {
  SupportReportNativeOperation({
    required this.ownership,
    required Future<SupportReportCoordinator> Function() createCoordinator,
    this.saveSupported = true,
    void Function()? disposeOwner,
  }) : _create = createCoordinator,
       // Keep the public composition seam while retaining disposal privately.
       // ignore: prefer_initializing_formals
       _disposeOwner = disposeOwner;
  final SupportReportOwnership ownership;
  final bool saveSupported;
  final Future<SupportReportCoordinator> Function() _create;
  final void Function()? _disposeOwner;
  SupportReportCoordinator? _coordinator;
  bool _alive = true;
  bool get isCurrent {
    try {
      return _alive && ownership.isCurrent;
    } catch (_) {
      return false;
    }
  }

  Future<SupportReportCoordinator> initialize() async {
    if (!isCurrent) _unavailable();
    final coordinator = await _create();
    _coordinator = coordinator;
    if (!isCurrent) {
      coordinator.dispose();
      _unavailable();
    }
    return coordinator;
  }

  void dispose() {
    _alive = false;
    _disposeOwner?.call();
    _coordinator?.dispose();
  }
}

Never _unavailable() =>
    throw const SupportReportException(SupportReportFailure.unavailable);
