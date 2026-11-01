import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/support_report_root_repo.dart';
import '../../../core/db/repositories/support_text_context_repo.dart';
import '../../../core/support/support_payload_cipher.dart';
import '../../../core/support_report/support_report_error.dart';
import '../models/support_permission_preferences.dart';
import '../services/report/support_report_ownership.dart';
import '../services/support_native_runtime.dart';

/// Immutable originals, captured BEFORE sodium/assets/DB/crypto awaits. This is
/// not a bool proof: actual writer ROOT is issued by SupportReportRootRepo only.
final class SupportReportOriginalOwner
    implements SupportReportOwnership, SupportReportOwnershipPort {
  SupportReportOriginalOwner({
    required this.database,
    required this.nativeSource,
    required this.runtime,
    required SupportPayloadCipher originalCipher,
    required this.redactor,
    required SupportTextAdmissionContract admissionContract,
    required bool Function() originalProvidersCurrent,
  }) : _providersCurrent = originalProvidersCurrent,
       _epoch = runtime.epoch,
       _lifetime = runtime.lifetime,
       _writeOwner = runtime.writeOwner,
       _session = runtime.sessionId,
       _configuration = runtime.configurationRevision(),
       _revocation = runtime.permissions.applicationDataRevocationRevision,
       _policy = runtime.snapshot.preferences {
    readCipher = SupportPayloadCipher.readOnly(
      delegate: originalCipher,
      gate: (work) async {
        _check();
        final value = await work().timeout(const Duration(seconds: 2));
        _check();
        originalRoot?.check(database);
        return value;
      },
    );
    _history = SupportTextContextRepo(
      db: database,
      cipher: readCipher,
      currentRedactor: () => redactor,
      admissionContract: admissionContract,
    );
    _root = SupportReportRootRepo(
      database: database,
      nativeSource: nativeSource,
      history: _history,
      isCurrent: () => isCurrent,
    );
  }
  @override
  final AppDatabase database;
  @override
  final NativeDataSourceIdentity nativeSource;
  @override
  final SecretRedactor redactor;
  final SupportNativeRuntime runtime;
  final bool Function() _providersCurrent;
  final int _epoch, _lifetime, _writeOwner, _configuration, _revocation;
  final String _session;
  final SupportPermissionPreferences? _policy;
  @override
  late final SupportPayloadCipher readCipher;
  late final SupportTextContextRepo _history;
  late final SupportReportRootRepo _root;
  bool _alive = true;

  @override
  bool get isCurrent {
    try {
      runtime.checkConfiguration();
      return _alive &&
          _providersCurrent() &&
          database.hasCompletedOpening &&
          !database.isClosing &&
          identical(database.nativeDataSourceIdentity, nativeSource) &&
          nativeSource.belongsTo(database) &&
          runtime.alive &&
          runtime.epoch == _epoch &&
          runtime.lifetime == _lifetime &&
          runtime.writeOwner == _writeOwner &&
          runtime.sessionId == _session &&
          runtime.pending == 0 &&
          runtime.settingsPending == 0 &&
          runtime.configurationStable() &&
          runtime.configurationRevision() == _configuration &&
          (runtime.gameSourceStable?.call() ?? true) &&
          identical(runtime.snapshot.preferences, _policy) &&
          runtime.permissions.applicationDataRevocationRevision == _revocation;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get allowsApplicationData =>
      isCurrent &&
      !runtime.permissions.applicationDataReadDenied &&
      _policy?.isGlobal == true &&
      _policy?.allows(SupportPermission.readApplicationData) == true;
  @override
  NativeReportRootScope? get originalRoot => _root.currentScope;
  @override
  SupportReportOwnership capture() {
    _check();
    return this;
  }

  @override
  Future<T> withOriginalRoot<T>(Future<T> Function() work) =>
      _root.read((scope) => work());
  @override
  Future<T> admitOriginalRoot<T>({
    required Future<void> Function() validate,
    required T Function() dispatch,
  }) => _root.admit(validate: (_) => validate(), dispatch: (_) => dispatch());
  void dispose() {
    _alive = false;
    _history.revokeAdmissionOwner();
  }

  void _check() {
    if (!isCurrent) {
      throw const SupportReportException(SupportReportFailure.changed);
    }
  }
}
