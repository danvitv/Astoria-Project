import 'dart:typed_data';

import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/db/app_db.dart';
import '../../../../core/db/repositories/support_report_read_repo.dart';
import '../../../../core/db/repositories/support_report_root_repo.dart';
import '../../../../core/support/support_payload_cipher.dart';
import '../../../../core/support_report/support_report_crypto.dart';
import '../../../../core/support_report/support_report_error.dart';
import '../../../../core/support_report/support_report_json.dart';
import '../../../../core/support_report/support_report_recipient.dart';
import '../../../../core/support_report/support_report_save_port.dart';
import 'support_report_builder.dart';
import 'support_report_models.dart';
import 'support_report_ownership.dart';

export 'support_report_models.dart';
export 'support_report_ownership.dart';

part 'support_report_preview_store.dart';

/// Native preview/save only. Never expose this coordinator as a model tool.
final class SupportReportCoordinator {
  SupportReportCoordinator({
    required this.readRepo,
    required this.ownership,
    required this.loadRecipient,
    required this.crypto,
    required this.savePort,
  });
  final SupportReportReadRepo readRepo;
  final SupportReportOwnershipPort ownership;
  final Future<SupportReportRecipient?> Function() loadRecipient;
  final SupportReportCrypto crypto;
  final SupportReportSavePort savePort;
  int _epoch = 0;
  bool _disposed = false, _exporting = false;
  _Prepared? _active;

  Future<SupportReportPreview> prepare(
    SupportReportPrepareRequest request,
  ) async {
    if (_disposed || _exporting) _fail(SupportReportFailure.unavailable);
    _retire();
    final epoch = _epoch;
    final owner = _capture(); // Original ownership BEFORE any await.
    if ([request.gameSessionId, request.supportSessionId].any(
      (id) =>
          id != null &&
          (id.isEmpty || id.length > 1024 || id.contains('\u0000')),
    )) {
      _fail(SupportReportFailure.invalidArguments);
    }
    bool current() {
      try {
        return !_disposed &&
            epoch == _epoch &&
            owner.isCurrent &&
            owner.nativeSource.belongsTo(owner.database) &&
            readRepo.usesDatabase(owner.database) &&
            (!request.requiresApplicationData || owner.allowsApplicationData);
      } catch (_) {
        return false;
      }
    }

    if (!current()) {
      _fail(SupportReportFailure.changed);
    }
    void check() {
      if (!current()) _fail(SupportReportFailure.changed);
    }

    try {
      final recipient = await loadRecipient();
      check();
      if (recipient != null &&
          owner.redactor.redactText(recipient.keyId) != recipient.keyId) {
        _fail(SupportReportFailure.invalidRecipient);
      }
      final prepared = await owner.withOriginalRoot(() async {
        check();
        final root = _root(owner);
        bool rootCurrent() => _rootCurrent(owner, root, current);
        return readRepo.snapshot(
          originalRoot: root,
          isCurrent: rootCurrent,
          gameSessionId: request.gameSessionId,
          supportSessionId: request.supportSessionId,
          includeTitles: request.includeTitles,
          includeProse: request.includeProse,
          read: (snapshot) async {
            check();
            final builder = SupportReportBuilder(owner, rootCurrent);
            await builder.build(snapshot, request);
            root.check(owner.database);
            check();
            final id = crypto.sodium.randombytes
                .buf(16)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();
            final day =
                DateTime.now().toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay;
            return _Prepared(
              owner,
              snapshot.revalidationOnly(),
              recipient,
              id,
              day,
              current,
              List.unmodifiable(builder.blocks),
              List.unmodifiable(builder.omissions),
            );
          },
        );
      });
      check();
      _active = prepared;
      return _preview(prepared);
    } on SupportReportException {
      rethrow;
    } catch (_) {
      _fail(SupportReportFailure.unavailable);
    }
  }

  SupportReportPreview exclude(
    SupportReportPreview preview,
    Set<String> blockIds,
  ) => _exclude(preview, blockIds);

