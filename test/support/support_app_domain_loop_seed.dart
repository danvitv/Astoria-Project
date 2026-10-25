import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';

import 'support_app_domain_loop_fixture.dart';

Future<void> seedDomainLoop(DomainLoopFixture f) async {
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
  await c
      .read(personaRepoProvider)
      .put(
        const Persona(
          id: 'domain-persona',
          name: DomainLoopFixture.private,
          prompt: DomainLoopFixture.private,
        ),
      );
  await c
      .read(lorebookRepoProvider)
      .put(
        const Lorebook(
          id: 'domain-lore',
          name: DomainLoopFixture.private,
          description: DomainLoopFixture.private,
        ),
      );
  await c
      .read(presetRepoProvider)
      .put(
        const Preset(
          id: 'domain-collision',
          name: DomainLoopFixture.private,
          summaryPrompt: DomainLoopFixture.private,
        ),
      );
  await c
      .read(studioPresetRepoProvider)
      .upsert(
        const StudioPreset(
          id: 'domain-collision',
          name: DomainLoopFixture.private,
          blocks: [
            StudioPresetBlock(
              id: 'domain-studio-block',
              title: DomainLoopFixture.private,
              content: DomainLoopFixture.private,
            ),
          ],
        ),
      );
  await c
      .read(extensionPresetsRepoProvider)
      .insert(
        const ExtensionPreset(
          id: 'domain-extension',
          name: DomainLoopFixture.private,
          blocks: [
            BlockConfig(
              id: 'domain-extension-block',
              name: DomainLoopFixture.private,
              type: BlockType.script,
              script: DomainLoopFixture.private,
            ),
          ],
        ),
      );
  // Actual original ChatNotifier build over the seeded row. No replacement test
  // queue/controller; native composition discovers this same owner thereafter.
  final loaded = await c.read(chatProvider(DomainLoopFixture.character).future);
  expect(loaded.session!.id, DomainLoopFixture.session);
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

Future<void> seedDomainCollector(DomainLoopFixture f) async {
  final c = f.screen.core.container, db = f.screen.core.native.db;
  final session = (await c
      .read(chatRepoProvider)
      .getById(DomainLoopFixture.session))!;
  final runs = c.read(ledgerReconciliationRunRepoProvider);
  var predecessor = '';
  final saved = <LedgerReconciliationSuccessfulRunRow>[];
  for (final entry in session.messages.indexed) {
    final message = entry.$2;
    final run = LedgerReconciliationRun(
      id: 'domain-reconciliation-${entry.$1}',
      sessionId: session.id,
      ordinal: entry.$1 + 1,
      anchors: [
        ReconciliationAnchor(
          messageId: message.id,
          swipeId: message.swipeId,
          agentSwipeId: message.agentSwipeId,
          role: message.role,
          contentHash: computeHash(message.content),
        ),
      ],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'domain-canon',
      effectiveCanonRevision: 0,
      effectiveCanonHash: 'domain-canon-hash',
      canonicalResult: const {'ops': <Map<String, dynamic>>[]},
      predecessorChainHash: predecessor,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: 10 + entry.$1,
    );
    await db.transaction(() async {
      expect(await runs.append(run), isA<ReconciliationRunAppended>());
      final state = await runs.captureState(session.id);
      await runs.recordEffect(
        runId: run.id,
        sessionId: session.id,
        before: state,
        after: state,
        createdAt: 10 + entry.$1,
      );
    });
    predecessor = run.chainHash;
    saved.add((await runs.getByContentHash(session.id, run.contentHash))!);
  }
  await db
      .into(db.cardEvolutionCollectorRuns)
      .insert(
        CardEvolutionCollectorRunsCompanion.insert(
          id: 'domain-failed-collector',
          sessionId: session.id,
          characterId: DomainLoopFixture.character,
          collectorOrdinal: 1,
          reconciliationRunId: saved.last.id,
          reconciliationRunOrdinal: saved.last.ordinal,
          reconciliationChainHash: saved.last.chainHash,
          rangeHash: CardEvolutionCollectorBatch(saved).rangeHash,
          inputHash: 'domain-input',
          ownerId: 'domain-owner',
          status: 'failed',
          leaseExpiresAt: 0,
          createdAt: 15,
          failedAt: const Value(16),
          failureCode: const Value('synthetic-parser'),
          failureDetail: const Value(DomainLoopFixture.private),
        ),
      );
}
