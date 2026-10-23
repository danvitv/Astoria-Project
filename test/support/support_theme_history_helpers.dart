import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_provider_fixture.dart';

export 'support_theme_provider_fixture.dart';

/// Existing strict declared-memory/FakeVault/real-AEAD fixture, with its exact
/// finite SQL/provider and native/HTTP/file/socket denials through cleanup.
void historyTest(
  String name,
  Future<void> Function(ThemeProviderFixture) body,
) => themeProviderTest(name, body);

const historySession = ThemeProviderFixture.session;
String historyId(int n) => 'history-${n.toString().padLeft(3, '0')}';

Future<void> seedHistory(
  ThemeProviderFixture f, {
  int count = 1,
  String session = historySession,
  String domain = SupportThemeEvidenceCodec.domain,
  String target = SupportThemeEvidenceCodec.target,
  String status = 'applied',
  bool unknownCodec = false,
  int time = 5,
}) async {
  const codec = SupportThemeEvidenceCodec();
  const before = SupportThemeValue(
    id: 'a',
    name: 'History A',
    mode: 'dark',
    accent: '#112233',
    active: true,
  );
  const after = SupportThemeValue(
    id: 'b',
    name: 'History B',
    mode: 'light',
    accent: '#445566',
    active: true,
  );
  for (var i = 0; i < count; i++) {
    await f.repo.putMutation(
      SupportMutationRecord(
        id:
            domain == SupportThemeEvidenceCodec.domain &&
                target == SupportThemeEvidenceCodec.target &&
                session == historySession
            ? historyId(i)
            : 'foreign-${domain.replaceAll('.', '-')}-$target-${i.toString()}',
        sessionId: session,
        domain: domain,
        targetId: target,
        status: status,
        createdAt: time,
        beforeJson: unknownCodec
            ? SupportMutationEvidence.encode('{"v":99}')
            : codec.encode(
                sessionId: session,
                value: before,
                policy: f.redaction.redactor,
              ),
        afterJson: unknownCodec
            ? SupportMutationEvidence.encode('{"v":99}')
            : codec.encode(
                sessionId: session,
                value: after,
                policy: f.redaction.redactor,
              ),
      ),
    );
  }
}

Future<SupportMutationHistoryPage?> coreHistory(
  ThemeProviderFixture f, {
  SupportMutationHistoryCursor? cursor,
  bool Function()? current,
  SupportRepo? repo,
  String session = historySession,
  String domain = SupportThemeEvidenceCodec.domain,
  String target = SupportThemeEvidenceCodec.target,
}) => (repo ?? f.repo).discoverMutationHistory(
  sessionId: session,
  domain: domain,
  targetId: target,
  isCurrent: current ?? (() => true),
  cursor: cursor,
);

Future<void> seedHistoryCanaries(ThemeProviderFixture f) async {
  await f.repo.putMessage(
    const SupportMessage(
      id: 'unrelated-history-message',
      sessionId: historySession,
      role: 'assistant',
      body: 'SYNTHETIC_BODY_CANARY',
      cardsJson: 'SYNTHETIC_CARDS_CANARY',
      createdAt: 4,
    ),
  );
  await f.repo.putContextBlock(
    const SupportContextBlock(
      id: 'unrelated-history-context',
      sessionId: historySession,
      startMessageId: 'unrelated-history-message',
      endMessageId: 'unrelated-history-message',
      summary: 'SYNTHETIC_CONTEXT_CANARY',
      createdAt: 4,
    ),
  );
  await f.repo.putReport(
    const SupportReportRecord(
      id: 'unrelated-history-report',
      sessionId: historySession,
      fileHash: 'SYNTHETIC_REPORT_CANARY',
      createdAt: 4,
    ),
  );
}

Future<String> historyBaseline(ThemeProviderFixture f) async {
  final tables = <String, Object>{};
  for (final table in const [
    'support_sessions',
    'support_messages',
    'support_context_blocks',
    'support_mutation_journal',
    'support_reports',
  ]) {
    tables[table] =
        (await f.db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
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

/// Start after deliberate synthetic seeding/changes; exact raw five support
/// tables, theme backing, vault values and ALL writes/encrypts stay unchanged.
Future<void> readOnlyHistory(
  ThemeProviderFixture f,
  Future<void> Function() body,
) async {
  final before = await historyBaseline(f);
  final operations = f.storage.operations.length;
  final checked = List.of(f.harness.store.checkedWrites);
  final ordinary = List.of(f.harness.store.ordinaryWrites);
  final lists = f.harness.store.savedLists.length;
  final statementCount = f.sql.statements.length;
  final freshReads = f.harness.store.freshReads;
  final primitive = f.primitive.event;
  final sql = f.sql.event;
  final writes = <String>[];
  f.primitive.event = (e) async {
    if (e.startsWith('encrypt:')) writes.add(e);
    await primitive?.call(e);
  };
  f.sql.event = (e) async {
    if (RegExp(r'^(insert|update|delete):', caseSensitive: false).hasMatch(e)) {
      writes.add(e);
    }
    await sql?.call(e);
  };
  try {
    await body();
    expect(await historyBaseline(f), before);
    expect(writes, isEmpty);
    expect(
      f.sql.statements
          .skip(statementCount)
          .where(
            (s) => RegExp(
              r'^\s*(INSERT|UPDATE|DELETE)\b',
              caseSensitive: false,
            ).hasMatch(s),
          ),
      isEmpty,
    );
    expect(
      f.storage.operations.skip(operations).where((o) => o != 'read'),
      isEmpty,
    );
    expect(f.harness.store.checkedWrites, checked);
    expect(f.harness.store.ordinaryWrites, ordinary);
    expect(f.harness.store.savedLists.length, lists);
    expect(f.harness.store.freshReads, freshReads);
  } finally {
    f.primitive.event = primitive;
    f.sql.event = sql;
  }
}

Future<void> changeHistory(
  ThemeProviderFixture f,
  String id,
  String column,
  Object value,
) => f.db.customStatement(
  'UPDATE support_mutation_journal SET $column = ? WHERE id = ?',
  [value, id],
);

Future<void> removeHistory(ThemeProviderFixture f, String id) => f.db
    .customStatement('DELETE FROM support_mutation_journal WHERE id = ?', [id]);

Future<void> scopeOff(ThemeProviderFixture f) async {
  final review = (await f.controller.prepareReview(resolveRecipient: false))!;
  expect(await f.controller.selectTheme(review, false), isTrue);
}

Future<void> grantOff(ThemeProviderFixture f) async {
  final review = (await f.controller.prepareReview(resolveRecipient: false))!;
  expect(
    await f.controller.setGrant(
      review,
      SupportPermission.readSafeSettings,
      false,
    ),
    isTrue,
  );
}

SupportThemeIntent nativeHistoryIntent(ThemeProviderFixture f) {
  final controller = f.controller;
  final displayed = controller.view.displayedIntent!;
  final lifetime = f.uiLifetime;
  return f.binding.service.emit(
    controller: controller,
    uiLifetime: lifetime,
    isCurrent: () =>
        f.uiCurrent &&
        identical(lifetime, f.uiLifetime) &&
        controller.isDisplayedIntentCurrent(displayed),
  )!;
}
