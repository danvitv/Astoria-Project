import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';
import 'support_app_domain_loop_fixture.dart';

final class _RetireAfterProfileInsert extends QueryInterceptor {
  _RetireAfterProfileInsert(this.retire);
  final void Function() retire;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runInsert(executor, statement, args);
    if (statement.contains('support_context_blocks')) retire();
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = SupportWorkspaceSettingsCodec();

  test(
    'global Astoria profile survives all chats with an explicit legacy-permission fixture',
    () async {
      final f = NativeFixture();
      ProviderContainer? container;
      try {
        await f.seed();
        await f.workspace.changeSettings(
          NativeFixture.id,
          (s) => s.copyWith(
            temperature: 0.6,
            maxTokens: 20000,
            reasoningEffort: SupportReasoningEffort.high,
            dcpCompressionEnabled: false,
          ),
        );
        final legacy = await f.database.repoB.getContextBlockById(
          codec.idFor(NativeFixture.id),
        );
        final permission = f.runtime.snapshot.preferences;
        container = ProviderContainer(
          overrides: [
            ...nativeWidgetOverrides(f),
            supportSessionStoreProvider.overrideWithValue(f.workspace),
          ],
        );
        final c = container;
        c.listen(supportWorkspaceProvider, (_, _) {});
        for (
          var i = 0;
          c.read(supportWorkspaceProvider).isLoading && i < 100;
          i++
        ) {
          await Future<void>.delayed(Duration.zero);
          await c.pump();
        }
        final notifier = c.read(supportWorkspaceProvider.notifier);
        expect(c.read(supportWorkspaceProvider).settings.maxTokens, 20000);
        final first = notifier.captureSettingsIntent()!;
        final other = (await notifier.createNewSession())!;
        expect(first.isCurrent, false);
        expect(c.read(supportWorkspaceProvider).settings.temperature, 0.6);
        expect(
          c.read(supportWorkspaceProvider).settings.modelId,
          'synthetic-model',
        );
        expect(f.runtime.snapshot.preferences!.grants, isEmpty);
        expect(f.runtime.snapshot.preferences!.scope, isNull);
        expect(f.runtime.recipientConfirmed, false);
        expect(await notifier.setMaxTokens(4096), true);
        notifier.selectSession(NativeFixture.id);
        await notifier.refresh();
        expect(c.read(supportWorkspaceProvider).settings.maxTokens, 4096);
        expect(f.runtime.snapshot.preferences!.grants, permission!.grants);
        expect(
          await f.database.repoB.getContextBlockById(
            codec.idFor(NativeFixture.id),
          ),
          legacy,
        );
        expect((await f.workspace.readableSettingsFor(other))!.maxTokens, 4096);
        final blocks = await f.database.repoB.getContextBlocksForSession(
          other,
          activeOnly: true,
        );
        expect(blocks.any((b) => b.id == codec.globalId), false);
        final fresh = SupportWorkspaceStore(f.database.repoB, () => f.redactor);
        expect(
          (await fresh.settingsFor(other)).reasoningEffort,
          SupportReasoningEffort.high,
        );
        await f.database.repoB.deleteSession(NativeFixture.id);
        await f.database.repoB.deleteSession(other);
        await notifier.refresh();
        expect(c.read(supportWorkspaceProvider).activeSessionId, isEmpty);
        expect(c.read(supportWorkspaceProvider).settings.maxTokens, 4096);
        expect(notifier.captureSettingsIntent(), isNotNull);
        expect(await notifier.setTemperature(0.8), true);
        expect(
          (await fresh.load(globalSettings: true)).settings['']!.temperature,
          0.8,
        );
      } finally {
        container?.dispose();
        await f.close();
      }
    },
  );

