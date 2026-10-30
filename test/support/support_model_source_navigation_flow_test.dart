import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_source_preparation_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_source_preparation_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_model_source_loop_fixture.dart';

// MAIN runs these FILE-backed actual-provider/AEAD/screen checks sequentially.
// They reuse original dispatch, IO tripwires and settlement futures, not a fake
// source POST or a replacement native owner.
String _readyGame(SourceLoop loop) =>
    (loop.lastData()['pieces'] as List)
            .cast<Map<dynamic, dynamic>>()
            .singleWhere(
              (p) => p['domain'] == 'game' && p['state'] == 'current',
            )['source']
        as String;
Map<String, dynamic> _body(SourceLoop loop) => Map<String, dynamic>.from(
  jsonDecode(loop.lastData()['sourceText'] as String) as Map,
);
Future<void> _index(WidgetTester tester, BackupLoopFixture f) =>
    backupLoopReal(tester, () async {
      final result = await f.native.db.historySourceIndex.maintain(
        sessionId: sourceSession,
        isCurrent: () => true,
      );
      expect(result.state, HistoryIndexMaintenanceState.ready);
    });

Future<void> _prepareLocally(WidgetTester tester, BackupLoopFixture f) async {
  f.isolation.extraAllowed.add(supportSourcePreparationPageProvider(0));
  final canonical = await backupLoopReal(
    tester,
    () async =>
        (await f.native.db
                .customSelect(
                  'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                  variables: [Variable.withString(sourceSession)],
                )
                .getSingle())
            .read<String>('messages_json'),
  );
  // The real mobile shell owns this entry in its action drawer, not Settings.
  // Both accepted fixture sizes use that shell (no DesktopScope is installed).
  final toggle = find.byKey(const ValueKey('support_drawer_toggle'));
  expect(toggle.hitTestable(), findsOneWidget);
  if (!tester.widget<IconButton>(toggle).isSelected!) {
    await backupLoopReal(tester, () => tester.tap(toggle));
    await tester.pump();
  }
  final entry = find.byKey(const ValueKey('support_local_source_preparation'));
  expect(entry.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(entry));
  final frame = find.byWidgetPredicate(
    (w) => w is SheetView && w.title == 'Локальная подготовка источников',
  );
  final sheet = find.descendant(
    of: frame,
    matching: find.byType(SupportSourcePreparationSheet),
  );
  await backupLoopUntil(tester, () => sheet.evaluate().isNotEmpty);
  final route = ModalRoute.of<void>(tester.element(sheet))!;
  await tester.pump();
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.isCurrent, isTrue);
  expect(route.animation!.status, AnimationStatus.completed);
  final candidate = find.descendant(
    of: sheet,
    matching: find.byKey(ValueKey('support_source_prepare_$sourceSession')),
  );
  await backupLoopUntil(tester, () => candidate.evaluate().isNotEmpty);
  expect(route.isCurrent, isTrue);
  expect(
    tester.widget<MenuItem>(candidate).subtitle,
    'Не готов · подготовить / продолжить',
  );
  await tester.ensureVisible(candidate);
  await tester.pump();
  expect(candidate.hitTestable(), findsOneWidget);
  expect(f.wire, isEmpty);
  SourceLoop(f).noBody();
  expect(
    find.byKey(const ValueKey('support_tool_confirmation_accept')),
    findsNothing,
  );
  await backupLoopReal(tester, () => tester.tap(candidate));
  await backupLoopUntil(
    tester,
    () => find
        .text(
          'Готово для текущего снимка. Чтение моделью требует отдельного согласия.',
        )
        .evaluate()
        .isNotEmpty,
  );
  await backupLoopReal(tester, () async {
    expect(
      (await f.native.db.historySourceIndex.observe(sourceSession))['status'],
      'ready',
    );
    final after =
        (await f.native.db
                .customSelect(
                  'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                  variables: [Variable.withString(sourceSession)],
                )
                .getSingle())
            .read<String>('messages_json');
    expect(utf8.encode(after), utf8.encode(canonical));
    final rows = await f.native.repo.getMessagesForSession(f.native.session);
    expect(rows.where((m) => m.runId != null), isEmpty);
  });
  expect(f.wire, isEmpty);
  SourceLoop(f).noBody();
  expect(
    find.byKey(const ValueKey('support_tool_confirmation_accept')),
    findsNothing,
  );
  // Close the one real preparation route through its header control.
  final back = find.descendant(
    of: frame,
    matching: find.byIcon(Icons.arrow_back),
  );
  expect(route.isCurrent, isTrue);
  expect(back.hitTestable(), findsOneWidget);
  final preparationClosed = BackupLoopSignal(route.completed);
  await backupLoopReal(tester, () => tester.tap(back));
  await tester.pump();
  await tester.pump(route.reverseTransitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  await backupLoopUntil(
    tester,
    () => preparationClosed.done,
    signal: preparationClosed,
  );
  await backupLoopReal(tester, () => route.completed);
  expect(route.isActive, isFalse);
  expect(frame, findsNothing);
  final drawerClose = find.byKey(const ValueKey('support_drawer_close'));
  expect(drawerClose.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(drawerClose));
  await tester.pump();
  expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
  _noPrivateSources(f);
}

