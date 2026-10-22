import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';

const importFenceSupportTables = [
  'support_sessions',
  'support_messages',
  'support_context_blocks',
  'support_mutation_journal',
  'support_reports',
];

/// Actual encryption with exclusively synthetic in-memory key storage.
Future<SupportRepo> seedImportFenceSupport(AppDatabase db) async {
  final repo = SupportRepo(
    db,
    SupportPayloadCipher(
      vault: CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      ),
    ),
  );
  await repo.createSession(
    const SupportSession(
      id: 'local-support',
      title: 'Local synthetic title',
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  await repo.appendMessage(
    const SupportMessage(
      id: 'local-message',
      sessionId: 'local-support',
      role: 'user',
      body: 'STATIC_LOCAL_ENCRYPTED_BODY_318549',
      cardsJson: '[]',
      createdAt: 2,
    ),
  );
  await repo.putContextBlock(
    const SupportContextBlock(
      id: 'local-context',
      sessionId: 'local-support',
      startMessageId: 'local-message',
      endMessageId: 'local-message',
      summary: 'Synthetic local summary',
      protectedFactsJson: '[]',
      isActive: true,
      createdAt: 3,
    ),
  );
  await repo.recordMutation(
    const SupportMutationRecord(
      id: 'local-mutation',
      sessionId: 'local-support',
      domain: 'preset',
      targetId: 'synthetic-preset',
      beforeJson: '{}',
      afterJson: '{}',
      status: 'applied',
      createdAt: 4,
    ),
  );
  await repo.recordReport(
    const SupportReportRecord(
      id: 'local-report',
      sessionId: 'local-support',
      fileHash: 'sha256:synthetic',
      status: 'exported',
      createdAt: 5,
    ),
  );
  return repo;
}

Future<Map<String, List<Map<String, dynamic>>>> importFenceSupportSnapshot(
  AppDatabase db,
) async => {
  for (final table in importFenceSupportTables)
    table: (await db.customSelect('SELECT * FROM $table').get())
        .map((row) => Map<String, dynamic>.from(row.data))
        .toList(),
};
