import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/db/app_db.dart';
import '../../../../core/db/repositories/support_report_root_repo.dart';
import '../../../../core/support/support_payload_cipher.dart';

/// Native composition only. Implement with original NativeOwner ROOT custody,
/// not a tool/model callback. capture is synchronous, BEFORE any awaited read.
abstract interface class SupportReportOwnershipPort {
  SupportReportOwnership capture();
}

abstract interface class SupportReportOwnership {
  AppDatabase get database;
  NativeDataSourceIdentity get nativeSource;
  SecretRedactor get redactor;
  SupportPayloadCipher get readCipher;
  bool get isCurrent;
  bool get allowsApplicationData;

  /// Parent-issued, unforgeable proof, present ONLY inside withOriginalRoot.
  NativeReportRootScope? get originalRoot;

  /// Retain ORIGINAL native ROOT writer exclusion, owner zone and lifetime
  /// through bounded reads/encryption/final ciphertext admission. Never hold
  /// this ROOT across a human picker or admitted Android response wait.
  /// A read-only WAL
  /// transaction and a fingerprint are not substitutes. Reject foreign roots.
  Future<T> withOriginalRoot<T>(Future<T> Function() work);

  /// Delegate to the original SupportReportRootRepo.admit: validate performs
  /// joined bounded reads; dispatch runs only AFTER its final audited checks.
  /// Return a capsule, never the native response Future itself.
  Future<T> admitOriginalRoot<T>({
    required Future<void> Function() validate,
    required T Function() dispatch,
  });
}
