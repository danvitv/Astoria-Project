import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_catalog_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

// Deliberately not backed by SQLite. Any decoding or DB mutation on this repo
// fails the test rather than crossing the worker boundary unnoticed.
class _Rows implements EmbeddingRepo {
  final List<EmbeddingRow> rows;
  Future<List<EmbeddingRow>> Function()? onRead;
  int reads = 0;
  _Rows(this.rows);

  @override
  Future<List<EmbeddingRow>> getBySourceType(String type) {
    expect(type, 'memory_entry');
    reads++;
    return onRead?.call() ?? Future.value(rows);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repo access: ${invocation.memberName}');
}

class _Books implements MemoryBookRepo {
  final MemoryBook book;
  Future<MemoryBook?> Function()? onRead;
  int reads = 0;
  _Books(this.book);

  @override
  Future<MemoryBook?> getBySessionId(String id) {
    expect(id, book.sessionId);
    reads++;
    return onRead?.call() ?? Future.value(book);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected book access: ${invocation.memberName}');
}

class _NoCatalog implements MemoryCatalogRepo {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected catalog access: ${invocation.memberName}');
}

class _Embedder extends EmbeddingService {
  final started = Completer<void>();
  final response = Completer<List<EmbeddingChunk>>();
  CancelToken? receivedToken;
  LlmCaptureContext? receivedCapture;
  int calls = 0;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) {
    calls++;
    receivedToken = cancelToken;
    receivedCapture = captureContext;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

EmbeddingRow _row(MemoryEntry entry) => EmbeddingRow(
  entryId: entry.id,
  sourceType: 'memory_entry',
  updatedAt: 0,
  vectorsBlob: vectorListToBytes(const [
    [1, 0],
  ]),
  textHash: sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'text': entry.content,
            'retrievalHints':
                MemoryEmbeddingService.extractMemoryRetrievalHints(entry),
          }),
        ),
      )
      .toString(),
  retrievalHintsJson: jsonEncode({
    'chunks': [
      {'index': 0, 'text': entry.content},
    ],
  }),
);

const _entry = MemoryEntry(
  id: 'a',
  content: 'An approved bridge scene with source evidence.',
  keys: ['bridge'],
  messageIds: ['m1'],
);
const _config = EmbeddingConfig(
  endpoint: 'https://synthetic.invalid/embeddings',
);
const _history = [ChatMessage(id: 'm1', role: 'user', content: 'the bridge')];
const _settings = MemoryGlobalSettings(vectorSearchEnabled: true);
const _vectors = [
  EmbeddingChunk(text: 'query', vector: [1, 0]),
];

late PromptWorker _worker;
SendPort _holdWorker(Object? input) {
  (input as SendPort).send('started');
  final watch = Stopwatch()..start();
  while (watch.elapsedMilliseconds < 100) {}
  return Isolate.current.controlPort;
}

MemoryInjectionService _injection(
  _Books books,
  _Rows rows,
  _Embedder embedder, {
  bool vectors = true,
}) => MemoryInjectionService(
  books,
  rows,
  _NoCatalog(),
  embedder,
  () => MemoryGlobalSettings(vectorSearchEnabled: vectors),
  promptWorker: _worker,
);

