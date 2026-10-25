import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/database_restore_repo.dart';
import '../../core/startup/database_startup.dart';
import '../../core/support/support_payload_cipher.dart';
import 'database_recovery_operation.dart';

enum DatabaseRecoveryPhase {
  ready,
  picking,
  preparing,
  proposal,
  cancelling,
  restoring,
  entering,
  blocked,
}

final class DatabaseRecoveryState {
  const DatabaseRecoveryState({
    this.phase = DatabaseRecoveryPhase.ready,
    this.code,
    this.selectedPath,
    this.proposal,
    this.operation,
    this.keyFailure,
  });
  final DatabaseRecoveryPhase phase;
  final DatabaseRestoreCode? code;
  final SupportCipherFailure? keyFailure;
  final String? selectedPath;
  final DatabaseRestoreProposal? proposal;
  final DatabaseRecoveryOperation? operation;
  bool get busy =>
      phase != DatabaseRecoveryPhase.ready &&
      phase != DatabaseRecoveryPhase.proposal &&
      phase != DatabaseRecoveryPhase.blocked;
}

/// Non-autoDispose: original operation custody does not end with widget return.
/// No default composition can start storage or fall back to ordinary providers.
final databaseRecoveryControllerProvider =
    NotifierProvider<DatabaseRecoveryController, DatabaseRecoveryState>(
      () => throw StateError('Recovery composition required'),
    );

final class DatabaseRecoveryController extends Notifier<DatabaseRecoveryState> {
  DatabaseRecoveryController({
    required this.process,
    required this.bootstrap,
    required this.publishNormal,
    this.picker = pickDatabaseRecoveryFile,
    this.credentialsFactory = DatabaseRecoveryCredentials.native,
    this.initialBlock,
    this.pickerBudget = const Duration(minutes: 2),
    this.operationFactory,
    this.recoveryAvailable = true,
  });
  final ProcessDatabaseStartup? process;
  final Future<void> Function() bootstrap;
  final void Function(ProcessDatabaseStartup) publishNormal;
  final DatabaseRecoveryPicker picker;
  final DatabaseRecoveryCredentials Function() credentialsFactory;
  final DatabaseRestoreCode? initialBlock;
  final Duration pickerBudget;
  final DatabaseRecoveryOperation Function(bool Function() current)?
  operationFactory;
  final bool recoveryAvailable;
  DatabaseRecoveryOperation? _operation;
  Future<void>? _work;
  Future<void>? _cancelWork;
  Timer? _pickerTimer;
  bool _viewAlive = true;
  bool _entryLatched = false;

  @override
  DatabaseRecoveryState build() {
    ref.onDispose(retireView);
    final block =
        initialBlock ??
        (process == null
            ? DatabaseRestoreCode.unavailable
            : process!.normalOpeningBlocked
            ? DatabaseRestoreCode.interruptedRequiresFreshConfirmation
            : null);
    return block == null
        ? DatabaseRecoveryState(
            code: recoveryAvailable ? null : DatabaseRestoreCode.unavailable,
          )
        : DatabaseRecoveryState(
            phase: DatabaseRecoveryPhase.blocked,
            code: block,
          );
  }

  bool _current(DatabaseRecoveryOperation operation) =>
      _viewAlive && identical(operation, _operation);
  void _publish(DatabaseRecoveryState next) {
    if (_viewAlive && ref.mounted) state = next;
  }

  Future<void> chooseFile() {
    if (!_viewAlive ||
        !recoveryAvailable ||
        _entryLatched ||
        state.busy ||
        state.phase == DatabaseRecoveryPhase.blocked ||
        _operation != null) {
      return Future<void>.value();
    }
    final startup = process?.startupOwner;
    if (startup == null) {
      _block(DatabaseRestoreCode.unsupported);
      return Future<void>.value();
    }
    late final DatabaseRecoveryOperation operation;
    operation =
        operationFactory?.call(() => _current(operation)) ??
        DatabaseRecoveryOperation(
          startup: startup,
          picker: picker,
          credentialsFactory: credentialsFactory,
          isViewCurrent: () => _current(operation),
        );
    _operation = operation;
    _publish(const DatabaseRecoveryState(phase: DatabaseRecoveryPhase.picking));
    _pickerTimer = Timer(pickerBudget, () {
      unawaited(cancel());
    });
    return _work = _prepare(operation);
  }

