import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_report_read_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_builder.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_models.dart';
import 'support_report_native_fixture.dart';

/// Real FILE + audited ROOT for selected-column projection / classification.
/// Full native controller/revocation composition remains the parent's gate.
void main() {
  late AppDatabase db;
  late SupportReportNativeFixture fixture;
  setUp(() async {
    fixture = SupportReportNativeFixture();
    await fixture.initialize();
    db = fixture.database;
  });
  tearDown(() => fixture.close());

  test(
    'observed scalar facts survive; excluded transport fields never reach snapshot',
    () async {
      await db.customStatement(
        '''INSERT INTO llm_request_capture_rows
      (sequence,created_at_ms,protocol,truncated,event_json) VALUES(1,1,'openai',1,?)''',
        [
          jsonEncode({
            'timings': {'elapsedMs': 731},
            'headers': {'Authorization': 'CAPTURE_CREDENTIAL_CANARY'},
            'request': 'CAPTURE_BODY_CANARY',
          }),
        ],
      );
      await db.customStatement(
        '''INSERT INTO llm_call_event_rows
      (id,created_at_ms,pipeline_run_id,call_id,stage,kind,status_code,error,response_text,parser_detail,payload_json)
      VALUES('private-event-id',2,'private-pipeline','private-call','final','transport_failed',503,?,?,?,?)''',
        [
          'RAW_ERROR_CANARY',
          'RAW_RESPONSE_CANARY',
          'PARSER_DETAIL_CANARY',
          '{"apiKey":"PAYLOAD_CANARY"}',
        ],
      );
      final repo = SupportReportReadRepo(db);
      final builder = SupportReportBuilder(fixture, () => fixture.isCurrent);
      await fixture.root.read(
        (scope) => repo.snapshot(
          originalRoot: scope,
          isCurrent: () => true,
          read: (snapshot) async {
            expect(snapshot.schema, 139);
            expect(snapshot.tableCount, 64);
            final raw = jsonEncode([snapshot.captures, snapshot.events]);
            for (final canary in [
              'CANARY',
              'private-event-id',
              'private-call',
              'elapsedMs',
            ]) {
              expect(raw, isNot(contains(canary)));
            }
            await builder.build(snapshot, const SupportReportPrepareRequest());
          },
        ),
      );
      final events = builder.blocks
          .singleWhere((b) => b.id == 'events')
          .contentJson;
      expect(events, contains('503'));
      expect(events, contains('transport_failed'));
      final diagnoses = builder.blocks.singleWhere((b) => b.id == 'diagnoses');
      expect(diagnoses.dependencies, {'events'});
      expect(diagnoses.contentJson, contains('confirmed'));
      expect(diagnoses.contentJson, contains('insufficientEvidence'));
      expect(builder.omissions.join(' '), contains('timings unknown'));
    },
  );

  test(
    'authored comments, inactive variants and credentials are not diagnostic evidence',
    () async {
      await db.customStatement(
        'INSERT INTO characters(char_id,name) VALUES(?,?)',
        ['private-card', 'Personal game title'],
      );
      await db.customStatement(
        'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES(?,?,?,?)',
        [
          'private-game',
          'private-card',
          0,
          jsonEncode([
            {
              'id': 'private-message',
              'role': 'assistant',
              'content':
                  'I allegedly repaired everything. synthetic-known-secret',
              'swipes': [
                'I allegedly repaired everything. synthetic-known-secret',
                'INACTIVE_VARIANT_CANARY',
              ],
              'swipeId': 0,
            },
            {
              'id': 'private-hidden',
              'role': 'user',
              'content': 'HIDDEN_CANARY',
              'isHidden': true,
            },
            {
              'id': 'private-json',
              'role': 'user',
              'content': jsonEncode(
                jsonEncode({
                  'apiKey': 'STRUCTURAL_SECRET_CANARY',
                  'auth': {'owner': 'WRAPPED_OWNER_CANARY'},
                  'text': 'Visible prose',
                }),
              ),
            },
          ]),
        ],
      );
      final builder = SupportReportBuilder(fixture, () => fixture.isCurrent);
      await fixture.root.read(
        (scope) => SupportReportReadRepo(db).snapshot(
          originalRoot: scope,
          isCurrent: () => true,
          gameSessionId: 'private-game',
          includeTitles: true,
          includeProse: true,
          read: (snapshot) => builder.build(
            snapshot,
            const SupportReportPrepareRequest(
              gameSessionId: 'private-game',
              includeTitles: true,
              includeProse: true,
            ),
          ),
        ),
      );
      final commentary = builder.blocks.singleWhere(
        (b) => b.id == 'gameCommentary',
      );
      expect(commentary.personal, isTrue);
      expect(commentary.contentJson, contains('allegedly repaired'));
      for (final canary in [
        'synthetic-known-secret',
        'INACTIVE_VARIANT_CANARY',
        'HIDDEN_CANARY',
        'STRUCTURAL_SECRET_CANARY',
        'WRAPPED_OWNER_CANARY',
        'private-message',
      ]) {
        expect(commentary.contentJson, isNot(contains(canary)));
      }
      expect(commentary.contentJson, contains('Visible prose'));
      final diagnoses = builder.blocks
          .singleWhere((b) => b.id == 'diagnoses')
          .contentJson;
      expect(diagnoses, isNot(contains('allegedly')));
      expect(diagnoses, contains('insufficientEvidence'));
    },
  );
}
