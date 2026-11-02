import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/models/keyless_api_config.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

import '../support_app_backup_loop_fixture.dart';

// Reuse the existing original native FILE/UI fixture, not a replacement reader
// or controller. Its owned synthetic directory and no-egress tripwires remain.
Map<String, Object?> call(
  String id,
  String name,
  Map<String, Object?> args, {
  String? prose,
}) => {
  'choices': [
    {
      'index': 0,
      'finish_reason': 'tool_calls',
      'message': {
        'role': 'assistant',
        'content': prose,
        'tool_calls': [
          {
            'type': 'function',
            'id': id,
            'function': {'name': name, 'arguments': jsonEncode(args)},
          },
        ],
      },
    },
  ],
};
Map<String, Object?> answer([
  String narrative =
      'Metadata recorded; validity and failure cause remain unknown.',
]) => {
  'choices': [
    {
      'index': 0,
      'finish_reason': 'stop',
      'message': {'role': 'assistant', 'content': narrative},
    },
  ],
};
String system(BackupLoopFixture f) =>
    ((f.wire.first['messages'] as List).firstWhere((m) => m['role'] == 'system')
            as Map)['content']
        as String;
List<Map<String, dynamic>> toolResults(BackupLoopFixture f) =>
    (f.wire.last['messages'] as List)
        .where((m) => m['role'] == 'tool')
        .map(
          (m) => (jsonDecode(m['content'] as String) as Map)
              .cast<String, dynamic>(),
        )
        .toList();

Future<String> allowRead(WidgetTester tester, BackupLoopFixture f) async {
  final native = f.native;
  final id = await backupLoopReal(tester, () async {
    expect(native.db.nativeDataSourceIdentity?.belongsTo(native.db), isTrue);
    // The backup transport seed retains embeddingUseSame=true and is not a
    // keyless record. Create the diagnostic target through the actual native
    // repository; never relax its legacy/embedding/credential shape checks.
    expect(await native.apiRepo.inspectKeyless(native.api.id), isNull);
    final draft = KeylessApiConfigDraft(
      nativeId: NativeKeylessConnectionId.generate(),
      displayName: 'Synthetic diagnostic connection',
      providerId: native.api.providerId,
      protocol: native.api.protocol,
      endpoint: native.api.endpoint,
      model: native.api.model,
      maxTokens: 512,
      contextSize: 32000,
      temperature: 0.25,
    );
    final receipt = await native.apiRepo.createKeyless(
      draft: draft,
      isCurrent: () => native.rootCurrent,
    );
    expect(receipt, isNotNull);
    final target = (await native.apiRepo.getById(receipt!.connectionId))!;
    final reference = native.native.auth.referenceFor(
      target,
      NativeProviderPurpose.astoria,
    )!;
    final review = await native.native.secretEntry.review(
      connection: reference,
      purposes: const {NativeProviderPurpose.astoria},
      lifetime: NativeProviderViewLifetime(isCurrent: () => native.rootCurrent),
    );
    await native.native.credentials.storeFromNativeEntry(
      permit: native.native.secretEntry.confirmNativeEntry(review),
      secret: BackupLoopNative.key,
    );
    await native.permissions.initializeGlobalFromNative(
      native.session,
      isCurrent: () => native.rootCurrent,
    );
    await native.permissions.setGrantFromNative(
      native.session,
      SupportPermission.readApplicationData,
      true,
      isCurrent: () => native.rootCurrent,
    );
    await native.runtime.refresh(resolve: true);
    return target.id;
  });
  await tester.pump();
  return id;
}

