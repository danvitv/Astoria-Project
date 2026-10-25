import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../core/db/repositories/database_restore_repo.dart';
import '../../core/startup/database_startup.dart';
import '../../core/support/support_payload_cipher.dart';

typedef DatabaseRecoveryPicker = Future<FilePickerResult?> Function();

/// Genuine v11 API; tests replace only its underlying platform singleton.
Future<FilePickerResult?> pickDatabaseRecoveryFile() => FilePicker.pickFiles(
  type: FileType.custom,
  allowedExtensions: const ['db'],
  allowMultiple: false,
  withData: false,
);

/// Custody for ONE original picker/prepare/restore. Retirement is monotonic;
/// cancel/dispose never makes an unsettled picker reusable or closes live SQL.
final class DatabaseRecoveryOperation {
  DatabaseRecoveryOperation({
    required this.startup,
    required this.picker,
    required this.credentialsFactory,
    required this.isViewCurrent,
    this.restoreOwnerFactory = NativeDatabaseRestoreOwner.fromStartup,
  });

  final NativeDatabaseStartupOwner startup;
  final DatabaseRecoveryPicker picker;
  final DatabaseRecoveryCredentials Function() credentialsFactory;
  final bool Function() isViewCurrent;
  final NativeDatabaseRestoreOwner Function({
    required NativeDatabaseStartupOwner startup,
    required File candidate,
    required SupportPayloadCipher payloadCipher,
  })
  restoreOwnerFactory;
  DatabaseRestoreRepo? repo;
  NativeDatabaseRestoreOwner? owner;
  DatabaseRecoveryCredentials? credentials;
  DatabaseRestoreProposal? proposal;
  AcceptedDatabaseRestore? accepted;
  String?
  selectedPath; // Private recovery surface only, never diagnostics/model.
  Future<void>? _active;
  Future<void>? _cancelling;
  bool retired = false;
  bool confirmed = false;
  bool _closed = false;
  final _clock = Stopwatch();

  bool get current => !retired && isViewCurrent();
  void requireCurrent() {
    if (!current)
      throw const DatabaseRestoreException(DatabaseRestoreCode.cancelled);
  }

  Future<T> _observe<T>(Future<T> original) {
    _active = original.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return original;
  }

  Future<DatabaseRestoreProposal?> pickAndPrepare() =>
      _observe(_pickAndPrepare());
  Future<DatabaseRestoreProposal?> _pickAndPrepare() async {
    requireCurrent();
    // Observe the ORIGINAL immediately. No timeout wrapper owns its settlement.
    final original = Future<FilePickerResult?>.sync(picker);
    unawaited(
      original.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final result = await original;
    requireCurrent();
    if (result == null) return null;
    if (result.files.length != 1 || result.files.single.path == null) {
      throw const DatabaseRestoreException(
        DatabaseRestoreCode.invalidCandidate,
      );
    }
    selectedPath = result.files.single.path!;
    credentials = credentialsFactory(); // ONLY after a fresh current picker.
    _clock.start();
    final readOnly = SupportPayloadCipher.readOnly(
      delegate: credentials!.cipher,
      gate: _readWithinCurrentBudget,
    );
    await readOnly
        .requireExistingInstallationKey(); // Also zero encrypted rows.
    requireCurrent();
    owner = restoreOwnerFactory(
      startup: startup,
      candidate: File(selectedPath!),
      payloadCipher: readOnly,
    );
    repo = DatabaseRestoreRepo(owner: owner);
    final prepared = await repo!.prepare();
    requireCurrent();
    _clock.stop();
    return proposal = prepared;
  }

  Future<String> _readWithinCurrentBudget(
    Future<String> Function() decrypt,
  ) async {
    _checkReadBudget();
    // Wait for the genuine pure future even on cancel. No abandoned key/FIFO
    // work becomes evidence that native resources can be closed.
    final original = Future<String>.sync(decrypt);
    unawaited(
      original.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final value = await original;
    _checkReadBudget();
    return value;
  }

  void _checkReadBudget() {
    requireCurrent();
    if (_clock.elapsed > const Duration(seconds: 15)) {
      throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
    }
  }

  /// Called only by the production destructive button, with its captured token.
  Future<DatabaseRestoreResult> confirmAndRestore(
    DatabaseRestoreProposal exact,
  ) {
    requireCurrent();
    if (confirmed || !identical(exact, proposal) || repo == null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    confirmed = true; // Before Core callbacks/awaits; never revived on failure.
    _clock.reset();
    _clock.start();
    final confirmation = repo!.confirm(exact);
    return _observe(
      repo!.restore(confirmation).then((result) {
        accepted =
            result.accepted; // Retain even if UI retires after admission.
        _clock.stop();
        return result;
      }),
    );
  }

  Future<void> cancelAndJoin() {
    retired = true; // BEFORE any callback or await; A→B→A cannot revive.
    return _cancelling ??= _cancelAndJoin();
  }

  Future<void> _cancelAndJoin() async {
    // Signal Core immediately after admission; it owns original settlement and
    // reverse. Before picker settles there is no backend to cancel or clean up.
    final cancellation = repo?.cancel();
    if (cancellation != null) {
      unawaited(
        cancellation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    await _active;
    await cancellation;
    if (accepted != null) return; // No guessed live-app writer drain/DB close.
    await closeSettled();
  }

  Future<void> closeSettled() async {
    if (_closed || accepted != null) return;
    await _active;
    await repo?.close(); // Borrowed startup guard remains process-owned.
    _closed = true;
  }
}
