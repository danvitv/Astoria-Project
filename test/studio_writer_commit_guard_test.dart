import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/llm/studio/studio_writer_checkpoint.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

const _targetId = 'assistant';
const _guidance = 'Keep the dialogue brief';
const _base = ChatSession(
  id: 'session',
  characterId: 'character',
  sessionIndex: 0,
  updatedAt: 10,
  sessionVars: {'retained': 'old'},
  messages: [
    ChatMessage(id: 'user', role: 'user', content: 'Original prompt'),
    ChatMessage(
      id: _targetId,
      role: 'assistant',
      content: 'Original reply',
      swipes: ['Original reply'],
      guidanceText: _guidance,
      guidanceType: 'SWIPE',
    ),
  ],
);

ChatSession _result() => _base.copyWith(
  updatedAt: 20,
  sessionVars: const {'retained': 'new', 'generation': 'added'},
  messages: [
    _base.messages.first,
    _base.messages.last.copyWith(
      content: 'New Writer reply',
      swipes: const ['New Writer reply'],
    ),
  ],
);

String _writerSource(ChatSession session) => StudioWriterCheckpoint.sourceFor(
  session.copyWith(
    messages: session.messages.takeWhile((m) => m.id != _targetId).toList(),
  ),
  _guidance,
);

void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
    await repo.put(_base);
  });
  tearDown(() => db.close());

  test(
    'an initially false guard skips beforeWrite and writes nothing',
    () async {
      var guardCalled = false;
      var beforeWriteCalled = false;
      final result = await repo.commitGenerationResult(
        baseSession: _base,
        generatedSession: _result(),
        regenTargetId: _targetId,
        canCommit: (latest) {
          guardCalled = true;
          expect(latest, _base);
          return false;
        },
        beforeWrite: (_, _) async {
          beforeWriteCalled = true;
        },
      );

      expect(guardCalled, isTrue);
      expect(beforeWriteCalled, isFalse);
      expect(result, isNull);
      expect(await repo.getById(_base.id), _base);
    },
  );

  test('retiring during beforeWrite rolls back its nested write', () async {
    var live = true;
    final guardDecisions = <bool>[];
    final result = await repo.commitGenerationResult(
      baseSession: _base,
      generatedSession: _result(),
      regenTargetId: _targetId,
      canCommit: (_) {
        guardDecisions.add(live);
        return live;
      },
      beforeWrite: (before, after) async {
        expect(after.messages.last.content, 'New Writer reply');
        await repo.updateSessionVarsJson(before.id, (vars) {
          vars['retained'] = 'temporary';
          vars['beforeWrite'] = 'temporary';
          return vars;
        });
        final insideTransaction = await repo.getById(before.id);
        expect(insideTransaction?.sessionVars, {
          'retained': 'temporary',
          'beforeWrite': 'temporary',
        });
        live = false;
      },
    );

    expect(guardDecisions, [true, false]);
    expect(result, isNull);
    expect(await repo.getById(_base.id), _base);
  });

  test(
    'a history edit invalidates the Writer source, not the target',
    () async {
      final source = _writerSource(_base);
      final edited = (await repo.mutateMessage(
        sessionId: _base.id,
        messageId: _base.messages.first.id,
        updatedAt: 15,
        mutate: (message) => message.copyWith(content: 'Edited prompt'),
      ))!;
      expect(edited.messages.last, _base.messages.last);
      expect(_writerSource(edited), isNot(source));

      final guardSources = <String>[];
      final result = await repo.commitGenerationResult(
        baseSession: _base,
        generatedSession: _result(),
        regenTargetId: _targetId,
        canCommit: (latest) {
          final currentSource = _writerSource(latest);
          guardSources.add(currentSource);
          return currentSource == source;
        },
      );

      expect(guardSources, [_writerSource(edited)]);
      expect(result, isNull);
      expect(await repo.getById(_base.id), edited);
    },
  );
}
