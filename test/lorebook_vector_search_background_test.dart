import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_types.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_text.dart';
import 'package:glaze_flutter/core/llm/lorebook_vector_search.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

const _config = EmbeddingConfig(endpoint: 'test', model: 'test');
const _settings = LorebookGlobalSettings(
  searchType: 'vector',
  vectorThreshold: 0,
  fallbackThreshold: 0,
);
const _entry = LorebookEntry(
  id: 'entry',
  content: 'Indexed body',
  vectorSearch: true,
);
const _book = Lorebook(id: 'book', name: 'Book', entries: [_entry]);

class _FixtureRepo extends EmbeddingRepo {
  final List<EmbeddingRow> rows;
  int reads = 0;
  Set<String> requestedIds = {};
  Completer<List<EmbeddingRow>>? readGate;
  void Function()? afterRead;

  _FixtureRepo(super.db, this.rows);

  @override
  Future<List<EmbeddingRow>> getBySourceIds(
    String sourceType,
    Iterable<String> sourceIds,
  ) {
    reads++;
    requestedIds = sourceIds.toSet();
    afterRead?.call();
    return readGate?.future ??
        Future.value([
          for (final row in rows)
            if (row.sourceType == sourceType &&
                requestedIds.contains(row.sourceId))
              row,
        ]);
  }

  @override
  Future<List<EmbeddingRow>> getBySource(String sourceType, String sourceId) =>
      Future.value([
        for (final row in rows)
          if (row.sourceType == sourceType && row.sourceId == sourceId) row,
      ]);

  @override
  List<List<double>>? decodeVectors(EmbeddingRow row) =>
      throw StateError('Candidate decoding must not call the repository');

  @override
  List<String>? decodeHints(EmbeddingRow row) =>
      throw StateError('Hint decoding must not call the repository');

  @override
  Map<String, dynamic>? decodeMetadata(EmbeddingRow row) =>
      throw StateError('Metadata decoding must not call the repository');
}

class _FixtureEmbeddings extends EmbeddingService {
  final queries = <String>[];
  final callerPorts = <SendPort>[];
  final contexts = <LlmCaptureContext?>[];
  final tokens = <CancelToken?>[];
  final started = Completer<void>();
  Completer<void>? release;
  void Function()? afterRequest;
  Map<String, List<List<double>>> queryVectors = {};

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async {
    queries.addAll(texts);
    callerPorts.add(Isolate.current.controlPort);
    contexts.add(captureContext);
    tokens.add(cancelToken);
    if (!started.isCompleted) started.complete();
    if (release != null) await release!.future;
    afterRequest?.call();
    return [
      for (final text in texts)
        for (final vector
            in queryVectors[text] ??
                const [
                  [1.0, 0.0],
                ])
          EmbeddingChunk(text: text, vector: vector),
    ];
  }
}

EmbeddingRow _row(
  LorebookEntry entry, {
  String lorebookId = 'book',
  String? sessionId,
  String? target,
  String? signature,
  List<List<double>> vectors = const [
    [1, 0],
  ],
  List<String> hints = const [],
  Uint8List? blob,
  String? hash,
  String? metadataJson,
}) => EmbeddingRow(
  entryId: sessionId == null
      ? '${lorebookId}_${entry.id}'
      : '$sessionId:$lorebookId:${entry.id}',
  sourceType: sessionId == null ? 'lorebook_entry' : 'session_lorebook_entry',
  sourceId: sessionId ?? lorebookId,
  vectorsBlob: blob ?? vectorListToBytes(vectors),
  textHash:
      hash ??
      computeHash(
        LorebookEmbeddingService.buildEmbeddingFingerprint(
          entry,
          lorebookEmbeddingText(entry, target),
        ),
      ),
  retrievalHintsJson:
      metadataJson ??
      jsonEncode({
        'embeddingSignature': signature ?? embeddingModelSignature(_config),
        'hints': hints,
      }),
  updatedAt: 0,
);

_FixtureRepo _repo(List<EmbeddingRow> rows) {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return _FixtureRepo(db, rows);
}

