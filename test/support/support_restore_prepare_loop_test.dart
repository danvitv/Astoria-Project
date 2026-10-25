import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_content_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_domain_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_secondary_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_session_memory_provider.dart';

import 'support_tool_loop_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const action = 'astoria_database_restore_prepare';

  toolLoopTest(
    'MODEL offline preparation is correlated noRestore on SAME old ROOT and DB',
    (f) async {
      _installNativeGraph(f);
      final originalDb = f.container.read(appDbProvider);
      final originalRegistry = f.container.read(
        supportAppActionRegistryProvider,
      );
      final definition = originalRegistry.definitions.singleWhere(
        (d) => d.name == action,
      );
      expect(definition.parameters['properties'], isEmpty);
      expect(definition.parameters['additionalProperties'], false);
      f.replies.addAll([
        f.call(action, const {}),
        f.answer('Database restored successfully.'),
      ]);
      final send = f.send();
      final result = await send.finished;
      expect(await send.accepted, true);
      expect(result.saved, true);
      expect(result.outcome?.status, PrivateTextStatus.error);
      if (Platform.isWindows) {
        expect(result.message?.text, contains('--astoria-recovery'));
        expect(
          result.message?.text,
          contains('не выполнялось и не запланировано'),
        );
      } else {
        expect(result.message?.text, contains('только на Windows'));
        expect(result.message?.text, isNot(contains('--astoria-recovery')));
      }
      expect(result.message?.text, isNot(contains('restored successfully')));
      expect(identical(f.container.read(appDbProvider), originalDb), true);
      expect(
        identical(
          f.container.read(supportAppActionRegistryProvider),
          originalRegistry,
        ),
        true,
      );
      expect(f.wire, hasLength(2));
      expect(result.outcome?.usage?.inputTokens, 31);
      expect(result.outcome?.usage?.outputTokens, 7);
      expect(result.outcome?.usage?.totalTokens, 38);
      final tool = (f.wire[1]['messages'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((m) => m['role'] == 'tool');
      expect(tool['tool_call_id'], 'call_1');
      expect(jsonDecode(tool['content'] as String), {
        'ok': false,
        'code': 'unavailable',
        'effect': 'none',
        'data': {
          'status': Platform.isWindows ? 'restartRequired' : 'unsupported',
          'restore': 'noRestore',
        },
      });
      final rows = await f.native.repo.getMessagesForSession(f.native.session);
      expect(
        rows.singleWhere((m) => m.id == result.message!.id).body,
        result.message!.text,
      );
      expect(f.wire.first['messages'].toString(), contains('empty arguments'));
      for (final hidden in [
        f.boundSyntheticSecret,
        'SYNTHETIC_EXCLUDED_BODY',
        'SYNTHETIC_HIDDEN_PROMPT',
      ]) {
        expect(jsonEncode(f.wire), isNot(contains(hidden)));
      }
    },
  );

  for (final payload in [
    {'path': 'synthetic-not-an-approved-file.db'},
    {'approved': true},
    {'restart': true},
  ]) {
    toolLoopTest(
      'MODEL recovery rejects authority payload ${payload.keys.single}',
      (f) async {
        _installNativeGraph(f);
        f.replies.addAll([
          f.call(action, payload),
          f.answer('Everything was restored.'),
        ]);
        final result = await f.send().finished;
        expect(result.saved, true);
        expect(result.outcome?.status, PrivateTextStatus.error);
        expect(
          result.message?.text,
          isNot(contains('Everything was restored')),
        );
        final tool = (f.wire.last['messages'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((m) => m['role'] == 'tool');
        final content = jsonDecode(tool['content'] as String) as Map;
        expect(content['code'], 'invalidArguments');
        expect(content['effect'], 'none');
        expect(content['data'], isEmpty);
      },
    );
  }
}

// Declare only the constructor-only native graph of the actual registry. Its
// repositories still use the fixture's exact memory DB/cipher overrides; the
// existing file/socket/channel/unexpected-provider tripwires remain active.
void _installNativeGraph(ToolLoopFixture f) => f.isolation.extraAllowed.addAll({
  supportAppNativeDomainAdaptersProvider,
  supportAppControlContentAdaptersProvider,
  supportAppControlContentMutationPortProvider,
  supportAppControlSessionMemoryProvider,
  supportAppControlSecondaryAdaptersProvider,
  supportAppControlRepairAdaptersProvider,
  supportAppRepairNativePortProvider,
  supportAppNativeRepairPortProvider,
  chatNativeOwnerRegistryProvider,
  chatSourceMutationRegistryProvider,
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
