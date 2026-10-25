import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';

import 'support_app_dormant_repair_fixture.dart';

void main() {
  dormantRepairTest(
    'MODEL native discovery continuation reaches older session and repairs its Collector',
    (tester, f) async {
      final core = f.screen.core, c = core.container, db = core.native.db;
      await configurationAction(tester, () async {
        final chats = c.read(chatRepoProvider);
        for (var i = 1; i <= 79; i++) {
          await chats.put(
            ChatSession(
              id: 'pagination-newer-$i',
              characterId: DomainLoopFixture.character,
              sessionIndex: i,
              updatedAt: i,
              messages: [
                ChatMessage(
                  id: 'pagination-message-$i',
                  role: 'user',
                  content: DomainLoopFixture.private,
                ),
              ],
            ),
          );
        }
        await seedDomainCollector(f);
      });
      final offsets = <int>[0];
      final seen = <String>{};
      f.script(
        core.call('astoria_session_integrity', {'operation': 'discover'}),
        next: (round) {
          final data = f.lastData();
          final records = (data['records'] as List)
              .cast<Map<dynamic, dynamic>>();
          if (round <= 6) {
            expect(data['bodyAccess'], 'notGranted');
            expect(data['count'], 80);
            expect(records, hasLength(16));
            for (final record in records) {
              expect(seen.add(record['sessionId'] as String), true);
            }
            final continuation = data['nextOffset'];
            if (continuation != null) {
              offsets.add(continuation as int);
              return core.call('astoria_session_integrity', {
                'operation': 'discover',
                'offset': continuation,
              }, id: 'discover_$continuation');
            }
            expect(offsets, [0, 16, 32, 48, 64]);
            expect(seen, hasLength(80));
            expect(round, 6);
            final target = records.singleWhere(
              (r) => r['sessionId'] == DomainLoopFixture.session,
            );
            return core.call('astoria_session_integrity', {
              'operation': 'inspect',
              'session': target['session'],
            }, id: 'older_inspect');
          }
          final target = records.singleWhere(
            (r) =>
                r['kind'] == 'collectorAttempt' &&
                r['availability'] == 'deleteUnusedAttempt',
          );
          return core.call('astoria_session_repair', {
            'operation': 'deleteUnusedCollector',
            'target': target['id'],
          }, id: 'older_repair');
        },
      );
      await f.start(tester);
      expectStillDormant(f);
      await f.apply(tester);
      final reply = await f.finish(tester);
      expect(reply.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(7));
      expect(
        await configurationAction(
          tester,
          () => db.select(db.cardEvolutionCollectorRuns).get(),
        ),
        isEmpty,
      );
      final journal = await configurationAction(
        tester,
        () => db.select(db.supportMutationJournal).get(),
      );
      expect(journal.single.status, 'applied');
      expect(journal.single.beforeCiphertext, isNotEmpty);
      expect(
        journal.single.beforeCiphertext,
        isNot(contains(DomainLoopFixture.private)),
      );
      expectStillDormant(f);
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL discovery offsets preserve inspection limits and terminate past the end',
    (tester, f) async {
      final core = f.screen.core;
      String? session;
      f.script(
        core.call('astoria_session_integrity', {'operation': 'discover'}),
        next: (round) {
          final result = f.lastResult();
          final data = result['data'] as Map<dynamic, dynamic>;
          if (round == 2) {
            session =
                ((data['records'] as List).single
                        as Map<dynamic, dynamic>)['session']
                    as String;
          } else if (round <= 5 || round == 7) {
            expect(result['code'], 'invalidArguments');
            expect(result['effect'], 'none');
          } else {
            expect(result['code'], 'completed');
            expect(data['records'], isEmpty);
            expect(data['count'], 1);
            expect(data['nextOffset'], isNull);
          }
          return switch (round) {
            2 => core.call('astoria_session_integrity', {
              'operation': 'inspect',
              'session': session,
              'offset': 64,
            }, id: 'inspect_limit'),
            3 => core.call('astoria_session_integrity', {
              'operation': 'receipts',
              'offset': 64,
            }, id: 'receipt_limit'),
            4 => core.call('astoria_database_health', {
              'offset': 1025,
            }, id: 'health_limit'),
            5 => core.call('astoria_session_integrity', {
              'operation': 'discover',
              'offset': ChatRepo.maxControlMetadataOffset,
            }, id: 'past_end'),
            6 => core.call('astoria_session_integrity', {
              'operation': 'discover',
              'offset': ChatRepo.maxControlMetadataOffset + 1,
            }, id: 'invalid_discovery'),
            _ => core.answer('Only bounded metadata was inspected.'),
          };
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(core.wire, hasLength(7));
      expect(f.results.every((r) => r['effect'] == 'none'), true);
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL safe native discovery repairs dangling DB membership and fresh native Undo',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      final folder = await configurationAction(
        tester,
        () => c
            .read(characterFolderRepoProvider)
            .create(name: DomainLoopFixture.private),
      );
      await configurationAction(
        tester,
        () => c
            .read(characterFolderRepoProvider)
            .addMember(folder.id, 'domain-missing-character'),
      );
      f.script(
        core.call('astoria_database_health', {'operation': 'discover'}),
        next: (_) {
          final record = (f.lastData()['records'] as List)
              .cast<Map<dynamic, dynamic>>()
              .single;
          return core.call('astoria_database_repair', {
            'target': record['target'],
          }, id: 'repair_call');
        },
      );
      await f.start(tester);
      await f.apply(tester);
      final repaired = await f.finish(tester);
      expect(
        await configurationAction(
          tester,
          () => c.read(characterFolderRepoProvider).getAllMembers(),
        ),
        isEmpty,
      );
      final journal = await configurationAction(
        tester,
        () =>
            core.native.db.select(core.native.db.supportMutationJournal).get(),
      );
      expect(journal.single.status, 'applied');
      expect(
        journal.single.beforeCiphertext,
        isNot(contains(DomainLoopFixture.private)),
      );
      expect(journal.single.afterCiphertext, isNotEmpty);
      expect(repaired.status, 'stopped');
      expect(repaired.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(2));
      // Receipt discovery addresses ONLY the actual retained owner object in this
      // SAME Astoria parent. The later run must supply a fresh native final Apply.
      f.script(
        core.call('astoria_database_health', {'operation': 'receipts'}),
        next: (_) {
          final record = (f.lastData()['records'] as List)
              .cast<Map<dynamic, dynamic>>()
              .single;
          return core.call('astoria_database_repair_undo', {
            'receipt': record['receipt'],
          }, id: 'undo_call');
        },
      );
      await f.start(tester);
      await f.apply(tester);
      final undone = await f.finish(tester);
      final members = await configurationAction(
        tester,
        () => c.read(characterFolderRepoProvider).getAllMembers(),
      );
      expect(members.single.charId, 'domain-missing-character');
      expect(members.single.folderId, folder.id);
      expect(undone.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(4));
      f.noEgress('${repaired.body}${undone.body}');
    },
  );

  for (final collector in [false, true]) {
    domainLoopTest(
      'MODEL ${collector ? 'Collector deletion' : 'Ledger correction'} uses original queue, journal, revision and Undo',
      (tester, f) async {
        final core = f.screen.core, c = core.container;
        if (collector)
          await configurationAction(tester, () => seedDomainCollector(f));
        final originalMessages = await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
        );
        f.script(
          core.call('astoria_session_integrity', {'operation': 'discover'}),
          next: (round) {
            final data = f.lastData();
            if (round == 2) {
              final record = (data['records'] as List)
                  .cast<Map<dynamic, dynamic>>()
                  .single;
              return core.call('astoria_session_integrity', {
                'operation': 'inspect',
                'session': record['session'],
              }, id: 'inspect_call');
            }
            final record = (data['records'] as List)
                .cast<Map<dynamic, dynamic>>()
                .firstWhere(
                  (r) =>
                      r['kind'] ==
                          (collector ? 'collectorAttempt' : 'liveLedger') &&
                      r['availability'] ==
                          (collector
                              ? 'deleteUnusedAttempt'
                              : 'correctExistingValue'),
                );
            return core.call('astoria_session_repair', {
              'operation': collector
                  ? 'deleteUnusedCollector'
                  : 'correctLedger',
              'target': record['id'],
              if (!collector) 'value': 'Supplied repaired value',
            }, id: 'effect_call');
          },
        );
        await f.start(tester);
        await f.apply(tester);
        final applied = await f.finish(tester);
        final trackers = await configurationAction(
          tester,
          () => core.native.db.select(core.native.db.trackerRows).get(),
        );
        if (collector) {
          expect(
            await configurationAction(
              tester,
              () => core.native.db
                  .select(core.native.db.cardEvolutionCollectorRuns)
                  .get(),
            ),
            isEmpty,
          );
        } else {
          expect(
            trackers.where((r) => r.value == 'Supplied repaired value'),
            hasLength(1),
          );
          expect(trackers.singleWhere((r) => r.scope == 'system').value, '1');
        }
        expect(applied.status, 'stopped');
        expect(applied.body, contains('изменение сохранено'));
        expect(core.wire, hasLength(3));
        final originalOwner = await configurationAction(
          tester,
          () => c.read(chatProvider(DomainLoopFixture.character).future),
        );
        expect(
          originalOwner.session!.messages.map((m) => m.toJson()).toList(),
          originalMessages!.messages.map((m) => m.toJson()).toList(),
        );
        f.script(
          core.call('astoria_session_integrity', {'operation': 'receipts'}),
          next: (_) {
            final record = (f.lastData()['records'] as List)
                .cast<Map<dynamic, dynamic>>()
                .single;
            return core.call('astoria_session_repair_undo', {
              'receipt': record['receipt'],
            }, id: 'undo_call');
          },
        );
        await f.start(tester);
        await f.apply(tester);
        final undone = await f.finish(tester);
        if (collector) {
          final row = await configurationAction(
            tester,
            () => core.native.db
                .select(core.native.db.cardEvolutionCollectorRuns)
                .get(),
          );
          expect(row.single.failureDetail, DomainLoopFixture.private);
        } else {
          final restored = await configurationAction(
            tester,
            () => core.native.db.select(core.native.db.trackerRows).get(),
          );
          expect(
            restored
                .where((r) => r.scope == 'ledger')
                .every((r) => r.value == DomainLoopFixture.private),
            true,
          );
          expect(restored.singleWhere((r) => r.scope == 'system').value, '2');
        }
        final snapshots = await configurationAction(
          tester,
          () => core.native.db.select(core.native.db.trackerSnapshots).get(),
        );
        expect(snapshots.single.trackersJson, '[]');
        expect(undone.body, contains('изменение сохранено'));
        expect(core.wire, hasLength(5));
        f.noEgress('${applied.body}${undone.body}');
      },
    );
  }

  domainLoopTest(
    'MODEL registered whole DB health and actual recorded canonical hashes return only metadata',
    (tester, f) async {
      final core = f.screen.core;
      await configurationAction(tester, () => seedDomainCollector(f));
      f.script(
        core.call('astoria_database_health', {'rowsPerTable': 4}),
        next: (round) {
          final data = f.lastData();
          if (round == 2) {
            expect(data['registeredTables'], core.native.db.allTables.length);
            expect(data['semanticValidation'], 'notChecked');
            return core.call('astoria_session_integrity', {
              'operation': 'discover',
            }, id: 'discover_call');
          }
          if (round == 3) {
            final record = (data['records'] as List)
                .cast<Map<dynamic, dynamic>>()
                .single;
            return core.call('astoria_session_integrity', {
              'operation': 'recordedHashes',
              'session': record['session'],
            }, id: 'hash_call');
          }
          expect(data['narrativeTruth'], 'notChecked');
          expect(data['complete'], true);
          expect(data['runsChecked'], 3);
          expect(data['effectsChecked'], 3);
          return core.answer('Bounded native metadata inspection complete.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(reply.status, 'complete');
      expect(core.wire, hasLength(4));
      expect(f.results.every((r) => r['effect'] == 'none'), true);
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );
}
