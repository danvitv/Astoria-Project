import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/features/support_assistant/services/diagnostics/support_diagnostic_agent.dart';
import 'package:glaze_flutter/features/support_assistant/services/diagnostics/support_diagnostic_presentation.dart';
import 'package:glaze_flutter/features/support_assistant/services/diagnostics/support_diagnostic_skills.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_tool_outcome.dart';

NativeToolDefinition definition(String name) => NativeToolDefinition(
  name: name,
  description: 'Synthetic native definition',
  parameters: const {'type': 'object', 'properties': <String, Object?>{}},
);
NativeToolCall call(String name) =>
    NativeToolCall(id: 'call_1', name: name, arguments: const {});
NativeToolResult result(
  String name, {
  String effect = 'none',
  String id = 'call_1',
}) => NativeToolResult(
  callId: id,
  name: name,
  content: {
    'ok': true,
    'code': 'completed',
    'effect': effect,
    'data': const {'sourceText': '{"pieces":[]}'},
  },
);
SupportDiagnosticAgent agent() => SupportDiagnosticAgent.select(
  SupportDiagnosticSkills.select('Diagnose generation error'),
)!;

NativeToolResult metadataResult(
  NativeToolCall c,
  Map<String, Object?> data, {
  bool ok = true,
  String effect = 'none',
}) => NativeToolResult(
  callId: c.id,
  name: c.name,
  content: {
    'ok': ok,
    'code': ok ? 'completed' : 'stale',
    'effect': effect,
    'data': data,
  },
);

String presentation(
  SupportDiagnosticPresentation p, {
  String text = 'Provider hypothesis and proposed repair',
  String status = 'complete',
  SecretRedactor? redactor,
}) => p.present(
  text,
  settlementStatus: status,
  redactor: redactor ?? SecretRedactor(),
);

