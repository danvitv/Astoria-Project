import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';

import 'support_app_domain_loop_fixture.dart';

export 'support_app_domain_loop_fixture.dart';

/// Same actual model-loop/root/native-footer, memory SQLite/FakeVault/AEAD and
/// retained redactor fixture. Only NEW fixtures seed a dormant target; the old
/// loaded-owner seed and passing fixtures are untouched. Target provider reads
/// are a pregraph tripwire unless a test explicitly introduces a real live race.
void dormantRepairTest(
  String name,
  Future<void> Function(WidgetTester, DomainLoopFixture) body,
) {
  toolLoopWidgetTest(name, (tester, screen) async {
    final f = DomainLoopFixture(screen);
    f.installFiniteGraph();
    screen.core.isolation.extraAllowed.remove(
      chatProvider(DomainLoopFixture.character),
    );
    try {
      await configurationAction(tester, () => seedDormantRepair(f));
      expect(
        screen.core.container.exists(chatProvider(DomainLoopFixture.character)),
        false,
      );
      await body(tester, f);
    } finally {
      for (final release in f.releases) {
        if (!release.isCompleted) release.complete();
      }
      screen.core.native.sql.afterSelect = null;
      screen.core.native.sql.afterWrite = null;
      screen.core.native.primitive.afterEncrypt = null;
      screen.core.native.storage.beforeRead = null;
      screen.core.native.storage.beforeWrite = null;
      await configurationAction(tester, () async {
        final owners = screen.core.container.read(
          chatNativeOwnerRegistryProvider,
        );
        for (final owner in owners.loaded) {
          await owner.queue.settle();
        }
        await screen.core.container
            .read(supportAppNativeRepairPortProvider)
            .maintenance
            ?.settleOwnedWork();
      });
    }
  });
}

Future<void> seedDormantRepair(DomainLoopFixture f) async {
  final c = f.screen.core.container;
  await c
      .read(characterRepoProvider)
      .put(
        const Character(
          id: DomainLoopFixture.character,
          name: DomainLoopFixture.private,
          description: DomainLoopFixture.private,
          systemPrompt: DomainLoopFixture.private,
          variantGroupId: DomainLoopFixture.character,
        ),
      );
  await c
      .read(chatRepoProvider)
      .put(
        ChatSession(
          id: DomainLoopFixture.session,
          characterId: DomainLoopFixture.character,
          sessionIndex: 0,
          messages: [
            for (var i = 1; i <= 3; i++)
              ChatMessage(
                id: 'domain-message-$i',
                role: 'user',
                content: DomainLoopFixture.private,
              ),
          ],
        ),
      );
  for (final name in ['world:location', 'world:active_threats']) {
    await c
        .read(trackerRepoProvider)
        .upsert(
          Tracker(
            sessionId: DomainLoopFixture.session,
            name: name,
            value: DomainLoopFixture.private,
            scope: 'ledger',
            provenance: 'manual_session_repair',
            updatedAt: 3,
          ),
        );
  }
  await f.screen.core.native.db
      .into(f.screen.core.native.db.trackerSnapshots)
      .insert(
        TrackerSnapshotsCompanion.insert(
          sessionId: DomainLoopFixture.session,
          messageId: '',
          committed: const Value(1),
          trackersJson: const Value('[]'),
          createdAt: const Value(1),
        ),
      );
}

void scriptDormantRepair(DomainLoopFixture f, {bool collector = false}) {
  final core = f.screen.core;
  f.script(
    core.call('astoria_session_integrity', {'operation': 'discover'}),
    next: (round) {
      final data = f.lastData();
      if (round == 2) {
        final record = (data['records'] as List).cast<Map>().single;
        expect(record['sessionId'], DomainLoopFixture.session);
        expect(data['bodyAccess'], 'notGranted');
        return core.call('astoria_session_integrity', {
          'operation': 'inspect',
          'session': record['session'],
        }, id: 'dormant_inspect');
      }
      if (round == 3) {
        final record = (data['records'] as List).cast<Map>().firstWhere(
          (r) =>
              r['kind'] == (collector ? 'collectorAttempt' : 'liveLedger') &&
              r['availability'] ==
                  (collector ? 'deleteUnusedAttempt' : 'correctExistingValue'),
        );
        return core.call('astoria_session_repair', {
          'operation': collector ? 'deleteUnusedCollector' : 'correctLedger',
          'target': record['id'],
          if (!collector) 'value': 'Supplied dormant correction',
        }, id: 'dormant_apply');
      }
      // Finite refusal case only; never substitute unavailable for a positive Apply.
      expect(f.results.last['effect'], 'none');
      return core.answer('Native repair was not admitted.');
    },
  );
}

void scriptDormantUndo(DomainLoopFixture f) {
  final core = f.screen.core;
  f.script(
    core.call('astoria_session_integrity', {'operation': 'receipts'}),
    next: (_) {
      final record = (f.lastData()['records'] as List).cast<Map>().single;
      return core.call('astoria_session_repair_undo', {
        'receipt': record['receipt'],
      }, id: 'dormant_undo');
    },
  );
}

void expectStillDormant(DomainLoopFixture f) {
  final c = f.screen.core.container;
  expect(c.exists(chatProvider(DomainLoopFixture.character)), false);
  expect(c.read(chatNativeOwnerRegistryProvider).loaded, isEmpty);
}