  /// Actual native save-button invocation is the one-use approval boundary.
  Future<SupportReportSaveResult> exportDisplayed(
    SupportReportPreview preview,
  ) async {
    Uint8List? packet;
    _ReportSaveAdmission? admitted;
    var ownsExport = false;
    try {
      final p = _require(preview);
      if (_exporting || p.consumed) _fail(SupportReportFailure.unavailable);
      p.consumed = true;
      _exporting = true;
      ownsExport = true;
      void check() {
        if (!p.current() || p.retired || !identical(_active, p)) {
          _fail(SupportReportFailure.changed);
        }
      }

      check();
      if (p.recipient == null) _fail(SupportReportFailure.recipientMissing);
      // Human destination choice is intentionally OUTSIDE the native writer
      // ROOT. Only this immutable preview and one-use approval survive the wait.
      final destination = await savePort.chooseDestination(
        fileName: 'astoria-support-${p.id}.astrpt',
        isCurrent: () => p.current() && !p.retired,
      );
      check();
      if (destination == null) {
        return const SupportReportSaveResult(SupportReportSaveStatus.canceled);
      }
      final recipient = await loadRecipient();
      check();
      if (!p.recipient!.sameAs(recipient)) _fail(SupportReportFailure.changed);
      final admission = await p.owner.admitOriginalRoot(
        validate: () async {
          check();
          final root = _root(p.owner);
          bool rootCurrent() => _rootCurrent(p.owner, root, p.current);
          await readRepo.revalidate(p.snapshot, rootCurrent, () async {
            root.check(p.owner.database);
            check();
            packet = crypto.encrypt(
              payloadJson: preview.payloadJson,
              recipient: p.recipient!,
              reportId: p.id,
              createdDay: p.day,
            );
            root.check(p.owner.database);
            check();
          }, originalRoot: root);
          root.check(p.owner.database);
          check();
        },
        dispatch: () {
          final root = _root(p.owner);
          bool rootCurrent() => _rootCurrent(p.owner, root, p.current);
          check();
          root.check(p.owner.database);
          check();
          // No await or byte copy between final check and native admission.
          // Windows writes synchronously here; Android dispatches the exact
          // packet synchronously and returns its admitted OS response future.
          final response = savePort.commit(
            destination: destination,
            ciphertext: packet!,
            isCurrent: () => rootCurrent() && !p.retired,
          );
          admitted = _ReportSaveAdmission(response);
          return admitted!; // Capsule prevents Future flattening inside ROOT.
        },
      );
      // Native ROOT transaction and borrow have now settled. Only admitted OS
      // I/O completion is awaited here; Stop cannot unsave an admitted write.
      final result = await admission.response;
      if (result.status != SupportReportSaveStatus.saved) check();
      return result;
    } on SupportReportException catch (e) {
      if (admitted != null) return await admitted!.response;
      return SupportReportSaveResult(
        SupportReportSaveStatus.refused,
        reason: e.failure.name,
      );
    } catch (_) {
      if (admitted != null) return await admitted!.response;
      return const SupportReportSaveResult(
        SupportReportSaveStatus.failed,
        reason: 'unavailable',
      );
    } finally {
      packet?.fillRange(0, packet!.length, 0);
      if (ownsExport) {
        _retire();
        if (admitted == null) {
          // Selection can already own an empty Android document. A failed
          // recipient/stamp/current check must settle that original custody,
          // outside the released ROOT, without canceling any admitted I/O.
          try {
            await savePort.cancel();
          } catch (_) {
            /* finite, best-effort native destination cleanup */
          }
        }
        _exporting = false;
      }
    }
  }

  Future<void> cancel() async {
    _retire();
    try {
      await savePort.cancel();
    } catch (_) {
      /* finite cancellation */
    }
  }

  void dispose() {
    _disposed = true;
    _retire();
    savePort.cancel().ignore();
  }

  Never _fail(SupportReportFailure failure) =>
      throw SupportReportException(failure);

  SupportReportOwnership _capture() {
    try {
      return _CapturedReportOwnership(ownership.capture());
    } catch (_) {
      _fail(SupportReportFailure.unavailable);
    }
  }
}