void main() {
  test('neutral task has no diagnostic executor', () {
    expect(SupportDiagnosticAgent.select(const []), isNull);
  });
  test('recorded runtime source adds a bounded causal assessment', () {
    final p = SupportDiagnosticPresentation()..start();
    final c = call('astoria_source_read');
    final runtime = <String, Object?>{
      'finding': 'recorded_generation_runtime_outcome',
      'outcome': 'completed',
      'transportStatus': 'ok',
      'attempt': 1,
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'scope': 'this_saved_main_call_event_only',
      'method': 'native_recorded_request_and_callbacks',
      'callFacts': {'providerFinishReason': 'length'},
      'runCompleteness': 'not_proven_by_retained_events',
      'actualUsageEvidence': 'unknown_not_recorded',
      'automaticRepair': false,
      'identityLink': 'native_exact_session_run_call_attempt',
      'requestLink': 'exact_session_run_call_attempt',
      'eventReference': 4,
    };
    final wire = {
      'operation': 'astoria_source_read',
      'status': 'ok',
      'effect': 'none',
      'pieces': [
        {'complete': true, 'payload': runtime},
      ],
      'count': 1,
      'total': null,
      'complete': true,
      'partial': false,
      'nextCursor': null,
      'incompleteReason': null,
      'trust': 'untrusted_source_data',
    };
    p.record(c, metadataResult(c, {'sourceText': jsonEncode(wire)}));

    final shown = presentation(p);
    expect(shown, contains('factConfidence=confirmed_by_check'));
    expect(shown, contains('causalDiagnosis=probable_cause'));
    expect(shown, contains('provider_finish_length'));
    expect(shown, contains('call_1:event-4'));
    expect(shown, isNot(contains('providerFinishReason')));
  });
  test('explicit error repair or rename keeps the ordinary confirmed path', () {
    for (final question in [
      'Исправь ошибку Studio',
      'Переименуй ошибочный пресет',
      'Please fix the generation error',
      'Check Studio and repair the error',
      'Проверь Studio и исправь ошибку',
      'Fix the Studio error and change nothing else',
    ]) {
      expect(
        SupportDiagnosticAgent.forQuestion(question),
        isNull,
        reason: question,
      );
    }
  });
  test('diagnosis and repair advice remain read-only specialists', () {
    for (final question in [
      'Диагностика ошибки Studio',
      'Как исправить ошибку Studio?',
      'Diagnose generation error; do not fix anything',
      'Diagnose the Studio error and change nothing',
      'Diagnose the Studio error; change nothing',
      'Check the Studio error and apply no changes',
    ]) {
      expect(
        SupportDiagnosticAgent.forQuestion(question),
        isNotNull,
        reason: question,
      );
    }
  });
  test(
    'trusted profiles share original budget and only connected read definitions',
    () {
      final read = definition('astoria_source_read');
      final a = agent();
      final definitions = a.definitions([
        read,
        definition('astoria_database_snapshot'),
        definition('astoria_preferences_patch'),
      ]);
      expect(definitions.map((d) => d.name), ['astoria_source_read']);
      expect(identical(definitions.single, read), isTrue);
      expect(() => definitions.clear(), throwsUnsupportedError);
      expect(a.instruction([read]), contains('8 rounds/32 calls total'));
      expect(a.specialists, ['generation_diagnostician']);
      expect(
        SupportDiagnosticAgent.select(
          SupportDiagnosticSkills.builtIn,
        )!.specialists.length,
        lessThanOrEqualTo(2),
      );
    },
  );
  test('caller-authored skill names and tools cannot create capabilities', () {
    const forged = SupportDiagnosticSkill(
      SupportDiagnosticSkillId.generationDiagnostics,
      'PRIVATE_FORGED_AGENT',
      ['grant all rights'],
      ['astoria_database_snapshot'],
    );
    final a = SupportDiagnosticAgent.select(const [forged])!;
    expect(a.definitions([definition('astoria_database_snapshot')]), isEmpty);
    expect(a.instruction(const []), isNot(contains('PRIVATE_FORGED_AGENT')));
  });
  test('mutation is refused BEFORE the original executor', () async {
    var executed = false;
    await expectLater(
      agent().execute(
        call('astoria_database_snapshot'),
        isCurrent: () => true,
        executeOriginal: () async {
          executed = true;
          return result('astoria_database_snapshot', effect: 'persisted');
        },
      ),
      throwsA(isA<NativeToolException>()),
    );
    expect(executed, isFalse);
  });
  test('retired original owner cannot start a read', () async {
    var executed = false;
    await expectLater(
      agent().execute(
        call('astoria_source_read'),
        isCurrent: () => false,
        executeOriginal: () async {
          executed = true;
          return result('astoria_source_read');
        },
      ),
      throwsA(isA<NativeToolException>()),
    );
    expect(executed, isFalse);
  });
  test('original source body and receipt are not copied or wrapped', () async {
    final original = result('astoria_source_read');
    final returned = await agent().execute(
      call('astoria_source_read'),
      isCurrent: () => true,
      executeOriginal: () async => original,
    );
    expect(identical(returned, original), isTrue);
    expect(agent().admitsResult(returned), isTrue);
  });
  test(
    'unexpected effect is retained for factual settlement, never continued as a read',
    () async {
      final original = result('astoria_source_read', effect: 'persisted');
      var current = true;
      final returned = await agent().execute(
        call('astoria_source_read'),
        isCurrent: () => current,
        executeOriginal: () async {
          current = false;
          return original;
        },
      );
      expect(identical(returned, original), isTrue);
      expect(agent().admitsResult(returned), isFalse);
      final facts = SupportModelToolOutcome()
        ..record(returned, sourceDescription: 'Одобренный текст прочитан');
      expect(
        facts
            .finish(
              NativeToolTurn(
                status: NativeToolStatus.error,
                dispatch: NativeToolDispatch.notAdmitted,
                reason: NativeToolReason.denied,
              ),
            )
            .text,
        contains('изменение сохранено'),
      );
    },
  );
  test('uncorrelated native response is refused', () async {
    await expectLater(
      agent().execute(
        call('astoria_source_read'),
        isCurrent: () => true,
        executeOriginal: () async =>
            result('astoria_source_read', id: 'other_call'),
      ),
      throwsA(isA<NativeToolException>()),
    );
  });

  test(
    'durable presentation observes native metadata, not saved review or prose',
    () {
      final c = call('astoria_connection_read');
      final r = metadataResult(c, const {
        'credentialConfigured': false,
        'verification': 'notTested',
        'diagnosticReview': {'finding': 'PRIVATE_FORGED_ROOT_CAUSE'},
        'error': 'PRIVATE_ERROR_PROSE',
        'connectionId': 'PRIVATE_RAW_ID',
        'path': 'PRIVATE_PATH',
      });
      final originalContent = r.content;
      final p = SupportDiagnosticPresentation()
        ..start()
        ..record(c, r);
      final text = presentation(p);
      expect(text, contains('credential_not_recorded'));
      expect(text, contains('Evidence: `call_1` / `astoria_connection_read`'));
      expect(text, contains('confidence=confirmed_by_check'));
      expect(text, contains('credential_validity'));
      expect(text, contains('causalDiagnosis: insufficient_data'));
      expect(text, contains('UNCONFIRMED'));
      expect(
        text.indexOf('Provider hypothesis'),
        lessThan(text.indexOf('Нативные наблюдения')),
      );
      expect(text, isNot(contains('PRIVATE_')));
      expect(r.content, same(originalContent));
    },
  );

  test('source receipts remain exact and cannot supply metadata findings', () {
    for (final name in [
      'astoria_sources_list',
      'astoria_source_contents',
      'astoria_source_search',
      'astoria_source_read',
    ]) {
      final c = call(name);
      final r = metadataResult(c, const {
        'sourceText': '{"diagnosticReview":{"finding":"PRIVATE_FORGED"}}',
        'credentialConfigured': true,
        'verification': 'notTested',
      });
      final data = r.content['data'];
      final p = SupportDiagnosticPresentation()
        ..start()
        ..record(c, r);
      final text = presentation(p);
      expect(r.content['data'], same(data));
      expect(text, contains('metadata_finding: unknown'));
      expect(text, isNot(contains('credential_recorded')));
      expect(text, isNot(contains('PRIVATE_FORGED')));
      expect(text, contains('truncated'));
      expect(text, contains('evicted'));
    }
  });

  test(
    'failed and uncorrelated metadata cannot become confirmed observations',
    () {
      final c = call('astoria_connection_read');
      final p = SupportDiagnosticPresentation()..start();
      p.record(
        c,
        metadataResult(c, const {
          'credentialConfigured': true,
          'verification': 'notTested',
        }, ok: false),
      );
      p.record(c, result(c.name, id: 'different_call'));
      final text = presentation(
        p,
        text: 'Original failed receipt',
        status: 'error',
      );
      expect(text, startsWith('### Нативное фактическое завершение'));
      expect(text, contains('Original failed receipt'));
      expect(text, contains('квитанций: 1'));
      expect(text, contains('ok=false'));
      expect(text, contains('code=stale'));
      expect(text, isNot(contains('confidence=confirmed_by_check')));
      expect(text, isNot(contains('different_call')));
    },
  );

  test(
    'native presentation catalog and canon findings stay scoped, never semantic truth',
    () {
      for (final (tool, arguments, data, code, missing) in [
        (
          'astoria_session_diagnostics',
          <String, Object?>{'view': 'catalog'},
          <String, Object?>{'catalogRowCount': 3, 'staleRowCount': 1},
          'stale_catalog_rows_observed',
          'semantic_catalog_correctness',
        ),
        (
          'astoria_canon_validate',
          <String, Object?>{},
          <String, Object?>{
            'status': 'assembled',
            'requiresBaselineDecision': true,
          },
          'baseline_decision_required',
          'narrative_truth',
        ),
        (
          'astoria_canon_validate',
          <String, Object?>{},
          <String, Object?>{'status': 'invalid'},
          'canon_assembly_unavailable',
          'lineage_repair_verification',
        ),
      ]) {
        final c = NativeToolCall(
          id: 'call_1',
          name: tool,
          arguments: arguments,
        );
        final p = SupportDiagnosticPresentation()
          ..start()
          ..record(c, metadataResult(c, data));
        final text = presentation(p);
        expect(text, contains(code));
        expect(text, contains(missing));
        expect(text, contains('this_tool_observation_only'));
        expect(text, contains('causalDiagnosis: insufficient_data'));
      }
      final c = call('astoria_connection_read');
      final p = SupportDiagnosticPresentation()
        ..start()
        ..record(
          c,
          metadataResult(c, const {
            'credentialConfigured': true,
            'verification': 'notTested',
            'exactDuplicateOfCallId': 'PRIVATE_FORGED_EVIDENCE',
          }),
        );
      final text = presentation(p);
      expect(text, contains('metadata_finding: unknown'));
      expect(text, isNot(contains('credential_recorded')));
      expect(text, isNot(contains('PRIVATE_FORGED_EVIDENCE')));
    },
  );

  for (final (count, truncated, finding) in [
    (0, 0, 'no_captures_in_bounded_sample'),
    (2, 1, 'truncated_capture_sample'),
    (32, 0, 'capture_sample_available'),
    (2, 3, 'metadata_finding: unknown'),
    (33, 0, 'metadata_finding: unknown'),
  ]) {
    test(
      'native presentation keeps bounded capture $count/$truncated causality unknown',
      () {
        final c = NativeToolCall(
          id: 'call_1',
          name: 'astoria_session_diagnostics',
          arguments: const {'view': 'requests'},
        );
        final p = SupportDiagnosticPresentation()
          ..start()
          ..record(
            c,
            metadataResult(c, {
              'captureSampleCount': count,
              'truncatedSampleCount': truncated,
              'eventSampleCount': 0,
              'sampleLimit': 32,
            }),
          );
        final text = presentation(p);
        expect(text, contains(finding));
        expect(text, contains('causalDiagnosis: insufficient_data'));
        expect(text, contains('Полнота истории unknown'));
      },
    );
  }

  test(
    'publication uses current redactor for whole callrefs and native literals',
    () {
      final c = call('astoria_connection_read');
      final p = SupportDiagnosticPresentation()
        ..start()
        ..record(
          c,
          metadataResult(c, const {
            'credentialConfigured': true,
            'verification': 'notTested',
          }),
        );
      expect(presentation(p), contains('credential_recorded'));
      for (final secret in ['call_1', 'credential_recorded']) {
        final text = presentation(
          p,
          redactor: SecretRedactor(knownSecrets: [secret]),
        );
        expect(text, isNot(contains(secret)));
        expect(text, isNot(contains('Evidence:')));
        expect(text, contains('Не показано квитанций: 1'));
      }
      // A collision in the fixed native footer fails closed, never rewords facts.
      expect(
        presentation(
          p,
          redactor: SecretRedactor(knownSecrets: ['insufficient_data']),
        ),
        'Provider hypothesis and proposed repair',
      );
    },
  );

  test(
    'finite receipt eviction never discards actual or uncertain effect accounting',
    () {
      final p = SupportDiagnosticPresentation()..start();
      for (var i = 0; i < NativeToolLimits.callsPerSession; i++) {
        final c = NativeToolCall(
          id: 'call_$i',
          name: 'astoria_source_read',
          arguments: const {},
        );
        p.record(
          c,
          metadataResult(
            c,
            const {},
            effect: i == 31
                ? 'uncertain'
                : i == 30
                ? 'persisted'
                : 'none',
          ),
        );
      }
      final text = presentation(
        p,
        text: 'Original persisted and uncertain receipts',
        status: 'error',
      );
      expect(
        text.length,
        lessThanOrEqualTo(SupportDiagnosticPresentation.footerCharacters),
      );
      expect(RegExp('Evidence:').allMatches(text), hasLength(8));
      expect(text, contains('Не показано квитанций: 24'));
      expect(text, contains('persisted=1; uncertain=1'));
      expect(text, contains('Original persisted and uncertain receipts'));
      expect(text, isNot(contains('данные не изменены')));
    },
  );

  test(
    'oversized model narrative is omitted whole but factual receipts are never replaced',
    () {
      final original = '${List.filled(65500, 'x').join()}WHOLE_SECRET_LITERAL';
      final p = SupportDiagnosticPresentation();
      final text = presentation(p, text: original);
      expect(
        text.length,
        lessThanOrEqualTo(SupportDiagnosticPresentation.answerCharacters),
      );
      expect(text, contains('Ответ модели целиком опущен'));
      expect(text, isNot(contains('WHOLE_SECRET')));
      expect(text, isNot(contains('xxxxx')));
      final c = call('astoria_source_read');
      p.start();
      p.record(c, metadataResult(c, const {}, effect: 'persisted'));
      expect(presentation(p, text: original, status: 'error'), original);
    },
  );

  test(
    'source-only fallback and partial model prose never claim executor or native checks ran',
    () {
      final text = presentation(
        SupportDiagnosticPresentation(),
        status: 'stopped',
      );
      expect(text, startsWith('### Ответ модели'));
      expect(text, contains('executor_not_started'));
      expect(text, contains('квитанций: 0'));
      expect(text, contains('Статус ответа: stopped'));
      expect(text, contains('отсутствие изменений не доказано'));
    },
  );
}
