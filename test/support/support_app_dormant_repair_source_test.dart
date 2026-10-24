import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'support_tool_loop_fixture.dart';

/// Auxiliary owning-source projection evidence, not a replacement model loop.
/// Production model/root/queue/capability evidence lives in the NEW effect files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  toolLoopTest(
    'native dormant source projection rejects malformed and oversized originals rather than tolerant idle defaults',
    (f) async {
      f.isolation.extraAllowed.add(chatRepoProvider);
      f.isolation.extraAllowed.add(characterRepoProvider);
      final db = f.native.db, repo = f.container.read(chatRepoProvider);
      const session = 'dormant-source_0';
      await f.container
          .read(characterRepoProvider)
          .put(const Character(id: 'dormant-source', name: 'Synthetic'));
      await repo.put(
        const ChatSession(
          id: session,
          characterId: 'dormant-source',
          sessionIndex: 0,
        ),
      );
      bool current() => f.native.rootCurrent && f.native.native.isCurrent;
      expect(
        await repo.readNativeMaintenanceSource(session, current),
        isNotNull,
      );
      await (db.update(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(session))).write(
        const ChatSessionsCompanion(sessionVarsJson: Value('{malformed')),
      );
      expect(await repo.readNativeMaintenanceSource(session, current), null);
      await (db.update(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(session))).write(
        ChatSessionsCompanion(
          sessionVarsJson: const Value(null),
          draft: Value(List.filled(65537, 'x').join()),
        ),
      );
      expect(await repo.readNativeMaintenanceSource(session, current), null);
      expect(f.wire, isEmpty);
    },
  );

  toolLoopTest(
    'native dormant source projection denies the SAME closed original AppDatabase',
    (f) async {
      f.isolation.extraAllowed.add(chatRepoProvider);
      f.isolation.extraAllowed.add(characterRepoProvider);
      final repo = f.container.read(chatRepoProvider);
      await f.container
          .read(characterRepoProvider)
          .put(const Character(id: 'closed-source', name: 'Synthetic'));
      await repo.put(
        const ChatSession(
          id: 'closed-source_0',
          characterId: 'closed-source',
          sessionIndex: 0,
        ),
      );
      bool current() => f.native.rootCurrent && f.native.native.isCurrent;
      expect(
        await repo.readNativeMaintenanceSource('closed-source_0', current),
        isNotNull,
      );
      await f.native.db.close();
      expect(
        await repo.readNativeMaintenanceSource('closed-source_0', current),
        null,
      );
      expect(f.wire, isEmpty);
    },
  );
}