Future<void> _durableBeforePost(BackupLoopFixture f, int count) async {
  final rows = await f.native.repo.getMessagesForSession(f.native.session);
  final reply = rows.singleWhere(
    (r) => r.role == 'assistant' && r.runId != null,
  );
  final recipe = await modelSourceRecipe(
    f,
    reply.id,
    expectedVersion: 4,
    expectedDisclosureCount: count,
  );
  expect(recipe.toolDisclosures, hasLength(count));
  for (var i = 0; i < count; i++) {
    final disclosure = recipe.toolDisclosures![i];
    expect(disclosure.domain.name, 'game');
    expect(disclosure.sourceId, sourceSession);
    expect(disclosure.operation?.name, ['contents', 'search', 'read'][i]);
    expect(
      disclosure.extent?.name,
      i == 0 ? 'scopeMetadata' : 'selectedMessages',
    );
    expect(disclosure.orderedSourceIds, [
      for (final n in [
        [0, 1, 2, 3],
        [2],
        [1, 2, 3],
      ][i])
        'model-source-$n',
    ]);
  }
  for (final disclosure in recipe.toolDisclosures!) {
    expect(jsonEncode(f.wire), isNot(contains(disclosure.snapshotDigest)));
  }
  for (final tool
      in (f.wire.last['messages'] as List).cast<Map<dynamic, dynamic>>().where(
        (m) => m['role'] == 'tool',
      )) {
    // Check the actual nested native result, not a payload-only estimate.
    expect(
      utf8.encode(jsonEncode(jsonDecode(tool['content'] as String))).length,
      lessThanOrEqualTo(65536),
    );
  }
}

void _noPrivateSources(BackupLoopFixture f) {
  for (final secret in [
    sourceExcluded,
    sourceOlderBody,
    sourceInactiveStudioBody,
    sourceSession,
    sourceCharacter,
  ]) {
    expect(jsonEncode(f.wire), isNot(contains(secret)));
  }
  sourceNoEgress(f);
}

Future<void> _seedPickerPages(
  WidgetTester tester,
  BackupLoopFixture f,
) => backupLoopReal(tester, () async {
  await f.native.db.customStatement(
    "INSERT INTO characters(char_id,name) VALUES('private-picker-character','PRIVATE_PAGED_TITLE')",
  );
  for (var i = 0; i < 34; i++) {
    final seconds = 1785750440 - i * 60;
    await f.native.db.customStatement(
      'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json,updated_at) VALUES(?,?,?,?,?)',
      [
        'private-picker-$i',
        'private-picker-character',
        i + 10,
        '[]',
        i.isEven ? seconds : seconds * 1000,
      ],
    );
    await f.native.db.customStatement(
      'INSERT INTO chat_summaries(session_id,content,message_count) VALUES(?,?,?)',
      ['private-picker-$i', 'PAGED_APPROVED_BODY_$i', 0],
    );
  }
});

