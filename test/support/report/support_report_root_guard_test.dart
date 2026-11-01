import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_read_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_root_repo.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'support_report_native_fixture.dart';

void main() {
  late SupportReportNativeFixture fixture;
  setUp(() async {
    fixture = SupportReportNativeFixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.close());
  test(
    'real issued scope joins writer ROOT and excludes another WAL writer',
    () async {
      final other = sqlite.sqlite3.open(fixture.path);
      other.execute('PRAGMA busy_timeout=0');
      try {
        await fixture.root.read((scope) async {
          scope.check(fixture.database);
          expect(scope.belongsTo(fixture.database), isTrue);
          await SupportReportReadRepo(fixture.database).snapshot(
            originalRoot: scope,
            isCurrent: () => fixture.isCurrent,
            read: (snapshot) async {
              scope.check(fixture.database);
              expect(
                () => other.execute('BEGIN IMMEDIATE'),
                throwsA(isA<sqlite.SqliteException>()),
              );
              expect(snapshot.tableCount, 64);
            },
          );
          scope.check(fixture.database);
        });
        other.execute('BEGIN IMMEDIATE');
        other.execute('ROLLBACK');
      } finally {
        other.close();
      }
    },
  );
  test(
    'retired scope and ordinary caller-owned transaction cannot authorize report reads',
    () async {
      late NativeReportRootScope old;
      await fixture.root.read((scope) async {
        old = scope;
      });
      expect(old.belongsTo(fixture.database), isFalse);
      await expectLater(
        () => SupportReportReadRepo(fixture.database).snapshot(
          originalRoot: old,
          isCurrent: () => true,
          read: (snapshot) async {},
        ),
        throwsA(isA<SupportReportException>()),
      );
      await fixture.database.transaction(() async {
        await expectLater(
          fixture.root.read((scope) async {}),
          throwsA(isA<SupportReportException>()),
        );
      });
    },
  );
  test(
    'active proof from another actual native FILE database is rejected',
    () async {
      final foreign = SupportReportNativeFixture();
      await foreign.initialize();
      try {
        await fixture.root.read((scope) async {
          expect(scope.belongsTo(foreign.database), isFalse);
          await expectLater(
            () => SupportReportReadRepo(foreign.database).snapshot(
              originalRoot: scope,
              isCurrent: () => true,
              read: (snapshot) async {},
            ),
            throwsA(isA<SupportReportException>()),
          );
        });
      } finally {
        await foreign.close();
      }
    },
  );
}
