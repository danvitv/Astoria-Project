import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/backup_export_repo.dart';

void main() {
  test('pages are byte-bounded and an oversized row stays intact', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db
        .into(db.characters)
        .insert(CharactersCompanion.insert(charId: 'c', name: 'Synthetic'));
    final texts = [
      'Ж' * 400000,
      'Ж' * 400000,
      'Ж' * 400000,
      'x' * (BackupExportRepo.pageBytes + 100),
      'Ж' * 400000,
    ];
    for (var i = 0; i < texts.length; i++) {
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 's$i',
              characterId: 'c',
              sessionIndex: i,
              messagesJson: texts[i],
            ),
          );
    }
    final pages = await BackupExportRepo(db).pages('chat_sessions').toList();
    expect(pages.map((page) => page.length), [2, 1, 1, 1]);
    final rows = pages.expand((page) => page).toList();
    expect(rows.map((row) => row['session_id']), [
      's0',
      's1',
      's2',
      's3',
      's4',
    ]);
    expect(rows.map((row) => row['messages_json']), texts);
    for (final page in pages.where((page) => page.length > 1)) {
      final bytes = page.fold<int>(
        0,
        (total, row) =>
            total +
            row.values.fold<int>(
              0,
              (sum, value) => sum + utf8.encode('$value').length,
            ),
      );
      expect(bytes, lessThanOrEqualTo(BackupExportRepo.pageBytes));
    }
  });
}
