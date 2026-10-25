import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/database_transaction_guard.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';
import 'package:glaze_flutter/core/db/models/session_repair.dart';
import 'package:glaze_flutter/core/db/repositories/database_maintenance_repo.dart';
import 'package:glaze_flutter/core/db/repositories/extension_presets_repository.dart';
import 'package:glaze_flutter/core/db/repositories/session_repair_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'database_maintenance/maintenance_fixture.dart';

final class _RejectedTransaction implements Exception {}

final class _TransactionProbe extends QueryInterceptor {
  _TransactionProbe({this.allowNesting = true});
  final bool allowNesting;
  int transactions = 0;
  int openings = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    transactions++;
    return parent.beginTransaction();
  }

  @override
  bool transactionCanBeNested(TransactionExecutor inner) => allowNesting;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    openings++;
    return executor.ensureOpen(user);
  }
}

final class _ClosingProbe extends _TransactionProbe {
  final closeGate = Completer<void>();
  final closeBegan = Completer<void>();
  bool closingStarted = false;
  bool denySelects = false;
  int selectAttempts = 0;

  @override
  Future<void> close(QueryExecutor executor) async {
    closingStarted = true;
    closeBegan.complete();
    await closeGate.future;
    await executor.close();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (denySelects) {
      selectAttempts++;
      throw StateError('Unexpected closing health query');
    }
    return executor.runSelect(statement, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  maintenanceTest('public entry guard refuses ambient zero-query work', (
    f,
  ) async {
    var entered = 0;
    Future<void> work() async {
      entered++;
    }

    Future<void> check() async {
      await Future<void>.value();
      await expectLater(
        outsideDatabaseTransaction(
          f.db,
          work,
          onRejected: _RejectedTransaction.new,
        ),
        throwsA(isA<_RejectedTransaction>()),
      );
      expect(entered, 0);
    }

    await f.db.transaction(check);
    await ExtensionPresetsRepository(f.db).transaction(check);
    for (final nesting in [true, false]) {
      final probe = _TransactionProbe(allowNesting: nesting);
      await f.db.runWithInterceptor(
        () => f.db.transaction(
          () => f.db.runWithInterceptor(check, interceptor: probe),
        ),
        interceptor: probe,
      );
      expect(probe.transactions, 1);
    }
    expect(entered, 0);
  });

  maintenanceTest(
    'public entry guard preserves separate commits and rollback',
    (f) async {
      final probe = _TransactionProbe();
      await f.db.runWithInterceptor(
        () => outsideDatabaseTransaction(f.db, () async {
          for (final id in ['guard-one', 'guard-two']) {
            await f.db.transaction(
              () => f.db.customStatement(
                'INSERT INTO character_folders (folder_id, name) VALUES (?, ?)',
                [id, MaintenanceFixture.canary],
              ),
            );
          }
        }, onRejected: _RejectedTransaction.new),
        interceptor: probe,
      );
      expect(probe.transactions, 2);
      final before = await f.snapshot();
      await expectLater(
        outsideDatabaseTransaction(
          f.db,
          () => f.db.transaction(() async {
            await f.db.customStatement(
              'DELETE FROM character_folders WHERE folder_id = ?',
              ['guard-one'],
            );
            throw _RejectedTransaction();
          }),
          onRejected: _RejectedTransaction.new,
        ),
        throwsA(isA<_RejectedTransaction>()),
      );
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'maintenance and session reads reject before target queries',
    (f) async {
      final sessions = SessionRepairRepo(f.db, f.support);
      f.events.clear();
      await f.db.transaction(() async {
        final health = await f.repo.inspect(isCurrent: f.isCurrent);
        expect(health.truncated, isTrue);
        expect(health.physical, DatabaseMaintenanceCheck.notChecked);
        expect(
          health.tables.every(
            (t) => t.schema == DatabaseMaintenanceCheck.notChecked,
          ),
          isTrue,
        );
        final analysis = await sessions.inspectLedgerAnalysis(
          targetSessionId: 'synthetic-target_0',
          supportSessionId: MaintenanceFixture.sessionId,
          isCurrent: f.isCurrent,
        );
        expect(analysis['analysis'], 'unavailable');
        expect(analysis['reason'], 'sourceChanged');
        final inspection = await sessions.inspect(
          targetSessionId: 'synthetic-target_0',
          supportSessionId: MaintenanceFixture.sessionId,
          isCurrent: f.isCurrent,
        );
        expect(inspection.complete, isFalse);
        expect(inspection.issues, contains(SessionRepairIssue.authorityDenied));
      });
      expect(f.events.where((e) => e.startsWith('select:')), isEmpty);
    },
  );

  maintenanceTest(
    'health context inspection never opens an unopened database',
    (f) async {
      final probe = _TransactionProbe();
      final unopened = AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(probe),
      );
      try {
        final repo = DatabaseMaintenanceRepo(
          unopened,
          SupportRepo(unopened, f.cipher),
        );
        expect(unopened.hasCompletedOpening, isFalse);
        final report = await repo.inspect(isCurrent: f.isCurrent);
        expect(unopened.hasCompletedOpening, isFalse);
        expect(probe.openings, 0);
        expect(probe.transactions, 0);
        expect(report.actualVersion, isNull);
        expect(report.physical, DatabaseMaintenanceCheck.unknown);
      } finally {
        await unopened.close();
      }
    },
  );

  maintenanceTest('closing ambient health refuses before selects or opening', (
    f,
  ) async {
    final probe = _ClosingProbe();
    final db = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(probe),
    );
    final repo = DatabaseMaintenanceRepo(db, SupportRepo(db, f.cipher));
    Future<void>? closing;
    try {
      await db.customSelect('SELECT 1').get();
      await db.transaction(() async {
        closing = db.close();
        await probe.closeBegan.future;
        expect(probe.closingStarted, isTrue);
        expect(db.isClosing, isTrue);
        probe.denySelects = true;
        final beforeOpening = probe.openings;
        final report = await repo.inspect(isCurrent: () => true);
        expect(report.truncated, isTrue);
        expect(report.physical, DatabaseMaintenanceCheck.notChecked);
        expect(
          report.tables.every(
            (t) => t.schema == DatabaseMaintenanceCheck.notChecked,
          ),
          isTrue,
        );
        expect(probe.selectAttempts, 0);
        expect(probe.openings, beforeOpening);
      });
    } finally {
      probe.closeGate.complete();
      await (closing ?? db.close());
    }
  });
}
