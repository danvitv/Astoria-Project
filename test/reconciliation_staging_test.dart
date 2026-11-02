import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_reconciliation_source.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_staging.dart';

Map<String, dynamic> _data(List<Map<String, dynamic>> rows) => {
  '__reconciliationState': true,
  'sessionId': 'staging-test',
  'schemaVersion': 2,
  for (final section in ReconciliationSection.values)
    section.name: section == ReconciliationSection.manifests
        ? rows
        : <dynamic>[],
};

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    final local = Platform.environment['LOCALAPPDATA'];
    final parent = local == null
        ? Directory.systemTemp
        : Directory('$local/Temp/opencode');
    temporaryRoot = await parent.createTemp('reconciliation-staging-test-');
  });
  tearDown(() async {
    expect(await temporaryRoot.list().toList(), isEmpty);
    await temporaryRoot.delete();
  });

  test(
    'buffer flushes, large-row bypass and final tails preserve exact NDJSON',
    () async {
      final rows = [
        for (var index = 0; index < 3000; index++)
          {'messageId': 'small-$index', 'manifestJson': 'retained Ж\n'},
        {'messageId': 'large', 'manifestJson': 'large Ж\n' * 32768},
        {'messageId': 'tail', 'manifestJson': 'final row'},
      ];
      final source = MapReconciliationStateSource(_data(rows));
      final fingerprint = await ReconciliationJsonCodec.fingerprint(source);
      final staging = await ReconciliationStaging.capture(
        source,
        temporaryRoot: temporaryRoot,
      );
      try {
        expect(staging.fingerprint.hash, fingerprint.hash);
        expect(staging.fingerprint.jsonBytes, fingerprint.jsonBytes);
        expect(staging.counts[ReconciliationSection.manifests], rows.length);
        expect(
          await staging.file(ReconciliationSection.manifests).readAsString(),
          rows.map((row) => '${jsonEncode(row)}\n').join(),
        );
        expect(
          await staging.readSection(ReconciliationSection.manifests).toList(),
          rows,
        );
        for (final section in ReconciliationSection.values) {
          if (section != ReconciliationSection.manifests) {
            expect(await staging.file(section).length(), 0);
          }
        }
      } finally {
        await staging.dispose();
      }
    },
  );

  test(
    'oversized row disposes staging with previously buffered rows',
    () async {
      final source = MapReconciliationStateSource(
        _data([
          {
            'messageId': 'small',
            'manifestJson': 'buffered but not yet flushed',
          },
          {
            'messageId': 'oversized',
            'manifestJson': 'x' * ReconciliationJsonCodec.maxRecordBytes,
          },
        ]),
      );
      await expectLater(
        ReconciliationStaging.capture(source, temporaryRoot: temporaryRoot),
        throwsFormatException,
      );
      expect(await temporaryRoot.list().toList(), isEmpty);
    },
  );
}