  Future<void> _prepare(DatabaseRecoveryOperation operation) async {
    try {
      final proposal = await operation.pickAndPrepare();
      if (!_current(operation) || operation.retired) return;
      _pickerTimer?.cancel();
      if (proposal == null) {
        await operation.closeSettled();
        if (!_current(operation) || operation.retired) return;
        _operation = null;
        _publish(const DatabaseRecoveryState());
      } else {
        _publish(
          DatabaseRecoveryState(
            phase: DatabaseRecoveryPhase.proposal,
            selectedPath: operation.selectedPath,
            proposal: proposal,
            operation: operation,
          ),
        );
      }
    } catch (error) {
      if (!_current(operation) || operation.retired) return;
      try {
        await operation.closeSettled();
        if (!_current(operation) || operation.retired) return;
        _operation = null;
        if (process!.normalOpeningBlocked) {
          _block(DatabaseRestoreCode.recoveryRequired);
        } else {
          _publish(
            DatabaseRecoveryState(
              code: _code(error),
              keyFailure: error is SupportCipherException
                  ? error.failure
                  : null,
            ),
          );
        }
      } catch (_) {
        _block(DatabaseRestoreCode.recoveryRequired);
      }
    } finally {
      _pickerTimer?.cancel();
    }
  }

  Future<void> confirm(
    DatabaseRecoveryOperation operation,
    DatabaseRestoreProposal proposal,
  ) {
    if (!_current(operation) ||
        operation.retired ||
        state.phase != DatabaseRecoveryPhase.proposal ||
        !identical(state.proposal, proposal) ||
        operation.confirmed)
      return Future<void>.value();
    _publish(
      DatabaseRecoveryState(
        phase: DatabaseRecoveryPhase.restoring,
        selectedPath: operation.selectedPath,
      ),
    ); // Latch before calling Core.
    return _work = _restore(operation, proposal);
  }

  Future<void> _restore(
    DatabaseRecoveryOperation operation,
    DatabaseRestoreProposal proposal,
  ) async {
    try {
      final result = await operation.confirmAndRestore(proposal);
      if (result.accepted case final accepted?) {
        process!.retainAccepted(accepted, operation.credentials!);
        if (!_current(operation) || operation.retired) {
          _block(DatabaseRestoreCode.recoveryRequired);
          return;
        }
        _entryLatched = true;
        _publish(
          const DatabaseRecoveryState(phase: DatabaseRecoveryPhase.entering),
        );
        await process!.finishAcceptedBootstrap(bootstrap);
        if (!_current(operation) || operation.retired) return;
        publishNormal(process!);
      } else {
        // Post-admission outcomes never silently open normal storage.
        _block(result.code);
      }
    } catch (error) {
      if (_current(operation)) _block(_code(error));
    }
  }

  Future<void> cancel() {
    final operation = _operation;
    if (operation == null || _cancelWork != null)
      return _cancelWork ?? Future<void>.value();
    _publish(
      const DatabaseRecoveryState(phase: DatabaseRecoveryPhase.cancelling),
    );
    final joined = operation
        .cancelAndJoin(); // Retire and signal before awaits.
    return _cancelWork = _cancel(operation, joined);
  }

  Future<void> _cancel(
    DatabaseRecoveryOperation operation,
    Future<void> joined,
  ) async {
    try {
      await joined;
      await _work; // Includes exact accepted retention, not merely Core result.
      if (!_current(operation)) return;
      if (operation.confirmed || process!.normalOpeningBlocked) {
        _block(state.code ?? DatabaseRestoreCode.recoveryRequired);
      } else {
        _operation = null;
        _publish(const DatabaseRecoveryState());
      }
    } catch (_) {
      if (_current(operation)) _block(DatabaseRestoreCode.recoveryRequired);
    } finally {
      _cancelWork = null;
    }
  }

  Future<void> continueNormally() {
    if (!_viewAlive ||
        _entryLatched ||
        state.busy ||
        _operation != null ||
        state.phase == DatabaseRecoveryPhase.blocked) {
      return Future<void>.value();
    }
    _entryLatched = true;
    _publish(
      const DatabaseRecoveryState(phase: DatabaseRecoveryPhase.entering),
    );
    return _work = _continueNormally();
  }

  Future<void> _continueNormally() async {
    try {
      await process!.openNormal(bootstrap);
      if (!_viewAlive || !ref.mounted) return;
      publishNormal(process!);
    } catch (error) {
      _block(_code(error));
    }
  }

  void retireView() {
    if (!_viewAlive) return;
    _viewAlive = false;
    _pickerTimer?.cancel();
    final operation = _operation;
    if (operation != null) {
      final original = operation.cancelAndJoin();
      unawaited(
        original.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  Future<void> joinForTesting() async {
    await _work;
    await _cancelWork;
  }

  void _block(DatabaseRestoreCode code) => _publish(
    DatabaseRecoveryState(phase: DatabaseRecoveryPhase.blocked, code: code),
  );
  static DatabaseRestoreCode _code(Object error) =>
      error is DatabaseRestoreException
      ? error.code
      : DatabaseRestoreCode.unavailable;
}
