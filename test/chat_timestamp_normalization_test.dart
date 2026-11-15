import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/utils/time_helpers.dart';

void main() {
  test('timestamp helpers preserve seconds and normalize milliseconds', () {
    expect(normalizeTimestampSeconds(1787088360), 1787088360);
    expect(normalizeTimestampSeconds(1787088360372), 1787088360);
    expect(timestampSecondsToMilliseconds(1787088360), 1787088360000);
    expect(timestampSecondsToMilliseconds(1787088360372), 1787088360000);
    expect(normalizeTimestampMilliseconds(1787088360), 1787088360000);
    expect(normalizeTimestampMilliseconds(1787088360372), 1787088360372);
  });

  test('ChatSession cloud JSON normalizes legacy milliseconds', () {
    final session = ChatSession.fromJson({
      'id': 'legacy',
      'characterId': 'character',
      'sessionIndex': 0,
      'updatedAt': 1787088360372,
    });

    expect(session.updatedAt, 1787088360);
  });

  test('ChatRepo normalizes timestamps before durable writes', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ChatRepo(db);

    await repo.put(
      const ChatSession(
        id: 'legacy',
        characterId: 'character',
        sessionIndex: 0,
        updatedAt: 1787088360372,
      ),
    );

    final row = await (db.select(
      db.chatSessions,
    )..where((table) => table.sessionId.equals('legacy'))).getSingle();
    expect(row.updatedAt, 1787088360);
    expect((await repo.getAllSessionMetadata()).single.updatedAt, 1787088360);
  });
}