void main() {
  test('keeps hybrid caps, raw fallback scores and per-book limits', () async {
    const boosted = LorebookEntry(
      id: 'boosted',
      content: 'Body',
      comment: 'Harbor',
      keys: ['tower', 'ancient', 'stone', 'Harbor'],
      vectorSearch: true,
    );
    const plain = LorebookEntry(
      id: 'plain',
      content: 'Body',
      vectorSearch: true,
    );
    const negative = LorebookEntry(
      id: 'negative',
      content: 'Body',
      comment: 'Harbor',
      vectorSearch: true,
    );
    const keyless = LorebookEntry(
      id: 'keyless',
      content: 'Body',
      comment: 'Harbor',
    );
    const secondKeyless = LorebookEntry(id: 'second-keyless', content: 'Body');
    const belowFallback = LorebookEntry(id: 'below-fallback', content: 'Body');
    final repo = _repo([
      _row(
        boosted,
        vectors: const [
          [0.6, 0.8],
        ],
        hints: ['ancient stone tower harbor'],
      ),
      _row(
        plain,
        vectors: const [
          [0.8, 0.6],
        ],
      ),
      _row(
        negative,
        vectors: const [
          [-1, 0],
        ],
      ),
      _row(
        keyless,
        vectors: [
          [0.4, sqrt(0.84)],
        ],
      ),
      _row(
        secondKeyless,
        vectors: [
          [0.35, sqrt(1 - 0.35 * 0.35)],
        ],
      ),
      _row(
        belowFallback,
        vectors: [
          [0.2, sqrt(0.96)],
        ],
      ),
    ]);
    final embeddings = _FixtureEmbeddings();
    final token = CancelToken();
    final callerPort = Isolate.current.controlPort;
    final results = await LorebookVectorSearch(repo, embeddings).search(
      const [],
      'Harbor tower ancient stone',
      const [
        Lorebook(
          id: 'book',
          name: 'Book',
          entries: [
            boosted,
            plain,
            negative,
            keyless,
            secondKeyless,
            belowFallback,
          ],
          settings: LorebookSettings(vectorThreshold: 0.7, vectorTopK: 2),
        ),
      ],
      const LorebookGlobalSettings(
        searchType: 'vector',
        vectorThreshold: 0.9,
        vectorTopK: 1,
        fallbackThreshold: 0.3,
        fallbackTopK: 1,
      ),
      _config,
      overrideTopK: 1,
      chatId: 'session',
      cancelToken: token,
    );
    expect(results.map((r) => r.entryId), ['boosted', 'plain', 'keyless']);
    expect(results[0].score, closeTo(1, 1e-12));
    expect(results[1].score, closeTo(0.8, 1e-12));
    expect(results[2].score, closeTo(0.4, 1e-12));
    expect(embeddings.queries, ['Harbor tower ancient stone']);
    expect(embeddings.callerPorts, [callerPort]);
    expect(embeddings.tokens.single, same(token));
    expect(embeddings.contexts.single?.stage, 'embedding.lorebook');
    expect(embeddings.contexts.single?.sessionId, 'session');
  });

  test(
    'uses max multi-chunk score across focused and staggered queries',
    () async {
      const first = LorebookEntry(
        id: 'first',
        content: 'Body',
        vectorSearch: true,
      );
      const second = LorebookEntry(
        id: 'second',
        content: 'Body',
        vectorSearch: true,
      );
      final repo = _repo([
        _row(
          first,
          vectors: const [
            [0, 1],
            [1, 0],
          ],
        ),
        _row(
          second,
          vectors: const [
            [0.6, 0.8],
          ],
        ),
      ]);
      final embeddings = _FixtureEmbeddings()
        ..queryVectors = {
          'now': [
            [0.8, 0.6],
            [0.7, sqrt(0.51)],
          ],
          'now\nanswer': [
            [0, 1],
          ],
        };
      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [ChatMessageForSearch(role: 'assistant', content: 'answer')],
        'now',
        const [
          Lorebook(id: 'book', name: 'Book', entries: [first, second]),
        ],
        _settings,
        _config,
      );
      final expected = findTopKMulti(
        [
          for (final chunks in embeddings.queryVectors.values)
            for (final vector in chunks) VectorChunk(text: '', vector: vector),
        ],
        [
          VectorCandidate(
            id: 'first',
            vectors: const [
              VectorChunk(text: '', vector: [0, 1]),
              VectorChunk(text: '', vector: [1, 0]),
            ],
          ),
          VectorCandidate(id: 'second', vector: const [0.6, 0.8]),
        ],
        2,
      );
      expect(embeddings.queries, ['now', 'now\nanswer']);
      expect(results.map((r) => r.entryId), expected.map((r) => r.id));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].score, closeTo(expected[i].score, 1e-12));
      }
    },
  );

  test(
    'preserves activation, character filters and vectorize-all pools',
    () async {
      const included = LorebookEntry(
        id: 'included',
        content: 'Body',
        keys: ['key'],
        characterFilter: LorebookCharacterFilter(names: ['Alice']),
      );
      const excluded = LorebookEntry(
        id: 'excluded',
        content: 'Body',
        vectorSearch: true,
        characterFilter: LorebookCharacterFilter(
          names: ['Alice'],
          isExclude: true,
        ),
      );
      const unmatched = LorebookEntry(
        id: 'unmatched',
        content: 'Body',
        vectorSearch: true,
        characterFilter: LorebookCharacterFilter(names: ['Bob']),
      );
      const secondary = LorebookEntry(
        id: 'secondary',
        content: 'Body',
        secondaryKeys: ['key'],
      );
      const optedOut = LorebookEntry(
        id: 'opted-out',
        content: 'Body',
        excludeFromVectorization: true,
      );
      const disabled = LorebookEntry(
        id: 'disabled',
        content: 'Body',
        enabled: false,
      );
      const constant = LorebookEntry(
        id: 'constant',
        content: 'Body',
        constant: true,
      );
      final repo = _repo([
        for (final entry in [
          included,
          excluded,
          unmatched,
          optedOut,
          disabled,
          constant,
        ])
          _row(entry, lorebookId: 'linked'),
        _row(secondary),
        _row(_entry, lorebookId: 'inactive'),
        _row(_entry, lorebookId: 'vector-disabled'),
      ]);
      final results = await LorebookVectorSearch(repo, _FixtureEmbeddings())
          .search(
            const [],
            'query',
            const [
              Lorebook(
                id: 'linked',
                name: 'Linked',
                enabled: false,
                entries: [
                  included,
                  excluded,
                  unmatched,
                  optedOut,
                  disabled,
                  constant,
                ],
                settings: LorebookSettings(vectorizeAllEntries: true),
              ),
              Lorebook(id: 'book', name: 'Book', entries: [secondary]),
              Lorebook(
                id: 'inactive',
                name: 'Inactive',
                enabled: false,
                entries: [_entry],
              ),
              Lorebook(
                id: 'vector-disabled',
                name: 'Disabled',
                entries: [_entry],
                settings: LorebookSettings(vectorSearchEnabled: false),
              ),
            ],
            _settings,
            _config,
            character: const Character(
              id: 'variant',
              name: 'Alice Smith',
              variantGroupId: 'group',
            ),
            activations: const LorebookActivations(
              character: {
                'group': ['linked'],
              },
            ),
          );
      expect(results.single.entryId, 'included');
      expect(results.single.lorebookId, 'linked');
      expect(repo.requestedIds, {'linked'});
    },
  );

  test(
    'keeps target fingerprints, hints and overlay signature fences',
    () async {
      const valid = LorebookEntry(
        id: 'valid',
        content: 'Body',
        comment: 'Title',
        vectorSearch: true,
      );
      const staleHints = LorebookEntry(
        id: 'stale-hints',
        content: 'Body',
        keys: ['new'],
        vectorSearch: true,
      );
      const overlay = LorebookEntry(
        id: 'overlay',
        content: 'Session body',
        vectorSearch: true,
      );
      const missingOverlay = LorebookEntry(
        id: 'missing-overlay',
        content: 'Body',
        vectorSearch: true,
      );
      const staleSignature = LorebookEntry(
        id: 'stale-signature',
        content: 'Body',
        vectorSearch: true,
      );
      final repo = _repo([
        _row(
          valid,
          target: 'comment',
          signature: 'https://old|test|chunks:8192',
        ),
        _row(
          staleHints,
          hash: computeHash(
            LorebookEmbeddingService.buildEmbeddingFingerprint(
              staleHints.copyWith(keys: ['old']),
              staleHints.content,
            ),
          ),
        ),
        _row(overlay), // Not a substitute for the session's vector.
        _row(overlay, sessionId: 'session', signature: 'other|chunks:8192'),
        _row(missingOverlay),
        _row(staleSignature, signature: 'test|chunks:1024'),
      ]);
      final embeddings = _FixtureEmbeddings();
      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [],
        'query',
        const [
          Lorebook(
            id: 'book',
            name: 'Book',
            entries: [
              valid,
              staleHints,
              overlay,
              missingOverlay,
              staleSignature,
            ],
            settings: LorebookSettings(embeddingTarget: 'comment'),
          ),
        ],
        _settings,
        _config,
        chatId: 'session',
        sessionOverlayTargets: const {
          (lorebookId: 'book', entryId: 'overlay'),
          (lorebookId: 'book', entryId: 'missing-overlay'),
        },
      );
      expect(results.single.entryId, 'valid');
      expect(embeddings.queries, ['query']);
    },
  );

  test(
    'repairs legacy TEXT blobs and rejects malformed vector payloads',
    () async {
      const valid = LorebookEntry(
        id: 'legacy',
        content: 'Body',
        vectorSearch: true,
      );
      const corrupt = LorebookEntry(
        id: 'corrupt',
        content: 'Body',
        vectorSearch: true,
      );
      const trailing = LorebookEntry(
        id: 'trailing',
        content: 'Body',
        vectorSearch: true,
      );
      const badJson = LorebookEntry(
        id: 'bad-json',
        content: 'Body',
        vectorSearch: true,
      );
      const badMetadata = LorebookEntry(
        id: 'bad-metadata',
        content: 'Body',
        vectorSearch: true,
      );
      final bytes = vectorListToBytes(const [
        [1, 0],
      ]);
      final repo = _repo([
        _row(
          valid,
          blob: Uint8List.fromList(utf8.encode(jsonEncode(bytes.toList()))),
        ),
        _row(corrupt, blob: Uint8List.fromList([255, 255, 255, 255])),
        _row(trailing, blob: Uint8List.fromList([...bytes, 0])),
        _row(badJson, blob: Uint8List.fromList(utf8.encode('[999]'))),
        _row(badMetadata, metadataJson: '{invalid'),
      ]);
      final results = await LorebookVectorSearch(repo, _FixtureEmbeddings())
          .search(
            const [],
            'query',
            const [
              Lorebook(
                id: 'book',
                name: 'Book',
                entries: [valid, corrupt, trailing, badJson, badMetadata],
              ),
            ],
            _settings,
            _config,
          );
      expect(results.single.entryId, 'legacy');
    },
  );

  test('pre-cancellation avoids reads and embedding requests', () async {
    final repo = _repo([_row(_entry)]);
    final embeddings = _FixtureEmbeddings();
    final token = CancelToken()..cancel();
    final results = await LorebookVectorSearch(repo, embeddings).search(
      const [],
      'query',
      const [_book],
      _settings,
      _config,
      cancelToken: token,
    );
    expect(results, isEmpty);
    expect(repo.reads, 0);
    expect(embeddings.queries, isEmpty);
  });

  test(
    'cancellation while rows are pending stops before preparation',
    () async {
      final rows = [_row(_entry)];
      final repo = _repo(rows)..readGate = Completer<List<EmbeddingRow>>();
      final embeddings = _FixtureEmbeddings();
      final token = CancelToken();
      final pending = LorebookVectorSearch(repo, embeddings).search(
        const [],
        'query',
        const [_book],
        _settings,
        _config,
        cancelToken: token,
      );
      token.cancel();
      repo.readGate!.complete(rows);
      expect(await pending, isEmpty);
      expect(embeddings.queries, isEmpty);
    },
  );

  test(
    'cancellation event during candidate worker discards its result',
    () async {
      final token = CancelToken();
      // Reads settle in microtasks; this queued event runs after the worker is
      // dispatched and before its result can return to the caller event loop.
      final repo = _repo([_row(_entry)])
        ..afterRead = () => Timer.run(token.cancel);
      final embeddings = _FixtureEmbeddings();
      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [],
        'query',
        const [_book],
        _settings,
        _config,
        cancelToken: token,
      );
      expect(token.isCancelled, isTrue);
      expect(results, isEmpty);
      expect(embeddings.queries, isEmpty);
    },
  );

  test('cancelled embedding completion cannot publish scores', () async {
    final repo = _repo([_row(_entry)]);
    final embeddings = _FixtureEmbeddings()..release = Completer<void>();
    final token = CancelToken();
    final pending = LorebookVectorSearch(repo, embeddings).search(
      const [],
      'query',
      const [_book],
      _settings,
      _config,
      cancelToken: token,
    );
    await embeddings.started.future;
    token.cancel();
    embeddings.release!.complete();
    expect(await pending, isEmpty);
    expect(embeddings.queries, ['query']);
  });

  test(
    'cancellation during scoring suppresses results and staggered request',
    () async {
      final repo = _repo([_row(_entry)]);
      final token = CancelToken();
      final embeddings = _FixtureEmbeddings()
        ..afterRequest = () => Timer.run(token.cancel);
      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [ChatMessageForSearch(role: 'assistant', content: 'answer')],
        'query',
        const [_book],
        _settings,
        _config,
        cancelToken: token,
      );
      expect(token.isCancelled, isTrue);
      expect(results, isEmpty);
      expect(embeddings.queries, ['query']);
    },
  );
}
