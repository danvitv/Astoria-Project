import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';

import 'support_theme_mode_action_fixture.dart';

export 'support_theme_mode_action_fixture.dart';

String modeHistoryId(int n) => 'mode-history-${n.toString().padLeft(3, '0')}';

Future<void> seedModeHistory(
  ThemeActionFixture f, {
  int count = 1,
  SupportThemeOperation operation = SupportThemeOperation.mode,
  String status = 'applied',
  bool malformed = false,
  bool foreignPreset = false,
}) async {
  final codec = SupportThemeEvidenceCodec(operation: operation);
  const before = SupportThemeValue(
    id: 'a',
    name: 'Historical A',
    mode: 'dark',
    accent: '#112233',
    active: true,
  );
  final after = SupportThemeValue(
    id: foreignPreset ? 'b' : 'a',
    name: 'Historical A',
    mode: 'light',
    accent: '#112233',
    active: true,
  );
  for (var n = 0; n < count; ++n) {
    await f.repo.putMutation(
      SupportMutationRecord(
        id: operation == SupportThemeOperation.mode
            ? modeHistoryId(n)
            : 'selection-history-${n.toString().padLeft(3, '0')}',
        sessionId: ThemeActionFixture.session,
        domain: codec.domainValue,
        targetId: codec.targetValue,
        status: status,
        createdAt: 5,
        beforeJson: malformed
            ? '{"v":99}'
            : codec.encode(
                sessionId: ThemeActionFixture.session,
                value: before,
                policy: f.redaction.redactor,
              ),
        afterJson: codec.encode(
          sessionId: ThemeActionFixture.session,
          value: after,
          policy: f.redaction.redactor,
        ),
      ),
    );
  }
}

Future<String> modeHistorySnapshot(ThemeActionFixture f) async {
  final tables = <String, Object>{};
  for (final name in const [
    'support_sessions',
    'support_messages',
    'support_context_blocks',
    'support_mutation_journal',
    'support_reports',
  ]) {
    tables[name] =
        (await f.db.customSelect('SELECT * FROM $name ORDER BY rowid').get())
            .map((r) => r.data)
            .toList();
  }
  return jsonEncode({
    'tables': tables,
    'theme': f.backing.presets.map((p) => p.toJson()).toList(),
    'active': f.backing.activeId,
    'vault': f.storage.values,
  });
}

/// No historical read may invoke effects, rewrite evidence, create keys or read
/// current theme storage. Only the declared synthetic fixture is inspected.
Future<void> passiveModeHistory(
  ThemeActionFixture f,
  Future<void> Function() body,
) async {
  final before = await modeHistorySnapshot(f);
  final freshReads = f.themeStore.freshReads;
  final modes = modeStore(f).modeWrites.length;
  final selections = f.themeStore.checkedWrites.length;
  final ordinary = f.themeStore.ordinaryWrites.length;
  final lists = f.themeStore.savedLists.length;
  final storage = f.storage.operations.length;
  final events = f.events.length;
  await body();
  expect(await modeHistorySnapshot(f), before);
  expect(
    f.events
        .skip(events)
        .where(
          (e) =>
              e.startsWith('encrypt:') ||
              e.startsWith('insert:') ||
              e.startsWith('update:') ||
              e.startsWith('delete:'),
        ),
    isEmpty,
  );
  expect(f.storage.operations.skip(storage).where((o) => o != 'read'), isEmpty);
  expect(f.themeStore.freshReads, freshReads);
  expect(modeStore(f).modeWrites.length, modes);
  expect(f.themeStore.checkedWrites.length, selections);
  expect(f.themeStore.ordinaryWrites.length, ordinary);
  expect(f.themeStore.savedLists.length, lists);
}