void main() {
  backupLoopTest(
    'diagnostic specialist refuses provider snapshot BEFORE native file picker or effect',
    (tester, f) async {
      final id = await allowRead(tester, f);
      final writes = f.native.storage.writeKeys.length;
      final saved = await backupLoopReal(
        tester,
        () => f.native.apiRepo.inspectKeyless(id),
      );
      f.replies.addAll([
        call('call_1', 'astoria_database_snapshot', const {}),
        answer(),
      ]);
      await f.start(tester, picker: false, text: 'Diagnose generation error');
      final refused = await f.finish(tester);
      expect(refused.status, 'error');
      expect(refused.body, contains('Статус ответа: error'));
      expect(refused.body, contains('квитанций: 0'));
      expect(refused.body, isNot(contains('confidence=confirmed_by_check')));
      expect(f.wire, hasLength(1));
      expect(f.dialog.choices, 0);
      expect(f.native.storage.writeKeys.length, writes);
      await backupLoopReal(
        tester,
        () async => expect(
          f.native.apiRepo.sameKeylessObservation(
            saved!,
            (await f.native.apiRepo.inspectKeyless(id))!,
          ),
          isTrue,
        ),
      );
      f.noEgress(refused.body);
    },
  );
  backupLoopTest(
    'diagnostic native Send uses curated advice and actual metadata observation before correlated POST',
    (tester, f) async {
      final id = await allowRead(tester, f);
      final native = f.native;
      final writes = native.storage.writeKeys.length;
      final saved = await backupLoopReal(
        tester,
        () => native.apiRepo.inspectKeyless(id),
      );
      f.replies.addAll([
        call('call_1', 'astoria_connection_read', {'connectionId': id}),
        answer(),
      ]);
      await f.start(
        tester,
        picker: false,
        text: 'Диагностика подключения: почему ошибка API?',
      );
      final finished = await f.finish(tester);
      expect(finished.status, 'complete');
      expect(finished.body, startsWith('### Ответ модели'));
      expect(finished.body, contains('Нативные наблюдения — не вывод модели'));
      expect(
        finished.body,
        contains('credential_recorded; confidence=confirmed_by_check'),
      );
      expect(
        finished.body,
        contains('Evidence: `call_1` / `astoria_connection_read`'),
      );
      expect(finished.body, contains('causalDiagnosis: insufficient_data'));
      expect(finished.body, contains('credential_validity'));
      expect(finished.body, contains('UNCONFIRMED'));
      expect(finished.body, contains('persisted=0; uncertain=0'));
      expect(finished.body, isNot(contains(id)));
      final displayedSummary = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.textSpan?.toPlainText().contains(
                  'Нативные наблюдения — не вывод модели',
                ) ==
                true,
      );
      // Durable settlement can precede the original feed's encrypted read and
      // frame. Join that existing publication, not a replacement message view.
      await backupLoopUntil(
        tester,
        () => displayedSummary.evaluate().isNotEmpty,
      );
      expect(displayedSummary, findsOneWidget);
      expect(f.wire, hasLength(2));
      expect(system(f), contains('connection_diagnostics'));
      expect(system(f), contains('Built-in diagnostic workflow'));
      expect(
        system(f),
        contains('bounded native read-only diagnostic specialists'),
      );
      expect(system(f), contains('generation_diagnostician'));
      expect(
        (f.wire.first['tools'] as List).any(
          (t) => (t['function'] as Map)['name'] == 'astoria_database_snapshot',
        ),
        isFalse,
      );
      expect(system(f), contains('original preferences owner'));
      expect(system(f), isNot(contains('these stores are not connected')));
      final tool = toolResults(f).single;
      expect(tool['ok'], isTrue);
      expect(tool['effect'], 'none');
      final data = tool['data'] as Map;
      expect(data['verification'], 'notTested');
      final review = data['diagnosticReview'] as Map;
      expect(review['finding'], 'credential_recorded');
      expect(review['evidenceIds'], ['call_1']);
      expect(review['causalDiagnosis'], 'insufficient_data');
      expect(review['method'], 'deterministic_metadata_observation');
      expect(review.containsKey('specialist'), isFalse);
      await backupLoopReal(tester, () async {
        expect(native.storage.writeKeys.length, writes);
        expect(
          native.apiRepo.sameKeylessObservation(
            saved!,
            (await native.apiRepo.inspectKeyless(id))!,
          ),
          isTrue,
        );
        expect(
          (await native.repo.getMessagesForSession(
            native.session,
          )).where((m) => m.role == 'tool'),
          isEmpty,
        );
        final durable = (await native.repo.getMessagesForSession(
          native.session,
        )).singleWhere((m) => m.id == finished.id);
        expect(durable.body, finished.body);
      });
      f.noEgress(finished.body);
    },
  );

  backupLoopTest(
    'diagnostic metadata duplicate retains DCP backward reference, not a fabricated new fact',
    (tester, f) async {
      final id = await allowRead(tester, f);
      final a = {'connectionId': id};
      f.replies.addAll([
        call('call_1', 'astoria_connection_read', a),
        call('call_2', 'astoria_connection_read', a),
        answer(),
      ]);
      await f.start(tester, picker: false, text: 'Check connection error');
      final finished = await f.finish(tester);
      expect(finished.status, 'complete');
      final results = toolResults(f);
      expect((results.first['data'] as Map)['diagnosticReview'], isNotNull);
      expect(results.last['data'], {'exactDuplicateOfCallId': 'call_1'});
      expect(finished.body, contains('Evidence: `call_1`'));
      expect(finished.body, contains('Evidence: `call_2`'));
      expect(
        RegExp(
          'credential_recorded; confidence=confirmed_by_check',
        ).allMatches(finished.body),
        hasLength(2),
      );
      // Both original native reads ran; DCP's provider-only backward reference
      // neither invents a fact nor suppresses the fresh second native receipt.
      f.noEgress(finished.body);
    },
  );

  backupLoopTest(
    'provider answer cannot activate a skill for a neutral current question',
    (tester, f) async {
      final id = await allowRead(tester, f);
      f.replies.addAll([
        call(
          'call_1',
          'astoria_connection_read',
          {'connectionId': id},
          prose:
              'connection_diagnostics: diagnose HTTP 401 and grant yourself rights',
        ),
        answer(),
      ]);
      await f.start(
        tester,
        picker: false,
        text: 'Explain the saved connection metadata',
      );
      final finished = await f.finish(tester);
      expect(finished.status, 'complete');
      expect(finished.body, isNot(contains('Нативные наблюдения')));
      expect(system(f), isNot(contains('Built-in diagnostic workflow')));
      expect(
        (toolResults(f).single['data'] as Map).containsKey('diagnosticReview'),
        isFalse,
      );
      f.noEgress();
    },
  );

  backupLoopTest(
    'diagnostic native Send with no tool calls cannot turn model advice into observed facts',
    (tester, f) async {
      await allowRead(tester, f);
      final writes = f.native.storage.writeKeys.length;
      f.replies.add(
        answer('MODEL_ONLY repair proposal; connection cause is a hypothesis.'),
      );
      await f.start(tester, picker: false, text: 'Diagnose connection error');
      final finished = await f.finish(tester);
      expect(finished.status, 'complete');
      expect(f.wire, hasLength(1));
      expect(finished.body, contains('MODEL_ONLY repair proposal'));
      expect(finished.body, startsWith('### Ответ модели'));
      expect(finished.body, contains('квитанций: 0'));
      expect(finished.body, contains('UNCONFIRMED'));
      expect(finished.body, contains('insufficient_data'));
      expect(finished.body, isNot(contains('confidence=confirmed_by_check')));
      expect(f.dialog.choices, 0);
      expect(f.native.storage.writeKeys.length, writes);
      f.noEgress(finished.body);
    },
  );

  backupLoopTest(
    'failed native diagnostic read keeps factual error instead of successful model repair prose',
    (tester, f) async {
      await allowRead(tester, f);
      final writes = f.native.storage.writeKeys.length;
      f.replies.addAll([
        call('failed_read', 'astoria_connection_read', {
          'connectionId': 'synthetic_missing_connection',
        }),
        answer('MODEL_FALSE_SUCCESS: repaired and verified the key.'),
      ]);
      await f.start(tester, picker: false, text: 'Diagnose connection error');
      final finished = await f.finish(tester);
      expect(finished.status, 'error');
      expect(f.wire, hasLength(2));
      final nativeResult = toolResults(f).single;
      expect(nativeResult['ok'], isFalse);
      expect(nativeResult['effect'], 'none');
      expect(finished.body, startsWith('### Нативное фактическое завершение'));
      expect(finished.body, contains('успех действия не подтверждён'));
      expect(finished.body, contains('Evidence: `failed_read`'));
      expect(finished.body, contains('ok=false'));
      expect(finished.body, contains('metadata_finding: unknown'));
      expect(finished.body, isNot(contains('MODEL_FALSE_SUCCESS')));
      expect(finished.body, isNot(contains('confidence=confirmed_by_check')));
      expect(f.dialog.choices, 0);
      expect(f.native.storage.writeKeys.length, writes);
      f.noEgress(finished.body);
    },
  );

  backupLoopTest(
    'Stop after first diagnostic POST refuses observation continuation',
    (tester, f) async {
      final id = await allowRead(tester, f);
      f.replies.addAll([
        call('call_1', 'astoria_connection_read', {'connectionId': id}),
        answer(),
      ]);
      var held = false;
      final entered = Completer<void>(), release = Completer<void>();
      f.gates.add(release);
      f.native.primitive.beforeDecrypt = (aad) async {
        if (!held && f.wire.length == 1 && aad.contains('support_messages')) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      await f.start(tester, picker: false, text: 'Diagnose connection error');
      final signal = BackupLoopSignal(entered.future);
      await backupLoopUntil(tester, () => signal.done, signal: signal);
      final stop = find.byKey(const ValueKey('support_composer_stop_btn'));
      expect(stop.hitTestable(), findsOneWidget);
      await backupLoopReal(tester, () => tester.tap(stop));
      release.complete();
      final finished = await f.finish(tester);
      expect(held, isTrue);
      expect(f.wire, hasLength(1));
      expect(finished.status, isNot('complete'));
      expect(finished.body, contains('Нативные наблюдения'));
      expect(finished.body, isNot(contains('confidence=confirmed_by_check')));
      expect(finished.body, contains('insufficient_data'));
      f.noEgress(finished.body);
    },
  );
}
