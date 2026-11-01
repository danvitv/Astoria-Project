import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_root_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_report_native_composition.dart';

import 'support_report_native_fixture.dart';

void main() {
  test(
    'only the actual stock factory attests its executor and admits the real report ROOT',
    () async {
      final fixture = SupportReportNativeFixture();
      await fixture.initialize();
      final stock = AppDatabase.fixedNativeFile(
        File('${fixture.directory.path}${Platform.pathSeparator}stock.db'),
      );
      try {
        expect(fixture.database.hasAuditedStockSingleConnectionExecutor, false);
        expect(stock.hasAuditedStockSingleConnectionExecutor, true);
        final unknown = ProviderContainer(
          overrides: [appDbProvider.overrideWithValue(fixture.database)],
        );
        final known = ProviderContainer(
          overrides: [appDbProvider.overrideWithValue(stock)],
        );
        try {
          expect(
            unknown.read(supportReportNativeAdmissionContractProvider),
            isNull,
          );
          expect(
            known.read(supportReportNativeAdmissionContractProvider),
            SupportTextAdmissionContract
                .auditedRootSingleConnectionNoBusyHandler,
          );
        } finally {
          unknown.dispose();
          known.dispose();
        }
        await stock.customSelect('SELECT 1').get();
        final native = stock.nativeDataSourceIdentity!;
        final history = SupportTextContextRepo(
          db: stock,
          cipher: fixture.readCipher,
          currentRedactor: () => fixture.redactor,
          admissionContract: SupportTextAdmissionContract
              .auditedRootSingleConnectionNoBusyHandler,
        );
        final root = SupportReportRootRepo(
          database: stock,
          nativeSource: native,
          history: history,
          isCurrent: () => !stock.isClosing,
        );
        expect(
          await root.read((scope) async {
            scope.check(stock);
            expect(scope.belongsTo(fixture.database), false);
            final timeout = await stock
                .customSelect('PRAGMA busy_timeout')
                .getSingle();
            scope.check(stock);
            return timeout.read<int>('timeout');
          }),
          0,
        );
      } finally {
        await stock.close();
        await fixture.close();
      }
    },
  );
}
