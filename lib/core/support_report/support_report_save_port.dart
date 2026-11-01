import 'dart:typed_data';

/// Native destination custody, never a model-supplied path or URI. Implementors
/// retain the private issuer and reject destinations from another operation.
abstract interface class SupportReportSaveDestination {}

enum SupportReportSaveStatus { saved, canceled, refused, failed }

final class SupportReportSaveResult {
  const SupportReportSaveResult(this.status, {this.fileName, this.reason});

  final SupportReportSaveStatus status;
  final String? fileName;

  /// A finite adapter refusal/error code, never a path, exception or content.
  final String? reason;
}

/// User-selected ciphertext-only save. Choice and write are separate so native
/// consent/source custody can be checked after the destination dialog. No
/// Downloads fallback, share sheet, upload or plaintext temporary artifact.
abstract interface class SupportReportSavePort {
  Future<SupportReportSaveDestination?> chooseDestination({
    required String fileName,
    required bool Function() isCurrent,
  });

  Future<SupportReportSaveResult> commit({
    required SupportReportSaveDestination destination,
    required Uint8List ciphertext,
    required bool Function() isCurrent,
  });

  Future<void> cancel();
}
