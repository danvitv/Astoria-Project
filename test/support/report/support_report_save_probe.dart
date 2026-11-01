import 'dart:async';
import 'dart:typed_data';

import 'package:glaze_flutter/core/support_report/support_report_save_port.dart';

/// Synthetic native handoff probe, never a ROOT issuer or file writer. Actual
/// scope/writer assertions are made by callers using SupportReportRootRepo.
final class SupportReportSaveProbe implements SupportReportSavePort {
  Future<SupportReportSaveDestination?> Function()? choose;
  void Function()? onCommit;
  Future<SupportReportSaveResult>? response;
  int choices = 0, commits = 0;
  Uint8List? packet;
  final dispatched = Completer<void>();
  final destination = _ProbeDestination();
  @override
  Future<SupportReportSaveDestination?> chooseDestination({
    required String fileName,
    required bool Function() isCurrent,
  }) {
    choices++;
    if (!isCurrent()) return Future.value(null);
    return choose?.call() ?? Future.value(destination);
  }

  @override
  Future<SupportReportSaveResult> commit({
    required SupportReportSaveDestination destination,
    required Uint8List ciphertext,
    required bool Function() isCurrent,
  }) {
    if (!isCurrent() || !identical(destination, this.destination)) {
      return Future.value(
        const SupportReportSaveResult(SupportReportSaveStatus.refused),
      );
    }
    onCommit?.call();
    packet = Uint8List.fromList(
      ciphertext,
    ); // native receiver's synchronous copy
    commits++;
    dispatched.complete();
    return response ??
        Future.value(
          const SupportReportSaveResult(SupportReportSaveStatus.saved),
        );
  }

  @override
  Future<void> cancel() async {}
}

final class _ProbeDestination implements SupportReportSaveDestination {}
