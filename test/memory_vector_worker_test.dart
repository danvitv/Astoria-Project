import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory/memory_vector_searcher.dart';
import 'package:glaze_flutter/core/llm/memory_embedding_service.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

String _hash(MemoryEntry entry) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'text': entry.content,
          'retrievalHints': MemoryEmbeddingService.extractMemoryRetrievalHints(
            entry,
          ),
        }),
      ),
    )
    .toString();

MemoryVectorSnapshot _snapshot(
  MemoryEntry entry, {
  Uint8List? blob,
  String? hash,
  String? metadata,
}) => MemoryVectorSnapshot(
  id: entry.id,
  title: entry.title,
  content: entry.content,
  keys: entry.keys,
  storedHash: hash ?? _hash(entry),
  storedVectors:
      blob ??
      vectorListToBytes(const [
        [1, 0],
        [0, 1],
        [0.5, 0.5],
      ]),
  storedMetadata:
      metadata ??
      jsonEncode({
        'chunks': [
          {'index': 2, 'text': 'next'},
          {'index': 0, 'text': 'previous'},
          {'index': 1, 'text': 'best'},
        ],
      }),
);

void main() {
  const entry = MemoryEntry(
    id: 'a',
    title: 'A memory',
    content: 'Scene: the old bridge',
    keys: ['bridge'],
  );

  test(
    'immutable preparation worker matches synchronous hash/metadata decoding',
    () async {
      final snapshots = [_snapshot(entry)];
      final synchronous = prepareMemoryVectors(snapshots).single;
      final isolated = (await prepareMemoryVectorsInIsolate(snapshots)).single;
      expect(isolated.id, synchronous.id);
      expect(isolated.vectors, synchronous.vectors);
      expect(isolated.chunkTexts, ['previous', 'best', 'next']);
      expect(() => isolated.vectors.first[0] = 2, throwsUnsupportedError);
      expect(() => isolated.chunkTexts.clear(), throwsUnsupportedError);
    },
  );

  test(
    'text, title and key edits each invalidate the stored fingerprint',
    () async {
      final oldHash = _hash(entry);
      final snapshots = [
        _snapshot(
          entry.copyWith(id: 'text', content: 'changed'),
          hash: oldHash,
        ),
        _snapshot(
          entry.copyWith(id: 'title', title: 'changed'),
          hash: oldHash,
        ),
        _snapshot(
          entry.copyWith(id: 'keys', keys: ['changed']),
          hash: oldHash,
        ),
        _snapshot(entry),
      ];
      expect(
        (await prepareMemoryVectorsInIsolate(snapshots)).map((c) => c.id),
        ['a'],
      );
    },
  );

  test(
    'malformed vectors do not poison valid candidates; legacy JSON bytes survive',
    () async {
      final bytes = vectorListToBytes(const [
        [1, 0],
        [0, 1],
      ]);
      final malformed = Uint8List(16);
      ByteData.sublistView(malformed).setUint32(0, 2, Endian.host);
      ByteData.sublistView(malformed).setUint32(4, 1, Endian.host);
      final snapshots = [
        _snapshot(
          entry.copyWith(id: 'truncated'),
          blob: Uint8List.sublistView(bytes, 0, bytes.length - 1),
        ),
        _snapshot(entry.copyWith(id: 'header'), blob: malformed),
        _snapshot(
          entry.copyWith(id: 'bad_json'),
          blob: Uint8List.fromList(utf8.encode('[999]')),
        ),
        _snapshot(
          entry.copyWith(id: 'legacy'),
          blob: Uint8List.fromList(utf8.encode(jsonEncode(bytes.toList()))),
        ),
        _snapshot(entry),
      ];
      final candidates = await prepareMemoryVectorsInIsolate(snapshots);
      expect(candidates.map((c) => c.id), ['legacy', 'a']);
      expect(candidates.first.vectors, const [
        [1, 0],
        [0, 1],
      ]);
    },
  );

  test(
    'malformed/legacy hint metadata keeps vectors but does not invent chunk text',
    () {
      for (final metadata in ['{broken', '["old hint"]', '{"chunks":false}']) {
        expect(
          prepareMemoryVectors([
            _snapshot(entry, metadata: metadata),
          ]).single.chunkTexts,
          isEmpty,
        );
      }
      final prepared = prepareMemoryVectors([
        _snapshot(
          entry,
          metadata: jsonEncode({
            'chunks': [
              {'index': -1, 'text': 'bad'},
              {'index': 99, 'text': 'bad'},
              {'index': '0', 'text': 'bad'},
              {'index': 0, 'text': 1},
              'bad',
              {'index': 1, 'text': 'best'},
            ],
          }),
        ),
      ]).single;
      expect(prepared.chunkTexts, ['', 'best', '']);
    },
  );

  test(
    'scoring worker preserves multi-query ranking, threshold, cap and neighbors',
    () async {
      final candidates = [
        PreparedMemoryVectorCandidate(
          id: 'a',
          vectors: const [
            [0, -1],
            [0, 1],
            [-1, 0],
          ],
          chunkTexts: const ['previous', 'best', 'next'],
        ),
        PreparedMemoryVectorCandidate(
          id: 'b',
          vectors: const [
            [0.6, 0.8],
          ],
          chunkTexts: const ['runner up'],
        ),
        PreparedMemoryVectorCandidate(
          id: 'negative',
          vectors: const [
            [-1, -1],
          ],
          chunkTexts: const ['ignored'],
        ),
        PreparedMemoryVectorCandidate(
          id: 'wrong_dimension',
          vectors: const [
            [1],
          ],
          chunkTexts: const ['ignored'],
        ),
      ];
      final input = MemoryVectorScoringInput(
        candidates: candidates,
        queryVectors: const [
          [1, 0],
          [0, 1],
        ],
        threshold: 0.7,
        topK: 2,
      );
      final reference = findTopKMulti(
        const [
          VectorChunk(text: '', vector: [1, 0]),
          VectorChunk(text: '', vector: [0, 1]),
        ],
        [
          for (final c in candidates)
            VectorCandidate(
              id: c.id,
              vectors: [
                for (final v in c.vectors) VectorChunk(text: '', vector: v),
              ],
            ),
        ],
        candidates.length,
      ).where((r) => r.score >= 0.7).take(2);
      final result = await scoreMemoryVectorsInIsolate(input);
      expect(result.scores, {for (final r in reference) r.id: r.score});
      expect(result.chunksByEntryId['a'], ['best', 'previous', 'next']);
      expect(result.chunksByEntryId['b'], ['runner up']);
      expect(
        scoreMemoryVectors(
          MemoryVectorScoringInput(
            candidates: candidates,
            queryVectors: input.queryVectors,
            threshold: 0,
            topK: 1,
          ),
        ).scores.keys,
        ['a'],
      );
    },
  );

  test('worker snapshots cannot observe later mutable input changes', () async {
    final keys = ['bridge'];
    final blob = vectorListToBytes(const [
      [1, 0],
    ]);
    final snapshot = MemoryVectorSnapshot(
      id: entry.id,
      title: entry.title,
      content: entry.content,
      keys: keys,
      storedHash: _hash(entry),
      storedVectors: blob,
    );
    keys.clear();
    blob.fillRange(0, blob.length, 0);
    final prepared = await prepareMemoryVectorsInIsolate([snapshot]);
    expect(prepared.single.vectors, const [
      [1, 0],
    ]);
    final query = [1.0, 0.0];
    final input = MemoryVectorScoringInput(
      candidates: prepared,
      queryVectors: [query],
      threshold: 0.5,
      topK: 1,
    );
    query[0] = -1;
    expect((await scoreMemoryVectorsInIsolate(input)).scores[entry.id], 1);
  });
}