void main() {
  late Directory fixture;
  setUpAll(() async {
    final base = Directory('${Directory.systemTemp.path}/opencode');
    await base.create(recursive: true);
    fixture = await base.createTemp('memory-worker-test-');
    _worker = await PromptWorker.createForTesting(appSupportPath: fixture.path);
  });
  tearDownAll(() async {
    _worker.dispose();
    await fixture.delete();
  });

  test(
    'late selector/diagnostics job cannot publish for a cancelled consumer',
    () async {
      final started = ReceivePort();
      addTearDown(started.close);
      final block = _worker.runTokenized<SendPort>(
        _holdWorker,
        started.sendPort,
      );
      await started.first;
      final token = CancelToken();
      final books = _Books(
        const MemoryBook(id: 'book', sessionId: 's', entries: [_entry]),
      );
      final result = _injection(books, _Rows([]), _Embedder(), vectors: false)
          .buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            cancelToken: token,
          );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await block;
      final retired = await result;
      expect(retired.selection.allScores, isEmpty);
      expect(retired.diagnostics?.totalCandidates, 0);
    },
  );

  test(
    'source window is frozen before retrieval and worker queueing',
    () async {
      final read = Completer<MemoryBook?>();
      final books = _Books(
        const MemoryBook(id: 'book', sessionId: 's', entries: [_entry]),
      )..onRead = () => read.future;
      final visible = {'m1'};
      final pending = _injection(books, _Rows([]), _Embedder(), vectors: false)
          .buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            visibleMessageIds: visible,
          );
      visible.clear();
      read.complete(books.book);
      final result = await pending;
      expect(result.selection.entries, isEmpty);
      expect(result.selection.excludedBySourceWindow, 1);
      expect(
        result.diagnostics?.candidates.single.reason,
        'source_visible_in_prompt',
      );
    },
  );

  test('cancelled vector lookup exits before DB or embedding work', () async {
    final rows = _Rows([_row(_entry)]);
    final embedder = _Embedder();
    final token = CancelToken()..cancel();
    final result = await MemoryVectorSearcher(rows, embedder).search(
      [_entry],
      _history,
      'bridge',
      _config,
      _settings,
      cancelToken: token,
    );
    expect(result.scores, isEmpty);
    expect(rows.reads, 0);
    expect(embedder.calls, 0);
  });

  test('cancel after row await discards rows and never embeds', () async {
    final rows = _Rows([_row(_entry)]);
    final read = Completer<List<EmbeddingRow>>();
    rows.onRead = () => read.future;
    final embedder = _Embedder();
    final token = CancelToken();
    final future = MemoryVectorSearcher(rows, embedder).search(
      [_entry],
      _history,
      'bridge',
      _config,
      _settings,
      cancelToken: token,
    );
    token.cancel();
    read.complete(rows.rows);
    expect((await future).scores, isEmpty);
    expect(embedder.calls, 0);
  });

  for (final useCancelToken in [false, true]) {
    test(
      'embedding completion is fenced by ${useCancelToken ? 'CancelToken' : 'source/ownership abort'}',
      () async {
        final rows = _Rows([_row(_entry)]);
        final embedder = _Embedder();
        final token = CancelToken();
        var invalidated = false;
        final future = MemoryVectorSearcher(rows, embedder).search(
          [_entry],
          _history,
          'bridge',
          _config,
          _settings,
          cancelToken: token,
          shouldAbort: () => invalidated,
        );
        await embedder.started.future;
        expect(identical(embedder.receivedToken, token), isTrue);
        expect(embedder.receivedCapture?.stage, 'embedding.memory');
        if (useCancelToken) {
          token.cancel();
        } else {
          invalidated = true;
        }
        embedder.response.complete(_vectors);
        final result = await future;
        expect(result.scores, isEmpty);
        expect(result.chunksByEntryId, isEmpty);
      },
    );
  }

  test('a stale scoring-worker completion is discarded', () async {
    final embedder = _Embedder()..response.complete(_vectors);
    var checks = 0;
    // Initial, DB, preparation worker, pre-embedding, embedding, scoring worker.
    final result = await MemoryVectorSearcher(_Rows([_row(_entry)]), embedder)
        .search(
          [_entry],
          _history,
          'bridge',
          _config,
          _settings,
          shouldAbort: () => ++checks >= 6,
        );
    expect(embedder.calls, 1);
    expect(checks, 6);
    expect(result.scores, isEmpty);
  });

  test(
    'normal retrieval publishes prepared/scored results without repo decoding',
    () async {
      final embedder = _Embedder()..response.complete(_vectors);
      final result = await MemoryVectorSearcher(
        _Rows([_row(_entry)]),
        embedder,
      ).search([_entry], _history, 'bridge', _config, _settings);
      expect(result.scores, {'a': 1});
      expect(result.chunksByEntryId, {
        'a': [_entry.content],
      });
    },
  );

  test(
    'injection keeps active revision, source invalidation and current-source fences',
    () async {
      final entries = [
        _entry,
        _entry.copyWith(id: 'outside', messageIds: ['m2']),
        _entry.copyWith(id: 'manual', messageIds: []),
        _entry.copyWith(id: 'inactive', status: 'pending'),
        _entry.copyWith(id: 'ledger', source: 'studio_ledger'),
        _entry.copyWith(id: 'empty', content: ' '),
        _entry.copyWith(id: 'revision', activeRevisionId: 'missing'),
        _entry.copyWith(
          id: 'invalidated',
          sourceManifest: MemorySourceManifest(
            originSessionId: 's',
            messages: [],
            invalidated: true,
          ),
        ),
      ];
      final books = _Books(
        MemoryBook(id: 'book', sessionId: 's', entries: entries),
      );
      final result =
          await _injection(
            books,
            _Rows([]),
            _Embedder(),
            vectors: false,
          ).buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            allowedSourceMessageIds: {'m1'},
          );
      expect(result.selection.entries.map((e) => e.id), ['a']);
      expect(result.selection.allScores.map((s) => s.entry.id), ['a']);
      expect(result.diagnostics?.totalCandidates, 1);
    },
  );

  test(
    'source-window exclusions remain visible in diagnostics, not injection',
    () async {
      final books = _Books(
        const MemoryBook(id: 'book', sessionId: 's', entries: [_entry]),
      );
      final result =
          await _injection(
            books,
            _Rows([]),
            _Embedder(),
            vectors: false,
          ).buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            visibleMessageIds: {'m1'},
            allowedSourceMessageIds: {'m1'},
          );
      expect(result.selection.entries, isEmpty);
      expect(result.selection.excludedBySourceWindow, 1);
      expect(
        result.diagnostics?.candidates.single.reason,
        'source_visible_in_prompt',
      );
    },
  );

  test(
    'injection abort after vector await cannot select keyword candidates',
    () async {
      final books = _Books(
        const MemoryBook(id: 'book', sessionId: 's', entries: [_entry]),
      );
      final embedder = _Embedder();
      var aborted = false;
      final future = _injection(books, _Rows([_row(_entry)]), embedder)
          .buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            embeddingConfig: _config,
            shouldAbort: () => aborted,
          );
      await embedder.started.future;
      aborted = true;
      embedder.response.complete(_vectors);
      final result = await future;
      expect(result.selection.entries, isEmpty);
      expect(result.selection.allScores, isEmpty);
      expect(result.diagnostics?.totalCandidates, 0);
    },
  );

  test(
    'injection CancelToken is checked after book await, without shouldAbort',
    () async {
      final books = _Books(
        const MemoryBook(id: 'book', sessionId: 's', entries: [_entry]),
      );
      final read = Completer<MemoryBook?>();
      books.onRead = () => read.future;
      final token = CancelToken();
      final embedder = _Embedder();
      final future = _injection(books, _Rows([_row(_entry)]), embedder)
          .buildCandidatesWithDiagnostics(
            sessionId: 's',
            history: _history,
            currentText: 'bridge',
            embeddingConfig: _config,
            cancelToken: token,
          );
      token.cancel();
      read.complete(books.book);
      expect((await future).selection.entries, isEmpty);
      expect(embedder.calls, 0);
    },
  );
}