  test(
    'global latest-row mutations serialize and rollback actual SQL on ownership loss',
    () async {
      final f = NativeFixture();
      try {
        await f.seed();
        await f.workspace.load(globalSettings: true);
        final other = SupportWorkspaceStore(f.database.repoB, () => f.redactor);
        await Future.wait([
          f.workspace.changeGlobalSettings(
            (s) => s.copyWith(temperature: 0.9),
            isCurrent: () => true,
          ),
          other.changeGlobalSettings(
            (s) => s.copyWith(maxTokens: 8192),
            isCurrent: () => true,
          ),
        ]);
        final settings = await other.settingsFor(NativeFixture.id);
        expect(settings.temperature, 0.9);
        expect(settings.maxTokens, 8192);
        final before = await f.database.repoB.getContextBlockById(
          codec.globalId,
        );
        var current = true;
        await expectLater(
          f.database.db.runWithInterceptor(
            () => other.changeGlobalSettings(
              (s) => s.copyWith(temperature: 1),
              isCurrent: () => current,
            ),
            interceptor: _RetireAfterProfileInsert(() => current = false),
          ),
          throwsStateError,
        );
        expect(current, false);
        expect(
          await f.database.repoB.getContextBlockById(codec.globalId),
          before,
        );
        final rows = await f.database.db
            .select(f.database.db.supportContextBlocks)
            .get();
        final row = rows.singleWhere(
          (r) => r.id == SupportRepo.assistantSettingsId,
        );
        expect(
          row.protectedFactsCiphertext,
          isNot(contains('synthetic-model')),
        );
        expect(row.sessionId, isEmpty);
        expect(row.isActive, false);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'global corruption cannot fall back to healthy legacy settings or overwrite locked bytes',
    () async {
      final f = NativeFixture();
      try {
        await f.seed();
        await f.workspace.load(globalSettings: true);
        await f.database.repoB.mutateAssistantSettings(
          mutate: (latest) =>
              latest!.copyWith(protectedFactsJson: 'invalid-global-profile'),
        );
        expect(
          (await f.workspace.load(
            globalSettings: true,
          )).settingsAvailability[''],
          SupportSettingsAvailability.corrupt,
        );
        await expectLater(
          f.workspace.settingsFor(NativeFixture.id),
          throwsA(isA<SupportSettingsUnavailable>()),
        );
        await expectLater(
          f.workspace.changeGlobalSettings(
            (s) => s.copyWith(temperature: 1),
            isCurrent: () => true,
          ),
          throwsStateError,
        );
        await f.workspace.recoverGlobalSettings(isCurrent: () => true);
        expect(
          (await f.workspace.settingsFor(NativeFixture.id)).hasConfiguredModel,
          false,
        );
        await (f.database.db.update(
          f.database.db.supportContextBlocks,
        )..where((t) => t.id.equals(codec.globalId))).write(
          const SupportContextBlocksCompanion(
            protectedFactsCiphertext: Value('invalid-envelope'),
          ),
        );
        final before = await f.database.repoB.getContextBlockById(
          codec.globalId,
        );
        expect(
          (await f.workspace.load(
            globalSettings: true,
          )).settingsAvailability[''],
          SupportSettingsAvailability.locked,
        );
        await expectLater(
          f.workspace.recoverGlobalSettings(isCurrent: () => true),
          throwsA(isA<SupportCipherException>()),
        );
        expect(
          await f.database.repoB.getContextBlockById(codec.globalId),
          before,
        );
      } finally {
        await f.close();
      }
    },
  );

  domainLoopTest(
    'MODEL new Astoria chat uses the durable global profile on its actual wire',
    (tester, f) async {
      final core = f.screen.core;
      final id = await configurationAction(tester, () async {
        final notifier = core.container.read(supportWorkspaceProvider.notifier);
        expect(await notifier.setTemperature(0.6), true);
        expect(await notifier.setMaxTokens(20000), true);
        expect(
          await notifier.setReasoningEffort(SupportReasoningEffort.high),
          true,
        );
        expect(await notifier.setDcpCompression(false), true);
        return (await notifier.createNewSession())!;
      });
      await tester.pump();
      f.script(core.answer('GLOBAL_PROFILE_ACTUAL_REPLY'));
      final original = await configurationAction(
        tester,
        () => (
          core.native.repo
              .watchMessagesForSession(id)
              .firstWhere(
                (rows) => rows.any(
                  (m) => m.role == 'assistant' && m.status == 'complete',
                ),
              ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Use the configured global Astoria profile.',
      );
      await tester.pump();
      final originalBridge = core.container.read(supportModelUiBridgeProvider);
      await configurationAction(
        tester,
        () =>
            tester.tap(find.byKey(const ValueKey('support_composer_send_btn'))),
      );
      final rows = await f.screen.join(tester, original.$1);
      await f.screen.terminal(tester, original: originalBridge);
      expect(
        originalBridge.view.runId,
        rows.singleWhere((m) => m.role == 'assistant').runId,
      );
      expect(
        rows.singleWhere((m) => m.role == 'assistant').body,
        'GLOBAL_PROFILE_ACTUAL_REPLY',
      );
      expect(core.wire, hasLength(1));
      expect(core.wire.single['temperature'], 0.6);
      expect(core.wire.single['max_tokens'], 20000);
      expect(core.wire.single['reasoning_effort'], 'high');
      expect((core.wire.single['tools'] as List), hasLength(63));
      expect(
        (await configurationAction(
          tester,
          () => core.native.repo.getMessagesForSession(id),
        )).where((m) => m.role == 'user'),
        hasLength(1),
      );
      f.noEgress(rows.last.body);
    },
  );

  test(
    'global migration refuses a locked priority parent instead of adopting an alternative profile',
    () async {
      final f = NativeFixture();
      try {
        await f.seed();
        final other = await f.workspace.create('Healthy alternative');
        await f.workspace.changeSettings(
          other,
          (s) => s.copyWith(modelId: 'ALTERNATIVE_MODEL'),
        );
        final before = await f.database.db
            .select(f.database.db.supportContextBlocks)
            .get();
        await (f.database.db.update(
          f.database.db.supportSessions,
        )..where((t) => t.id.equals(NativeFixture.id))).write(
          const SupportSessionsCompanion(
            titleCiphertext: Value('invalid-priority-parent'),
          ),
        );
        final snapshot = await f.workspace.load(
          globalSettings: true,
          preferredSessionId: NativeFixture.id,
        );
        expect(
          snapshot.settingsAvailability[''],
          SupportSettingsAvailability.locked,
        );
        expect(snapshot.settings.containsKey(''), false);
        expect(
          await f.database.repoB.getContextBlockById(codec.globalId),
          isNull,
        );
        expect(
          await f.database.db.select(f.database.db.supportContextBlocks).get(),
          before,
        );
      } finally {
        await f.close();
      }
    },
  );
}
