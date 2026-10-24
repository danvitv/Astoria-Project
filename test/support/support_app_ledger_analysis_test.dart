import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_ui_bridge.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'support_app_ledger_analysis_fixture.dart';

void main() {
  final cases = <(AnalysisSeed, String, String, String, String)>[
    (AnalysisSeed.omitted, 'available', 'missing', 'unverifiable', 'unknown'),
    (
      AnalysisSeed.same,
      'available',
      'explicitReturned',
      'accepted',
      'sameNumeric',
    ),
    (
      AnalysisSeed.rejected,
      'available',
      'explicitReturned',
      'rejected',
      'unknown',
    ),
    (
      AnalysisSeed.changed,
      'available',
      'explicitReturned',
      'accepted',
      'differentNumeric',
    ),
    (AnalysisSeed.noOps, 'available', 'missing', 'unverifiable', 'unknown'),
    (AnalysisSeed.noDebug, 'unavailable', 'unknown', 'unverifiable', 'unknown'),
    (
      AnalysisSeed.noCapture,
      'unavailable',
      'unknown',
      'unverifiable',
      'unknown',
    ),
    (
      AnalysisSeed.noSnapshot,
      'available',
      'explicitReturned',
      'accepted',
      'unknown',
    ),
    (
      AnalysisSeed.truncated,
      'unavailable',
      'unknown',
      'unverifiable',
      'unknown',
    ),
    (
      AnalysisSeed.duplicateCall,
      'unavailable',
      'unknown',
      'unverifiable',
      'unknown',
    ),
    (AnalysisSeed.repair, 'unavailable', 'unknown', 'unverifiable', 'unknown'),
    (
      AnalysisSeed.newerAttempt,
      'unavailable',
      'unknown',
      'unverifiable',
      'unknown',
    ),
    (
      AnalysisSeed.newerUser,
      'unavailable',
      'unknown',
      'unverifiable',
      'unknown',
    ),
    (
      AnalysisSeed.ambiguousBaseline,
      'available',
      'explicitReturned',
      'accepted',
      'unknown',
    ),
  ];
  for (final entry in cases) {
    domainLoopTest(
      'MODEL Ledger analysis ${entry.$1.name}: actual request/parser/snapshot only',
      (tester, f) async {
        await configurationAction(
          tester,
          () => seedLedgerAnalysis(f, entry.$1),
        );
        final before = await configurationAction(
          tester,
          () => ledgerSources(f),
        );
        await runLedgerAnalysis(tester, f, (result) {
          expect(result['code'], 'completed');
          expect(result['effect'], 'none');
          final data = Map<String, dynamic>.from(result['data'] as Map);
          expect(data.length, 15);
          expect(data['analysis'], entry.$2);
          expect(data['worldTimeOperation'], entry.$3);
          expect(data['worldTimeParser'], entry.$4);
          expect(data['numericClockComparison'], entry.$5);
          expect(data['bodyAccess'], 'notGranted');
          expect(data['advisory'], true);
          expect(data['builtInContractEditable'], false);
          if (entry.$2 == 'available') {
            expect(data['capturedInstruction'], 'present');
            expect(data['captureCount'], 1);
            expect(data['eventCount'], 2);
            expect(data['debugCount'], 1);
            expect(
              data['snapshotState'],
              entry.$1 == AnalysisSeed.noSnapshot ? 'unknown' : 'tentative',
            );
            expect(
              data['persistedSnapshot'],
              {
                    AnalysisSeed.same,
                    AnalysisSeed.changed,
                    AnalysisSeed.ambiguousBaseline,
                  }.contains(entry.$1)
                  ? 'matching'
                  : 'unverifiable',
            );
          } else {
            expect(data['capturedInstruction'], 'unknown');
            expect(data['persistedSnapshot'], 'unverifiable');
          }
        });
        expect(
          await configurationAction(tester, () => ledgerSources(f)),
          before,
        );
      },
    );
  }

  for (final shape in AnalysisSelectedShape.values) {
    domainLoopTest('MODEL Ledger analysis selected shape ${shape.name}', (
      tester,
      f,
    ) async {
      await configurationAction(
        tester,
        () => seedLedgerSelectedShape(f, shape),
      );
      final before = await configurationAction(tester, () => ledgerSources(f));
      final valid = shape == AnalysisSelectedShape.validBlue;
      await runLedgerAnalysis(tester, f, (result) {
        expect(result['ok'], true);
        expect(result['code'], 'completed');
        expect(result['effect'], 'none');
        final data = Map<String, dynamic>.from(result['data'] as Map);
        expect(data, {
          'analysis': valid ? 'available' : 'unavailable',
          'scope': 'latestSelectedTurn',
          'reason': valid ? 'none' : 'unsupportedShape',
          'capturedInstruction': valid ? 'present' : 'unknown',
          'worldTimeOperation': valid ? 'explicitReturned' : 'unknown',
          'worldTimeParser': valid ? 'accepted' : 'unverifiable',
          'persistedSnapshot': valid ? 'matching' : 'unverifiable',
          'snapshotState': valid ? 'tentative' : 'unknown',
          'numericClockComparison': valid ? 'sameNumeric' : 'unknown',
          'captureCount': valid ? 1 : 0,
          'eventCount': valid ? 2 : 0,
          'debugCount': valid ? 1 : 0,
          'bodyAccess': 'notGranted',
          'advisory': true,
          'builtInContractEditable': false,
        });
      });
      expect(await configurationAction(tester, () => ledgerSources(f)), before);
    });
  }

  for (final pending in [true, false]) {
    domainLoopTest(
      'MODEL Ledger analysis ${pending ? 'busy source' : 'changed original checkpoint'} is not authority',
      (tester, f) async {
        await configurationAction(
          tester,
          () => seedLedgerAnalysis(f, AnalysisSeed.same),
        );
        final core = f.screen.core;
        final registry = core.container.read(
          chatSourceMutationRegistryProvider,
        );
        final before = await configurationAction(
          tester,
          () => ledgerSources(f),
        );
        void Function()? settle;
        var fenced = false;
        core.native.sql.afterSelect = (sql, _) async {
          if (fenced) return;
          // Discovery read for pending; the first owning projection for changed.
          if (sql.contains(pending ? 'AS message_count' : 'args AS (SELECT')) {
            fenced = true;
            settle = registry.beginMutation(
              sessionId: DomainLoopFixture.session,
            );
            if (!pending) settle!();
          }
        };
        try {
          await runLedgerAnalysis(tester, f, (result) {
            expect(result['ok'], false);
            expect(result['code'], pending ? 'unavailable' : 'conflict');
            expect(result['effect'], 'none');
            expect(result['data'], isEmpty);
          }, expectedReplyStatus: 'error');
        } finally {
          settle?.call();
          core.native.sql.afterSelect = null;
        }
        expect(fenced, true);
        expect(
          await configurationAction(tester, () => ledgerSources(f)),
          before,
        );
      },
    );
  }

  domainLoopTest('MODEL Ledger analysis never warms an unloaded owner', (
    tester,
    f,
  ) async {
    await configurationAction(
      tester,
      () => seedLedgerAnalysis(f, AnalysisSeed.same),
    );
    final core = f.screen.core;
    final owners = core.container.read(chatNativeOwnerRegistryProvider);
    final original = owners.existing(DomainLoopFixture.session);
    expect(original, isNotNull);
    core.container.invalidate(chatProvider(DomainLoopFixture.character));
    await tester.pump();
    expect(owners.existing(DomainLoopFixture.session), isNull);
    final before = await configurationAction(tester, () => ledgerSources(f));
    await runLedgerAnalysis(tester, f, (result) {
      expect(result['ok'], false);
      expect(result['code'], 'unavailable');
      expect(result['effect'], 'none');
      expect(result['data'], isEmpty);
    }, expectedReplyStatus: 'error');
    expect(owners.existing(DomainLoopFixture.session), isNull);
    expect(await configurationAction(tester, () => ledgerSources(f)), before);
  });

  domainLoopTest(
    'MODEL Ledger analysis actual composer Stop denies late projection and any third POST',
    (tester, f) async {
      await configurationAction(
        tester,
        () => seedLedgerAnalysis(f, AnalysisSeed.same),
      );
      final core = f.screen.core;
      final before = await configurationAction(tester, () => ledgerSources(f));
      var stopped = false;
      Object? failure;
      StackTrace? failureStack;
      String? originalRunId;
      f.script(
        core.call('astoria_session_integrity', {'operation': 'discover'}),
        next: (round) {
          try {
            if (round != 2) throw StateError('Forbidden POST after Stop');
            final record = (f.lastData()['records'] as List).cast<Map>().single;
            final originalComposer = find.byType(
              SupportComposerBar,
              skipOffstage: false,
            );
            expect(originalComposer, findsOneWidget);
            final originalContext = tester.element(originalComposer);
            expect(originalContext.mounted, true);
            final composer = tester.widget<SupportComposerBar>(
              originalComposer,
            );
            expect(composer.sessionId, core.native.session);
            expect(composer.busy, true);
            expect(composer.nativeOwner, isA<SupportModelUiEmitter>());
            final emitter = composer.nativeOwner! as SupportModelUiEmitter;
            expect(emitter.isCurrent, true);
            expect(ModalRoute.of<void>(originalContext)!.isCurrent, true);
            expect(core.bridge.view.sessionId, core.native.session);
            expect(core.bridge.view.busy, true);
            final runId = core.bridge.view.runId;
            expect(runId, isNotNull);
            originalRunId = runId;
            final stopButton = find.descendant(
              of: originalComposer,
              matching: find.byKey(
                const ValueKey('support_composer_stop_btn'),
                skipOffstage: false,
              ),
              skipOffstage: false,
            );
            expect(stopButton, findsOneWidget);
            expect(tester.element(stopButton).mounted, true);
            final stop = tester.widget<IconButton>(stopButton).onPressed;
            expect(stop, isNotNull);
            // The real screen supplies activeSend.stop directly to onStop.
            expect(identical(stop, composer.onStop), true);
            core.native.sql.afterSelect = (sql, _) async {
              if (!stopped && sql.contains('args AS (SELECT')) {
                try {
                  expect(originalContext.mounted, true);
                  expect(
                    tester.element(originalComposer),
                    same(originalContext),
                  );
                  final currentComposer = tester.widget<SupportComposerBar>(
                    originalComposer,
                  );
                  expect(currentComposer.sessionId, composer.sessionId);
                  expect(currentComposer.controller, same(composer.controller));
                  expect(currentComposer.nativeOwner, same(emitter));
                  expect(currentComposer.busy, true);
                  expect(emitter.isCurrent, true);
                  expect(core.bridge.view.runId, runId);
                  expect(core.bridge.view.sessionId, composer.sessionId);
                  expect(core.bridge.view.busy, true);
                  expect(tester.element(stopButton).mounted, true);
                  expect(
                    tester.widget<IconButton>(stopButton).onPressed == stop,
                    true,
                  );
                  expect(currentComposer.onStop == stop, true);
                  stopped = true;
                  stop!();
                } catch (error, trace) {
                  if (failure == null) {
                    failure = error;
                    failureStack = trace;
                  }
                }
              }
            };
            return core.call('astoria_session_integrity', {
              'operation': 'analyzeLedger',
              'session': record['session'],
            }, id: 'analysis_stop_call');
          } catch (error, trace) {
            if (failure == null) {
              failure = error;
              failureStack = trace;
            }
            return core.answer();
          }
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      core.native.sql.afterSelect = null;
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      expect(failure, isNull);
      expect(stopped, true);
      expect(reply.status, 'stopped');
      expect(reply.runId, originalRunId);
      expect(core.wire, hasLength(2));
      expect(await configurationAction(tester, () => ledgerSources(f)), before);
      f.noEgress(reply.body);
      expect(
        '${jsonEncode(core.wire)}${reply.body}',
        isNot(contains(analysisPrivate)),
      );
    },
  );
}
