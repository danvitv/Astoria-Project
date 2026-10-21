import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../credentials/fake_credential_storage.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp(
      'support_backup_isolation_',
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'normal archive import ignores support tables and imports roleplay',
    () async {
      final vault = CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      );
      final repo = SupportRepo(db, SupportPayloadCipher(vault: vault));
      await repo.createSession(
        const SupportSession(
          id: 'support-1',
          title: 'Local title',
          createdAt: 10,
          updatedAt: 20,
          pinned: true,
          mode: 'hybrid',
        ),
      );
      await repo.appendMessage(
        const SupportMessage(
          id: 'message-1',
          sessionId: 'support-1',
          role: 'user',
          body: 'local encrypted history',
          cardsJson: '[]',
          status: 'complete',
          createdAt: 30,
        ),
      );
      await repo.putContextBlock(
        const SupportContextBlock(
          id: 'context-1',
          sessionId: 'support-1',
          startMessageId: 'message-1',
          endMessageId: 'message-1',
          summary: 'local context',
          protectedFactsJson: '[]',
          isActive: true,
          createdAt: 40,
        ),
      );
      await repo.recordMutation(
        const SupportMutationRecord(
          id: 'mutation-1',
          sessionId: 'support-1',
          domain: 'preset',
          targetId: 'p1',
          beforeJson: '{}',
          afterJson: '{"changed":true}',
          status: 'applied',
          createdAt: 50,
        ),
      );
      await repo.recordReport(
        const SupportReportRecord(
          id: 'report-1',
          sessionId: 'support-1',
          fileHash: 'sha256:local',
          status: 'exported',
          createdAt: 60,
        ),
      );

      final before = <String, List<Map<String, dynamic>>>{};
      for (final table in const [
        'support_sessions',
        'support_messages',
        'support_context_blocks',
        'support_mutation_journal',
        'support_reports',
      ]) {
        before[table] = (await db.customSelect('SELECT * FROM $table').get())
            .map((row) => Map<String, dynamic>.from(row.data))
            .toList();
      }

      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode('{"schemaVersion":13,"keysStripped":false}'),
          ),
        )
        ..addFile(
          ArchiveFile.bytes(
            'tables/characters.jsonl',
            utf8.encode(
              '${jsonEncode({"char_id": "roleplay-1", "name": "Imported character"})}\n',
            ),
          ),
        );
      for (final table in before.keys) {
        archive.addFile(
          ArchiveFile.bytes(
            'tables/$table.jsonl',
            utf8.encode('${jsonEncode({"malicious": "overwrite"})}\n'),
          ),
        );
      }
      final path = '${tempDir.path}${Platform.pathSeparator}malicious.glz';
      final encoder = ZipFileEncoder()..create(path);
      for (final file in archive.files) {
        encoder.addArchiveFile(file);
      }
      await encoder.close();

      await FlutterBackupImporter(
        db,
        ImageStorageService(tempDir.path),
      ).importFromZipFile(path);

      for (final entry in before.entries) {
        final after =
            (await db.customSelect('SELECT * FROM ${entry.key}').get())
                .map((row) => Map<String, dynamic>.from(row.data))
                .toList();
        expect(
          after,
          entry.value,
          reason: '${entry.key} rows must remain byte-for-byte unchanged',
        );
      }
      final character = await (db.select(
        db.characters,
      )..where((row) => row.charId.equals('roleplay-1'))).getSingle();
      expect(character.name, 'Imported character');
    },
  );
}
