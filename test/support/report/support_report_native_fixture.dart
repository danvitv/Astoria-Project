import 'dart:io';

import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_root_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_ownership.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../credentials/fake_credential_storage.dart';

/// Synthetic FILE database and the ACTUAL audited writer-excluding ROOT. This
/// fixture cannot mint a scope or substitute a memory database / caller boolean.
/// Native UI/global-policy composition remains the parent's integration gate.
final class SupportReportNativeFixture
    implements SupportReportOwnership, SupportReportOwnershipPort {
  late Directory directory;
  late sqlite.Database raw;
  @override
  late AppDatabase database;
  @override
  late NativeDataSourceIdentity nativeSource;
  @override
  final redactor = SecretRedactor(knownSecrets: ['synthetic-known-secret']);
  @override
  late SupportPayloadCipher readCipher;
  late SupportReportRootRepo root;
  bool alive = true;
  bool applicationData = true;
  void Function()? onAdmissionReleased;
  String get path => '${directory.path}${Platform.pathSeparator}synthetic.db';

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'astoria-synthetic-report-root-',
    );
    raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA journal_mode=WAL');
    raw.execute('PRAGMA busy_timeout=0');
    database = AppDatabase.openedNative(raw);
    await database.customSelect('SELECT 1').get();
    raw.execute('PRAGMA busy_timeout=0');
    nativeSource = database.nativeDataSourceIdentity!;
    final cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'synthetic_report',
      ),
    );
    readCipher = SupportPayloadCipher.readOnly(
      delegate: cipher,
      gate: (work) => work(),
    );
    final history = SupportTextContextRepo(
      db: database,
      cipher: readCipher,
      currentRedactor: () => redactor,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
    );
    root = SupportReportRootRepo(
      database: database,
      nativeSource: nativeSource,
      history: history,
      isCurrent: () => isCurrent,
    );
  }

  @override
  bool get isCurrent =>
      alive && !database.isClosing && nativeSource.belongsTo(database);
  @override
  bool get allowsApplicationData => applicationData;
  @override
  NativeReportRootScope? get originalRoot => root.currentScope;
  @override
  SupportReportOwnership capture() => this;
  @override
  Future<T> withOriginalRoot<T>(Future<T> Function() work) =>
      root.read((scope) => work());
  @override
  Future<T> admitOriginalRoot<T>({
    required Future<void> Function() validate,
    required T Function() dispatch,
  }) async {
    try {
      return await root.admit(
        validate: (scope) => validate(),
        dispatch: (scope) => dispatch(),
      );
    } finally {
      onAdmissionReleased?.call();
    }
  }

  Future<void> close() async {
    alive = false;
    await database.close();
    await directory.delete(recursive: true); // Only this fixture's own files.
  }
}
