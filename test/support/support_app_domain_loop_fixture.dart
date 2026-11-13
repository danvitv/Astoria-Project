import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/session_mutation_gate.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/generating_sessions_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_native_owner.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_content_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_session_memory_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_secondary_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_domain_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';

import 'support_tool_loop_screen_fixture.dart';
import 'support_tool_loop_configuration_fixture.dart'
    show configurationAction, configurationModal, configurationDecision;
import 'support_app_domain_loop_seed.dart';

export 'support_tool_loop_screen_fixture.dart';
export 'support_tool_loop_configuration_fixture.dart'
    show configurationAction, configurationModal, configurationDecision;
export 'support_app_domain_loop_seed.dart';

/// New cases only. Existing phase fixtures are imported, never edited or rerun.
/// Their original memory DB/FakeVault/real AEAD/root/socket-free JSON/native UI
/// and pregraph file/socket/channel tripwires remain in effect through cleanup.
void domainLoopTest(
  String name,
  Future<void> Function(WidgetTester, DomainLoopFixture) body, {
  bool nativeSourceFile = false,
}) {
  toolLoopWidgetTest(name, (tester, screen) async {
    final f = DomainLoopFixture(screen);
    f.installFiniteGraph(); // BEFORE any new production domain provider is read.
    try {
      await configurationAction(tester, () => seedDomainLoop(f));
      await body(tester, f);
    } finally {
      for (final release in f.releases) {
        if (!release.isCompleted) release.complete();
      }
      screen.core.native.sql.afterSelect = null;
      screen.core.native.sql.afterWrite = null;
      screen.core.native.sql.beforeOuterSend = null;
      screen.core.native.sql.afterOuterSend = null;
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
      });
    }
  }, nativeSourceFile: nativeSourceFile);
}

final class DomainLoopFixture {
  DomainLoopFixture(this.screen);
  final ToolLoopScreenFixture screen;
  final releases = <Completer<void>>[];
  Set<String> _previous = {};
  Future<List<SupportMessage>>? _settlement;
  SupportMessage? reply;
  final results = <Map<String, dynamic>>[];
  static const character = 'domain-character';
  static const session = 'domain-character_0';
  static const private = 'SYNTHETIC_DOMAIN_PRIVATE_BODY';
  Completer<void> release() {
    final gate = Completer<void>();
    releases.add(gate);
    return gate;
  }

  void installFiniteGraph() => screen.core.isolation.extraAllowed.addAll({
    supportAppNativeDomainAdaptersProvider,
    supportAppControlContentAdaptersProvider,
    supportAppControlContentMutationPortProvider,
    supportAppControlSessionMemoryProvider,
    supportAppControlSecondaryAdaptersProvider,
    supportAppControlRepairAdaptersProvider,
    supportAppRepairNativePortProvider,
    supportAppNativeRepairPortProvider,
    chatNativeOwnerRegistryProvider,
    // Real per-container, memory-only ownership gate; no DB or native startup.
    sessionMutationGateProvider,
    chatSourceMutationRegistryProvider,
    chatProvider(character),
    generatingSessionsProvider,
    characterRepoProvider,
    chatRepoProvider,
    personaRepoProvider,
    lorebookRepoProvider,
    presetRepoProvider,
    studioPresetRepoProvider,
    characterFolderRepoProvider,
    presetFolderRepoProvider,
    extensionPresetsRepoProvider,
    extensionPresetsProvider,
    memoryBookRepoProvider,
    memoryCatalogRepoProvider,
    memoryActiveDraftsProvider,
    memoryBookRevisionProvider,
    memoryNativeEntryOwnerRegistryProvider,
    rewriteNativeReviewOwnerRegistryProvider,
    llmRequestCaptureRepoProvider,
    characterRevisionRepoProvider,
    characterSessionBaselineRepoProvider,
    characterKnowledgeFactRepoProvider,
    appliedCanonTransitionRepoProvider,
    canonTransitionFactRefRepoProvider,
    ledgerRawTrackerStateReaderProvider,
    trackerRepoProvider,
    trackerSnapshotRepoProvider,
    sessionCanonCheckpointRepoProvider,
    ledgerReconciliationCheckpointRepoProvider,
    ledgerReconciliationRunRepoProvider,
    cardEvolutionCollectorRunRepoProvider,
  });

  Map<String, dynamic> lastResult() {
    final messages = screen.core.wire.last['messages'] as List;
    final tool = messages.cast<Map<dynamic, dynamic>>().lastWhere(
      (m) => m['role'] == 'tool',
    );
    final value = Map<String, dynamic>.from(
      jsonDecode(tool['content'] as String) as Map,
    );
    results.add(value);
    return value;
  }

  Map<String, dynamic> lastData() =>
      Map<String, dynamic>.from(lastResult()['data'] as Map);

  void script(
    Map<String, Object?> first, {
    Map<String, Object?> Function(int round)? next,
  }) {
    final start = screen.core.wire.length;
    screen.core.replies.add(first);
    screen.core.atFetch = (round) async {
      if (round > start + 1 && next != null) {
        screen.core.replies.add(next(round - start));
      }
    };
  }

  Future<void> start(
    WidgetTester tester, {
    bool confirmation = true,
    String instruction = 'Выполни только точную показанную операцию Astoria.',
  }) async {
    final old = await configurationAction(
      tester,
      () => screen.core.native.repo.getMessagesForSession(
        screen.core.native.session,
      ),
    );
    _previous = old.map((m) => m.id).toSet();
    final boxed = await configurationAction(
      tester,
      () => (
        screen.core.native.repo
            .watchMessagesForSession(screen.core.native.session)
            .firstWhere(
              (rows) => rows.any(
                (m) =>
                    !_previous.contains(m.id) &&
                    m.role == 'assistant' &&
                    m.runId != null &&
                    const {
                      'complete',
                      'error',
                      'stopped',
                      'limited',
                    }.contains(m.status),
              ),
            ),
      ),
    );
    _settlement =
        boxed.$1; // Original real-async encrypted stream; not FakeAsync SQL.
    await tester.enterText(find.byType(TextField).first, instruction);
    await tester.pump();
    final send = find.byKey(const ValueKey('support_composer_send_btn'));
    expect(send.hitTestable(), findsOneWidget);
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    await configurationAction(tester, () => tester.tap(send));
    if (confirmation) await configurationModal(tester, screen);
  }

  Future<SupportMessage> finish(WidgetTester tester) async {
    final rows = await screen.join(tester, _settlement!);
    reply = rows.singleWhere(
      (m) =>
          !_previous.contains(m.id) && m.role == 'assistant' && m.runId != null,
    );
    await tester.pump();
    return reply!;
  }

  Future<void> apply(WidgetTester tester) =>
      configurationDecision(tester, 'accept');
  Future<void> cancel(WidgetTester tester) =>
      configurationDecision(tester, 'cancel');
  void noEgress([String text = '']) {
    final outward =
        '${jsonEncode(screen.core.wire)}${jsonEncode(results)}$text';
    for (final canary in [
      private,
      screen.core.boundSyntheticSecret,
      'SYNTHETIC_HIDDEN_PROMPT',
      'SYNTHETIC_EXCLUDED_BODY',
      'world:location',
      'world:active_threats',
      'domain-failed-collector',
      'domain-canon-hash',
    ]) {
      expect(outward, isNot(contains(canary)));
    }
  }
}
