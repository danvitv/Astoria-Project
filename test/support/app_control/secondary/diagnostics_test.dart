import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'secondary_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecondaryFixture fixture;
  setUp(() async => fixture = await SecondaryFixture.create());
  tearDown(() async => fixture.close());

  Future<void> seed(String session, int sequence) async {
    await fixture.db
        .into(fixture.db.llmRequestCaptureRows)
        .insert(
          LlmRequestCaptureRowsCompanion.insert(
            sequence: sequence,
            createdAtMs: sequence,
            sessionId: Value(session),
            stage: const Value(secondaryPrivateCanary),
            callId: const Value(secondaryPrivateCanary),
            protocol: const Value(secondaryPrivateCanary),
            truncated: false,
            eventJson: jsonEncode({
              'messages': [secondaryPrivateCanary],
              'key': secondaryPrivateCanary,
            }),
          ),
        );
    await fixture.db
        .into(fixture.db.llmCallEventRows)
        .insert(
          LlmCallEventRowsCompanion.insert(
            id: 'owned-event-$sequence',
            createdAtMs: sequence,
            sessionId: Value(session),
            pipelineRunId: secondaryPrivateCanary,
            callId: secondaryPrivateCanary,
            stage: secondaryPrivateCanary,
            kind: 'transport_failed',
            responseText: const Value(secondaryPrivateCanary),
            error: const Value(secondaryPrivateCanary),
            parserDetail: const Value(secondaryPrivateCanary),
            payloadJson: Value(jsonEncode({'private': secondaryPrivateCanary})),
          ),
        );
  }

  test(
    'actual SQLite counts and original installed sink configuration exclude all private canaries',
    () async {
      await seed('owned-secondary-session', 1);
      await seed('owned-secondary-session', 2);
      await seed('owned-other-session', 3);
      final registry = fixture.registry();
      fixture.container.read(llmRequestCaptureInstallationProvider);
      final result = await registry.execute(
        secondaryCall('astoria_diagnostics_read'),
        fixture.context(),
      );
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'none');
      final data = secondaryData(result);
      expect(data['requestCount'], 2);
      expect(data['callEventCount'], 2);
      expect(data['requestCaptureInstalled'], true);
      expect(data['callEventCaptureInstalled'], true);
      expect(data['retentionMutable'], false);
      expect(data['health'], 'unknown');
      expect(data['credentialValidity'], 'unknown');
      expect(
        jsonEncode(result.content),
        isNot(contains(secondaryPrivateCanary)),
      );
      final raw = await fixture.db
          .select(fixture.db.llmRequestCaptureRows)
          .get();
      expect(raw.length, 3);
      expect(raw.first.eventJson, contains(secondaryPrivateCanary));
      expect(
        (await fixture.db.select(fixture.db.llmCallEventRows).get()).length,
        3,
      );
    },
  );

  test(
    'missing installed capture host is reported, not fabricated or enabled',
    () async {
      final registry = fixture.registry();
      final result = await registry.execute(
        secondaryCall('astoria_diagnostics_read'),
        fixture.context(),
      );
      expect(result.content['code'], 'completed');
      expect(secondaryData(result)['requestCaptureInstalled'], false);
      expect(secondaryData(result)['callEventCaptureInstalled'], false);
      expect(secondaryData(result)['requestCount'], 0);
    },
  );

  test(
    'no foreign session/body/retention fields, cancelled reads have no effect',
    () async {
      await seed('owned-secondary-session', 1);
      final registry = fixture.registry();
      for (final args in [
        {'sessionId': 'owned-other-session'},
        {'includeBodies': true},
        {'captureEnabled': false},
        {'maxBytesTotal': 1},
      ]) {
        final result = await registry.execute(
          secondaryCall('astoria_diagnostics_read', args),
          fixture.context(),
        );
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      final context = fixture.context()..cancelToken.cancel();
      final result = await registry.execute(
        secondaryCall('astoria_diagnostics_read'),
        context,
      );
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(
        (await fixture.db.select(fixture.db.llmRequestCaptureRows).get())
            .length,
        1,
      );
    },
  );
}
