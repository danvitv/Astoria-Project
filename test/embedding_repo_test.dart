import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';

void main() {
  late AppDatabase db;
  late EmbeddingRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = EmbeddingRepo(db);
  });

  tearDown(() => db.close());

  test('reads vectors restored as JSON byte arrays in a TEXT column', () async {
    final encoded = vectorListToBytes(const [
      [0.5, -0.25],
    ]);
    expect(bytesToVectorList(encoded), [
      const [0.5, -0.25],
    ]);
    await db.customStatement(
      'INSERT INTO embeddings (entry_id, source_type, source_id, vectors_blob) '
      'VALUES (?, ?, ?, ?)',
      ['legacy', 'lorebook_entry', 'book', jsonEncode(encoded)],
    );

    final row = await repo.getByEntryId('legacy');
    expect(row, isNotNull);
    expect(row!.vectorsBlob?.take(4).toList(), [91, 49, 44, 48]);
    expect(vectorBytesFromJson(utf8.decode(row.vectorsBlob!)), encoded);
    expect(repo.decodeVectors(row), [
      const [0.5, -0.25],
    ]);
  });

  test('rejects invalid vector headers before allocating vectors', () {
    expect(
      bytesToVectorList(Uint8List.fromList([255, 255, 255, 255, 255])),
      isEmpty,
    );
    expect(
      bytesToVectorList(Uint8List.fromList([1, 0, 0, 0, 255, 255, 255, 255])),
      isEmpty,
    );
    expect(
      bytesToVectorList(Uint8List.fromList(utf8.encode('[5,0,0,0]'))),
      isEmpty,
    );
  });

  test('getBySource applies source type and source id predicates', () async {
    for (final row in [
      ('chat-s1', 'chat_message', 's1'),
      ('chat-s2', 'chat_message', 's2'),
      ('memory-s1', 'memory_entry', 's1'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    final rows = await repo.getBySource('chat_message', 's1');

    expect(rows.map((row) => row.entryId), ['chat-s1']);
  });

  test('getBySourceIds applies source type and source id predicates', () async {
    for (final row in [
      ('one_shared', 'lorebook_entry', 'one'),
      ('two_shared', 'lorebook_entry', 'two'),
      ('three_shared', 'lorebook_entry', 'three'),
      ('memory-one', 'memory_entry', 'one'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    final rows = await repo.getBySourceIds('lorebook_entry', ['one', 'two']);

    expect(rows.map((row) => row.entryId).toSet(), {
      'one_shared',
      'two_shared',
    });
    expect(await repo.getBySourceIds('lorebook_entry', const []), isEmpty);
  });

  test('bulk entry deletion is scoped to source type and source id', () async {
    for (final row in [
      ('chat-s1-stale', 'chat_message', 's1'),
      ('chat-s1-keep', 'chat_message', 's1'),
      ('chat-s2-stale', 'chat_message', 's2'),
      ('memory-s1-stale', 'memory_entry', 's1'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    await repo.deleteBySourceAndEntryIds('chat_message', 's1', [
      'chat-s1-stale',
      'chat-s2-stale',
      'memory-s1-stale',
    ]);

    expect(await repo.getByEntryId('chat-s1-stale'), isNull);
    expect(await repo.getByEntryId('chat-s1-keep'), isNotNull);
    expect(await repo.getByEntryId('chat-s2-stale'), isNotNull);
    expect(await repo.getByEntryId('memory-s1-stale'), isNotNull);
  });

  test('composite source query uses the composite index', () async {
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT * FROM embeddings '
          'WHERE source_type = ? AND source_id = ?',
          variables: [
            Variable.withString('chat_message'),
            Variable.withString('s1'),
          ],
        )
        .get();

    expect(
      plan.map((row) => row.read<String>('detail')).join('\n'),
      contains('idx_embeddings_source_type_id'),
    );
  });

  test(
    'message invalidation preserves unrelated sources and retires legacy groups',
    () async {
      for (final source in [
        ('keep', 'chat_message', 's1', ['old-1', 'old-2']),
        ('changed', 'chat_message', 's1', ['old-2', 'removed']),
        ('legacy', 'chat_message', 's1', <String>[]),
        ('other-session', 'chat_message', 's2', ['removed']),
        ('memory', 'memory_entry', 's1', ['removed']),
      ]) {
        await repo.putEmbeddingVector(
          entryId: source.$1,
          sourceType: source.$2,
          sourceId: source.$3,
          vectors: const [
            [1, 0],
          ],
          textHash: source.$1,
          retrievalMetadata: {'messageIds': source.$4},
        );
      }
      final before = await repo.getAll();
      await repo.invalidateChatMessageGroupsForMessages('s1', const {});
      expect(await repo.getAll(), before);
      await repo.invalidateChatMessageGroupsForMessages('s1', {'removed'});
      expect((await repo.getAll()).map((row) => row.entryId).toSet(), {
        'keep',
        'other-session',
        'memory',
      });
    },
  );
}
