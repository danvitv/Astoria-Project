import 'dart:convert';

import 'package:drift/drift.dart';

import '../../services/android_snapshot_namespace.dart';
import '../../services/database_snapshot_service.dart';
import '../database_transaction_guard.dart';

/// Only fixed native control SQL, on the exact original Drift connection.
final class DatabaseBackgroundSnapshotSourceRepo {
  DatabaseBackgroundSnapshotSourceRepo({
    required DatabaseConnectionUser database,
    required AndroidSnapshotNamespace namespace,
    required String sourcePath,
    required Set<String> registeredTables,
    required bool Function() isCurrent,
    required Future<void> Function(Future<void> Function()) joinLifetime,
    required void Function(Object) retainUnsettled,
  }) : _database = database,
       _joinLifetime = joinLifetime,
       source = NativeBackgroundDatabaseSnapshotSource(
         namespace: namespace,
         sourcePath: sourcePath,
         registeredTableNames: registeredTables,
         isCurrent: isCurrent,
         retainUnsettled: retainUnsettled,
       ) {
    source.bind(
      exclusively: runOriginalScope,
      inReadTransaction: runReadTransaction,
      command: runWorkerCommand,
    );
  }

  final DatabaseConnectionUser _database;
  final Future<void> Function(Future<void> Function()) _joinLifetime;
  final NativeBackgroundDatabaseSnapshotSource source;

  Future<void> runOriginalScope(Future<void> Function() work) => _joinLifetime(
    () => outsideDatabaseTransaction(
      _database,
      () => _database.exclusively(work),
      onRejected: () =>
          StateError('Snapshot needs an original transaction scope'),
    ),
  );

  Future<void> runReadTransaction(Future<void> Function() work) =>
      _database.transaction(work);

  Future<Map<String, Object?>> runWorkerCommand(
    String command,
    String token,
  ) async {
    if (!const {
          'check',
          'start',
          'step',
          'finish',
          'abort',
        }.contains(command) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw StateError('Invalid native snapshot command');
    }
    // Abort/check must still join the original worker after cancellation/close.
    // The enclosing lifetime fence keeps this exact executor alive until then.
    final rows = await _database
        .customSelect(
          'SELECT astoria_native_snapshot(?, ?, ?) AS result',
          variables: [
            Variable.withString(command),
            Variable.withString(token),
            Variable.withString(
              command == 'start'
                  ? jsonEncode(source.registeredTableNames.toList())
                  : '',
            ),
          ],
        )
        .get();
    if (rows.length != 1) throw StateError('Invalid native snapshot reply');
    final raw = rows.single.read<String>('result');
    if (raw.length > 256) throw StateError('Invalid native snapshot reply');
    final reply = jsonDecode(raw);
    if (reply is! Map<String, dynamic> ||
        reply['closed'] is! bool ||
        !const {
          'ready',
          'progress',
          'verified',
          'closed',
          'unavailable',
          'invalid',
          'tooLarge',
          'uncertain',
        }.contains(reply['status']) ||
        reply.keys.any(
          (key) => !const {'status', 'closed', 'tableCount'}.contains(key),
        ) ||
        (reply.containsKey('tableCount') &&
            (reply['status'] != 'verified' ||
                reply['tableCount'] is! int ||
                (reply['tableCount'] as int) < 1 ||
                (reply['tableCount'] as int) > 512))) {
      throw StateError('Invalid native snapshot reply');
    }
    return Map<String, Object?>.from(reply);
  }
}