Future<void> _pickerPage(WidgetTester tester, String direction) async {
  final button = find.byKey(ValueKey('support_source_$direction'));
  expect(button.hitTestable(), findsOneWidget);
  expect(tester.widget<GlazeActionButton>(button).onTap, isNotNull);
  await backupLoopReal(tester, () => tester.tap(button));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  backupLoopTest(
    'MODEL LOCAL paged next previous selects exact beyond16 source with no selection grant',
    (tester, f) async {
      await _seedPickerPages(tester, f);
      final loop = SourceLoop(f);
      late String handle;
      loop.script(
        loop.list('savedSummary', 'paged_list'),
        rounds: 5,
        next: (round) async {
          if (round == 2) {
            loop.noBody();
            final data = loop.lastData();
            expect(data['count'], 1);
            expect(data['complete'], isFalse);
            expect(data['incompleteReason'], 'localTargetSelection');
            handle = loop.handle();
            return loop.contents(handle, 'paged_contents');
          }
          // Top-level contents issues section selectors only; read needs an
          // issued record selector from a search within the chosen source.
          if (round == 3) {
            return loop.search(
              handle,
              'PAGED_APPROVED_BODY_16',
              'paged_search',
            );
          }
          if (round == 4) {
            return loop.read(handle, loop.selector(), 'paged_read');
          }
          expect(jsonEncode(loop.body()), contains('PAGED_APPROVED_BODY_16'));
          expect(
            jsonEncode(loop.body()),
            isNot(contains('PAGED_APPROVED_BODY_0"')),
          );
          return SourceLoop.answer(
            'Read only the locally chosen saved summary.',
          );
        },
      );
      await loop.start(
        tester,
        confirmation: false,
        text: 'Choose a saved summary locally.',
      );
      final target = find.byKey(const ValueKey('support_source_target_0'));
      await backupLoopUntil(
        tester,
        () => target.evaluate().isNotEmpty,
        signal: f.settlement,
      );
      final route = await sourceLoopReadyRoute(tester, target);
      String label() => tester.widget<GlazeActionButton>(target).label;
      final first = label();
      expect(first, contains('Сессия 11 ·'));
      expect(first, contains('(местное время)'));
      expect(first, isNot(contains('1785750440')));
      await _pickerPage(tester, 'next');
      await backupLoopUntil(
        tester,
        () => label().contains('Сессия 27 ·'),
        signal: f.settlement,
      );
      expect(ModalRoute.of(tester.element(target)), same(route));
      final second = label();
      await _pickerPage(tester, 'previous');
      await tester.pump();
      expect(label(), first);
      await _pickerPage(tester, 'next');
      await tester.pump();
      expect(label(), second);
      expect(f.wire, hasLength(1));
      loop.noBody();
      await tester.ensureVisible(target);
      await tester.pump();
      expect(target.hitTestable(), findsOneWidget);
      await backupLoopReal(tester, () => tester.tap(target));
      await sourceLoopRouteClosed(tester, route);
      await loop.modal(tester);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      expect(f.wire, hasLength(5));
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 3,
        ),
      );
      for (final disclosure in recipe.toolDisclosures!) {
        expect(disclosure.sourceId, 'private-picker-16');
        expect(jsonEncode(f.wire), isNot(contains(disclosure.snapshotDigest)));
      }
      for (final secret in [
        'PRIVATE_PAGED_TITLE',
        'private-picker-',
        second,
        '(местное время)',
        '1785750440',
      ]) {
        expect(jsonEncode(f.wire), isNot(contains(secret)));
      }
      sourceNoEgress(f);
    },
  );

  for (final action in ['cancel', 'stop', 'routeABA', 'sourceABA']) {
    backupLoopTest('MODEL LOCAL pending-page $action fails closed', (
      tester,
      f,
    ) async {
      await _seedPickerPages(tester, f);
      final loop = SourceLoop(f);
      loop.script(
        loop.list('savedSummary', 'pending_page'),
        rounds: 2,
        next: (_) => throw TestFailure('Pending page must not produce a POST'),
      );
      await loop.start(
        tester,
        confirmation: false,
        text: 'Choose a saved summary locally.',
      );
      final target = find.byKey(const ValueKey('support_source_target_0'));
      await backupLoopUntil(
        tester,
        () => target.evaluate().isNotEmpty,
        signal: f.settlement,
      );
      final route = await sourceLoopReadyRoute(tester, target);
      final stop = tester
          .widget<SupportComposerBar>(find.byType(SupportComposerBar))
          .onStop!;
      // The gate completers live inside the runAsync zone. Completing a
      // completer created in the fake-async test body parks its microtask in
      // the fake queue that only tester.pump() flushes, so an await inside
      // tester.runAsync would never resume there. runAsync forks real
      // root-zone scheduling, so these completions reach the held transaction
      // without any pump.
      Future<void>? blocked;
      Completer<void>? releaseGate;
      // Hold the actual original DB executor, not a replacement page callback.
      await backupLoopReal(tester, () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        releaseGate = release;
        blocked = f.native.db.transaction(() async {
          entered.complete();
          await release.future;
          if (action == 'sourceABA') {
            await f.native.db.customStatement(
              "UPDATE chat_sessions SET draft='ABA' WHERE session_id='private-picker-16'",
            );
            await f.native.db.customStatement(
              "UPDATE chat_sessions SET draft='' WHERE session_id='private-picker-16'",
            );
          }
        });
        await entered.future;
      });
      try {
        await _pickerPage(tester, 'next');
        await tester.pump();
        expect(
          tester
              .widget<GlazeActionButton>(
                find.byKey(const ValueKey('support_source_next')),
              )
              .busy,
          isTrue,
        );
        expect(tester.widget<GlazeActionButton>(target).onTap, isNull);
        if (action == 'cancel') {
          await loop.cancel(tester);
        } else if (action != 'sourceABA') {
          await backupLoopReal(tester, () async {
            if (action == 'stop') {
              stop();
            } else {
              f.router.go('/characters');
              f.router.go('/support');
            }
          });
          await sourceLoopRouteClosed(tester, route);
        }
      } finally {
        final gate = releaseGate;
        final held = blocked;
        await backupLoopReal(tester, () async {
          gate?.complete();
          if (held != null) await held;
        });
      }
      if (action == 'sourceABA') {
        // Opening the gate lets the queued page fetch settle into the repo's
        // change fence: the transaction's own session writes moved the stamp,
        // the repo retires, its leases die and the picker invalidates this
        // original route. That pop runs on a real event-loop turn, so first
        // wait until the invalidation has actually popped this exact route:
        // the finite loop pumps zero-duration frames, which alone never let
        // the real reverse transition finish, and joining route.completed
        // before the pop would exhaust its frame budget without a pop.
        await backupLoopUntil(
          tester,
          () => !route.isCurrent,
          signal: f.settlement,
        );
        await sourceLoopRouteClosed(tester, route);
      }
      final reply = await loop.finish(tester);
      expect(
        reply.status,
        action == 'stop' || action == 'routeABA' ? 'stopped' : 'error',
      );
      expect(f.wire, hasLength(1));
      expect(target, findsNothing);
      loop.noBody();
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 2,
          expectedDisclosureCount: null,
        ),
      );
      expect(recipe.toolDisclosures, isNull);
      expect(jsonEncode(f.wire), isNot(contains('PRIVATE_PAGED_TITLE')));
      expect(jsonEncode(f.wire), isNot(contains('PAGED_APPROVED_BODY_')));
      sourceNoEgress(f);
    });
  }
  for (final action in ['cancel', 'stop', 'routeABA', 'sourceABA']) {
    backupLoopTest('MODEL LOCAL named-target $action returns no title/body/grant', (
      tester,
      f,
    ) async {
      await seedModelSources(tester, f, messages: 4);
      const title = 'LOCAL_PICKER_TITLE_CANARY';
      await backupLoopReal(
        tester,
        () =>
            (f.native.db.update(f.native.db.characters)
                  ..where((t) => t.charId.equals(sourceCharacter)))
                .write(const CharactersCompanion(name: Value(title))),
      );
      final loop = SourceLoop(f);
      final policy = f.native.runtime.snapshot.preferences;
      final epoch = f.native.runtime.epoch;
      var replayPosts = 0;
      loop.script(
        loop.list('game', 'local_target'),
        rounds: 2,
        next: (_) {
          replayPosts++;
          // Cancel retires the source owner one-way; every terminal case must
          // reject replay at original-ROOT admission, including a refusal.
          throw TestFailure('Unexpected LOCAL $action replay POST');
        },
      );
      await loop.start(
        tester,
        confirmation: false,
        text: 'Select a named saved game locally.',
      );
      final target = find.byKey(const ValueKey('support_source_target_0'));
      await backupLoopUntil(tester, () {
        loop.checkScript();
        if (f.settlement!.done && target.evaluate().isEmpty) {
          throw TestFailure('Source settled before the original local picker');
        }
        return target.evaluate().isNotEmpty;
      }, signal: f.settlement);
      final route = await sourceLoopReadyRoute(tester, target);
      final stop = tester
          .widget<SupportComposerBar>(find.byType(SupportComposerBar))
          .onStop!;
      expect(f.wire, hasLength(1));
      loop.noBody();
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      final localPreview = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey('support_tool_confirmation_preview'),
              ),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data ?? '')
          .join('\n');
      expect(localPreview, contains(title));
      expect(localPreview, contains('Сессия 2 ·'));
      if (action == 'cancel') {
        await loop.cancel(tester);
      } else if (action == 'sourceABA') {
        await backupLoopReal(tester, () async {
          await (f.native.db.update(
            f.native.db.chatSessions,
          )..where((t) => t.sessionId.equals(sourceSession))).write(
            const ChatSessionsCompanion(draft: Value('outside chosen target')),
          );
          await (f.native.db.update(f.native.db.chatSessions)
                ..where((t) => t.sessionId.equals(sourceSession)))
              .write(const ChatSessionsCompanion(draft: Value('')));
        });
        await sourceLoopChooseTarget(tester);
      } else {
        await backupLoopReal(tester, () async {
          if (action == 'stop') {
            stop();
          } else {
            f.router.go('/characters');
            f.router.go('/support');
          }
        });
        await sourceLoopRouteClosed(tester, route);
      }
      final reply = await loop.finish(tester);
      expect(
        reply.status,
        action == 'stop' || action == 'routeABA' ? 'stopped' : 'error',
      );
      if (action == 'cancel' || action == 'sourceABA') {
        expect(f.bridge.view.transportReason.name, 'denied');
        expect(
          reply.body,
          contains(
            action == 'sourceABA'
                ? 'Исходный источник или контекст изменился; чтение не продолжено'
                : 'Вызов не разрешён; согласие не получено или ссылка на источник недействительна',
          ),
        );
        expect(
          reply.body,
          isNot(contains('No local target was read or disclosed.')),
        );
      }
      expect(f.wire, hasLength(1));
      expect(replayPosts, 0);
      for (final request in f.wire) {
        expect(request['model'], f.native.api.model);
      }
      for (final request in f.requests) {
        expect(
          request.uri.toString(),
          'https://api.openai.com/v1/chat/completions',
        );
      }
      expect(
        loop.dispatchAuthorizations,
        List.filled(f.wire.length, 'Bearer ${BackupLoopNative.key}'),
      );
      // Provenance mapping decrypts real AEAD; join it outside fake async.
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 2,
          expectedDisclosureCount: null,
        ),
      );
      expect(recipe.toolDisclosures, isNull);
      expect(f.native.runtime.snapshot.preferences, policy);
      expect(f.native.runtime.epoch, epoch);
      expect(jsonEncode(f.wire), isNot(contains(title)));
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      loop.noBody();
      _noPrivateSources(f);
      sourceNoEgress(f, reply.body);
    });
  }

  backupLoopTest(
    'MODEL missing Studio selection resolves SAVED default without authored metadata egress',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      await backupLoopReal(tester, () async {
        // Fresh DB creation already owns this key. Establish an exact saved
        // fallback rather than inserting a duplicate or retaining seed fields.
        final saved = await (f.native.db.select(
          f.native.db.studioPresetRows,
        )..where((t) => t.presetId.equals(sourceStudio))).getSingle();
        final changed =
            await (f.native.db.update(
              f.native.db.studioPresetRows,
            )..where((t) => t.presetId.equals('default'))).write(
              saved
                  .copyWith(presetId: 'default', name: 'LOCAL_FALLBACK_TITLE')
                  .toCompanion(false),
            );
        expect(changed, 1);
        expect(
          await (f.native.db.select(
            f.native.db.studioPresetRows,
          )..where((t) => t.presetId.equals('default'))).getSingle(),
          saved.copyWith(presetId: 'default', name: 'LOCAL_FALLBACK_TITLE'),
        );
        await f.container
            .read(activeStudioPresetProvider.notifier)
            .set('missing-saved-studio');
      });
      final loop = SourceLoop(f);
      late String source;
      loop.script(
        loop.list('studioPreset', 'fallback_catalog'),
        rounds: 5,
        next: (round) async {
          if (round == 2) {
            source = loop.activeStudioHandle();
            expect(loop.lastData()['count'], 1);
            expect(loop.lastData()['complete'], isFalse);
            expect(loop.lastData()['incompleteReason'], 'localTargetSelection');
            expect(
              jsonEncode(loop.lastData()),
              isNot(contains('LOCAL_FALLBACK_TITLE')),
            );
            loop.noBody();
            return loop.contents(source, 'fallback_contents');
          }
          final rows = await f.native.repo.getMessagesForSession(
            f.native.session,
          );
          final recipe = await modelSourceRecipe(
            f,
            rows.last.id,
            expectedVersion: 4,
            expectedDisclosureCount: round - 2,
          );
          expect(recipe.toolDisclosures, hasLength(round - 2));
          expect(recipe.toolDisclosures!.map((d) => d.sourceId).toSet(), {
            'default',
          });
          if (round == 3) {
            return loop.search(source, sourceStudioBody, 'fallback_search');
          }
          if (round == 4) {
            return loop.read(source, loop.selector(), 'fallback_read');
          }
          expect(jsonEncode(_body(loop)), contains(sourceStudioBody));
          return SourceLoop.answer(
            'The selected SAVED default text was read, not its historical prompt use.',
          );
        },
      );
      await loop.start(tester, text: 'Read the current saved Studio.');
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      expect(f.wire, hasLength(5));
      expect(jsonEncode(f.wire), isNot(contains('LOCAL_FALLBACK_TITLE')));
      sourceNoEgress(f, reply.body);
    },
  );

  // Each domain owns an independent original FILE/provider/native run. Do not
  // combine them and accidentally evade the native 16-disclosure/8-round caps.
  for (final scenario in <(String, String, String, String?)>[
    ('game', '${sourceGameBody}2', 'active', null),
    ('ordinaryPreset', 'MODEL_NINE_ordinaryPreset_BODY', 'currentSaved', null),
    ('studioPreset', sourceStudioBody, 'currentSaved', null),
    ('memory', 'MODEL_NINE_memory_BODY', 'active', 'invalid'),
    ('savedSummary', 'MODEL_NINE_savedSummary_BODY', 'current', 'unknown'),
    ('ledgerState', 'MODEL_NINE_ledgerState_BODY', 'current', 'unknown'),
    (
      'ledgerSnapshot',
      'MODEL_NINE_ledgerSnapshot_BODY',
      'historicalCommitted',
      'unknown',
    ),
    (
      'reconciliation',
      'MODEL_NINE_reconciliation_BODY',
      'historicalCommitted',
      'unknown',
    ),
    (
      'characterKnowledge',
      'MODEL_NINE_characterKnowledge_BODY',
      'active',
      'unknown',
    ),
    ('memory', 'MODEL_NINE_memory_REVISION', 'currentSaved', 'unknown'),
    ('memory', 'MODEL_NINE_memory_DRAFT', 'pendingApproval', 'unknown'),
    ('memory', 'MODEL_NINE_memory_DERIVED', 'derived', 'unknown'),
    ('savedSummary', 'MODEL_NINE_savedSummary_TEMPLATE', 'current', 'unknown'),
    (
      'reconciliation',
      'MODEL_NINE_reconciliation_EFFECT',
      'historicalCommitted',
      null,
    ),
    (
      'ledgerSnapshot',
      'MODEL_NINE_ledgerSnapshot_BODY',
      'tentative',
      'unknown',
    ),
    (
      'ledgerSnapshot',
      'MODEL_NINE_ledgerSnapshot_BODY',
      'historicalCommitted',
      'missing',
    ),
  ]) {
    final (domain, literal, state, evidence) = scenario;
    backupLoopTest(
      'MODEL native $domain $literal $state/$evidence contents/search/read encrypted BEFORE each actual POST',
      (tester, f) async {
        await seedModelSources(tester, f, messages: 4);
        await seedSavedModelDomains(tester, f);
        if (domain == 'ledgerSnapshot' &&
            (state == 'tentative' || evidence == 'missing')) {
          await backupLoopReal(
            tester,
            () => f.native.db.customStatement(
              'UPDATE tracker_snapshots SET committed = ?, message_id = ? WHERE session_id = ?',
              [
                state == 'tentative' ? 0 : 1,
                evidence == 'missing'
                    ? 'private-removed-anchor'
                    : 'model-source-2',
                sourceSession,
              ],
            ),
          );
        }
        final loop = SourceLoop(f);
        final parentLinked = !const {
          'game',
          'ordinaryPreset',
          'studioPreset',
        }.contains(domain);
        final originalDb = f.native.db.nativeDataSourceIdentity!;
        final originalModel = f.native.api.model;
        final policy = f.native.runtime.snapshot.preferences;
        final epoch = f.native.runtime.epoch;
        late String source;
        String? parent;
        String? section;
        var committed = 0;
        var emptySearchPages = 0;
        var readRequested = false;
        final rounds = parentLinked ? 6 : 5;
        loop.script(
          loop.list(parentLinked ? 'game' : domain, 'nine_catalog'),
          rounds: 8,
          next: (round) async {
            expect(originalDb.belongsTo(f.native.db), isTrue);
            expect(f.wire.last['model'], originalModel);
            if (parentLinked && round == 2) {
              parent = _readyGame(loop);
              loop.noBody();
              return SourceLoop.call('astoria_sources_list', {
                'domain': domain,
                'parent': parent,
              }, id: 'nine_parent_catalog');
            }
            final logicalRound = round - (parentLinked ? 1 : 0);
            if (logicalRound == 2) {
              final metadata = loop.lastData();
              expect(metadata['count'], 1);
              final piece = (metadata['pieces'] as List).single as Map;
              expect(piece['domain'], domain);
              expect(piece['label'], domain);
              expect(piece['historicalUse'], 'unknown');
              expect(piece['parent'], parent);
              source = piece['source'] as String;
              expect(source, isNot(sourceSession));
              expect(source, isNot(sourceStudio));
              expect(
                jsonEncode(metadata),
                isNot(contains('LOCAL_ORDINARY_AUTHORED_TITLE')),
              );
              loop.noBody();
              return loop.contents(source, 'nine_contents');
            }
            committed++;
            final rows = await f.native.repo.getMessagesForSession(
              f.native.session,
            );
            final recipe = await modelSourceRecipe(
              f,
              rows.last.id,
              expectedVersion: 4,
              expectedDisclosureCount: committed,
            );
            expect(recipe.toolDisclosures, hasLength(committed));
            expect(recipe.toolDisclosures!.map((d) => d.domain.name).toSet(), {
              domain,
            });
            expect(recipe.toolDisclosures!.map((d) => d.sourceId).toSet(), {
              const {'ordinaryPreset', 'studioPreset'}.contains(domain)
                  ? sourceStudio
                  : sourceSession,
            });
            expect(
              recipe.toolDisclosures!.last.operation,
              committed == 1
                  ? SupportModelToolDisclosureOperation.contents
                  : readRequested
                  ? SupportModelToolDisclosureOperation.read
                  : SupportModelToolDisclosureOperation.search,
            );
            expect(
              recipe.toolDisclosures!.last.extent,
              committed == 1
                  ? SupportModelToolDisclosureExtent.scopeMetadata
                  : domain == 'game'
                  ? SupportModelToolDisclosureExtent.selectedMessages
                  : SupportModelToolDisclosureExtent.sourceIdentity,
            );
            for (final d in recipe.toolDisclosures!) {
              expect(d.snapshotDigest, hasLength(64));
              expect(jsonEncode(f.wire), isNot(contains(d.snapshotDigest)));
              for (final id in d.orderedSourceIds) {
                expect(jsonEncode(f.wire), isNot(contains(id)));
              }
            }
            for (final request in f.wire) {
              for (final message in request['messages'] as List) {
                if (message['role'] == 'tool') {
                  expect(
                    utf8.encode(message['content'] as String).length,
                    lessThanOrEqualTo(65536),
                  );
                }
              }
            }
            final body = _body(loop);
            if (logicalRound == 3) {
              expect(jsonEncode(body), isNot(contains(literal)));
              expect(body['pieces'], isNotEmpty);
              expect(
                find.byKey(const ValueKey('support_tool_confirmation_accept')),
                findsNothing,
              );
              if (domain == 'memory') {
                final kind = literal.endsWith('_DERIVED')
                    ? 'memoryDerived'
                    : literal.endsWith('_DRAFT')
                    ? 'memoryDraft'
                    : literal.endsWith('_REVISION')
                    ? 'memoryRevision'
                    : 'memoryEntry';
                section =
                    (body['pieces'] as List).singleWhere(
                          (p) => p['kind'] == kind,
                        )['selector']
                        as String;
              }
              return loop.search(
                source,
                literal,
                'nine_search',
                section: section,
              );
            }
            if (!readRequested && (body['pieces'] as List).isEmpty) {
              // Native work pages are honest partial results. Continue the SAME
              // literal and issued section/cursor under the original frozen scope.
              // The original 8-round cap remains the finite stopping condition.
              expect(body['complete'], isFalse);
              final cursor = body['nextCursor'] as String;
              emptySearchPages++;
              return loop.search(
                source,
                literal,
                'nine_search_$emptySearchPages',
                section: section,
                cursor: cursor,
              );
            }
            final hits = (body['pieces'] as List)
                .cast<Map<dynamic, dynamic>>()
                .toList();
            final effectSearch =
                !readRequested && literal == 'MODEL_NINE_reconciliation_EFFECT';
            if (effectSearch) {
              // The saved after-state and added-effect record legitimately
              // expose the same scalar. Both must be actual issued matches;
              // read one original selector, not an invented record identity.
              expect(hits, hasLength(2));
              expect(hits.map((h) => h['selector']).toSet(), hasLength(2));
              for (final match in hits) {
                expect(match['kind'], 'reconciliationSavedResult');
                expect(match['state'], state);
                expect(match['excerpt'], literal);
                expect(match['occurrence'], 'first_visible_literal_per_record');
              }
            }
            final hit = effectSearch ? hits[0] : hits.single;
            expect(hit['state'], state);
            expect(jsonEncode(hit), contains(literal));
            if (evidence != null) {
              final binding = (hit['citation'] as Map)['binding'] as Map;
              expect((binding['evidence'] as Map)['state'], evidence);
            }
            if (!readRequested) {
              expect(hit['occurrence'], 'first_visible_literal_per_record');
              readRequested = true;
              return loop.read(source, hit['selector'] as String, 'nine_read');
            }
            expect(body['complete'], isTrue);
            expect(hit['payload'], contains(literal));
            return SourceLoop.answer(
              'Only this approved $domain saved text was read; $state/$evidence is not historical assembled-prompt proof.',
            );
          },
        );
        await loop.start(
          tester,
          text: 'Read the selected native $domain saved source.',
        );
        // Target selection (if any) has finished. This is exactly ONE ORIGINAL
        // body-scope gesture, with no metadata/body before its native custody.
        expect(jsonEncode(f.wire), isNot(contains(literal)));
        expect(find.text('Прочитать и передать модели'), findsOneWidget);
        await loop.apply(tester);
        final reply = await loop.finish(tester);
        expect(reply.status, 'complete');
        expect(f.wire, hasLength(rounds + emptySearchPages));
        expect(f.wire.first['tools'], hasLength(47));
        expect(committed, 3 + emptySearchPages);
        expect(f.wire.length, lessThanOrEqualTo(8));
        expect(f.native.runtime.epoch, epoch);
        expect(f.native.runtime.snapshot.preferences, policy);
        expect(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
          findsNothing,
        );
        for (final request in f.requests) {
          expect(
            request.uri.toString(),
            'https://api.openai.com/v1/chat/completions',
          );
        }
        expect(loop.dispatchAuthorizations, hasLength(f.requests.length));
        expect(
          loop.dispatchAuthorizations,
          everyElement('Bearer ${BackupLoopNative.key}'),
        );
        final outward = jsonEncode(f.wire);
        for (final excluded in [
          sourceExcluded,
          sourceOlderBody,
          sourceInactiveStudioBody,
          'MODEL_NINE_EXCLUDED_DIAGNOSTIC',
          'private-studio-expensive',
          'private-studio-cheap',
          'private-ordinary-block',
          'private-memory-entry',
          'private-revision',
          'private-draft',
          'private-catalog',
          'private-saved-run',
          'private-canon',
          'private-checkpoint-range',
          'private-knowledge',
          'private-knower',
          'private-subject',
          'private-removed-anchor',
          sourceSession,
          sourceStudio,
          sourceCharacter,
        ]) {
          expect(outward, isNot(contains(excluded)));
        }
        for (final other in const [
          'ordinaryPreset',
          'memory',
          'savedSummary',
          'ledgerState',
          'ledgerSnapshot',
          'reconciliation',
          'characterKnowledge',
        ]) {
          if (other != domain) {
            expect(outward, isNot(contains('MODEL_NINE_${other}_BODY')));
          }
        }
        if (domain != 'game') expect(outward, isNot(contains(sourceGameBody)));
        if (domain != 'studioPreset') {
          expect(outward, isNot(contains(sourceStudioBody)));
        }
        sourceNoEgress(f, reply.body);
      },
    );
  }
  for (final (localPreparation, mobile) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    backupLoopTest(
      localPreparation
          ? 'production local preparation sheet -> native catalog -> frozen consent -> contents/search/read -> encrypted provenance -> settled reply${mobile ? ' (390x844, DPR1)' : ''}'
          : 'native catalog -> one frozen consent -> contents/search/read -> durable provenance -> settled reply',
      (tester, f) async {
        if (mobile) {
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          await tester.pump();
        }
        await seedModelSources(tester, f, messages: 4, prepareHistory: false);
        if (localPreparation) {
          await _prepareLocally(tester, f);
        } else {
          await _index(tester, f);
        }
        final loop = SourceLoop(f);
        late String source;
        loop.script(
          SourceLoop.call('astoria_sources_list', {
            'domain': 'game',
          }, id: 'nav-list'),
          rounds: 5,
          next: (round) async {
            if (round == 2) {
              loop.noBody();
              source = _readyGame(loop);
              return SourceLoop.call('astoria_source_contents', {
                'source': source,
              }, id: 'nav-contents');
            }
            await _durableBeforePost(f, round - 2);
            final body = _body(loop);
            expect(body['status'], 'ok');
            expect(body['complete'], isTrue);
            if (round == 3) {
              expect(body['pieces'], hasLength(4));
              expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
              return SourceLoop.call('astoria_source_search', {
                'source': source,
                'literal': '${sourceGameBody}2',
              }, id: 'nav-search');
            }
            if (round == 4) {
              final match = (body['pieces'] as List)
                  .cast<Map<dynamic, dynamic>>()
                  .single;
              expect(jsonEncode(match), contains('${sourceGameBody}2'));
              return SourceLoop.call('astoria_source_read', {
                'source': source,
                'selector': match['selector'],
                'before': 1,
                'after': 1,
              }, id: 'nav-read');
            }
            expect(round, 5);
            expect(body['pieces'], hasLength(3));
            for (final i in [1, 2, 3]) {
              expect(jsonEncode(body), contains('$sourceGameBody$i'));
            }
            _noPrivateSources(f);
            return SourceLoop.answer(
              'Selected active messages read within the frozen scope; saved material is not historical prompt proof.',
            );
          },
        );
        await loop.start(tester);
        loop.noBody();
        expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
        await loop.apply(tester); // Exactly ONE game-source scope gesture.
        final reply = await loop.finish(
          tester,
        ); // No new gesture for search/read.
        expect(reply.status, 'complete', reason: loop.activityDiagnostic);
        expect(f.wire, hasLength(5));
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(
            f,
            reply.id,
            expectedVersion: 4,
            expectedDisclosureCount: 3,
          ),
        );
        expect(recipe.toolDisclosures, hasLength(3));
        expect(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
          findsNothing,
        );
        _noPrivateSources(f);
      },
    );
  }

  backupLoopTest(
    'refused local authored source label is absent from factual reply and later Send',
    (tester, f) async {
      const label = 'LOCAL_ONLY_AUTHOR_LABEL_CANARY';
      await seedModelSources(tester, f, messages: 4);
      await backupLoopReal(
        tester,
        () =>
            (f.native.db.update(f.native.db.characters)
                  ..where((t) => t.charId.equals(sourceCharacter)))
                .write(const CharactersCompanion(name: Value(label))),
      );
      await _index(tester, f);
      final loop = SourceLoop(f);
      loop.script(
        SourceLoop.call('astoria_sources_list', {
          'domain': 'game',
        }, id: 'private-list'),
        rounds: 3,
        next: (round) {
          if (round == 2) {
            return SourceLoop.call('astoria_source_contents', {
              'source': _readyGame(loop),
            }, id: 'private-contents');
          }
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'denied');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer('No source text was disclosed.');
        },
      );
      await loop.start(tester);
      expect(find.textContaining(label), findsWidgets); // Local UI only.
      await loop.cancel(tester);
      final refused = await loop.finish(tester);
      expect(refused.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        refused.body,
        contains('Нативное согласие на эту область не получено или отозвано'),
      );
      expect(refused.body, isNot(contains('No source text was disclosed.')));
      expect(refused.body, isNot(contains(label)));
      expect(jsonEncode(f.wire), isNot(contains(label)));
      loop.noBody();
      final sent = f.wire.length;
      loop.script(
        SourceLoop.answer('New Send has no previous source grant.'),
        rounds: 1,
      );
      await loop.start(tester, confirmation: false); // Real composer Send only.
      final next = await loop.finish(tester);
      expect(next.status, 'complete');
      expect(f.wire.length, sent + 1);
      expect(jsonEncode(f.wire), isNot(contains(label)));
      loop.noBody();
    },
  );
}
