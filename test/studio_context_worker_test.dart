import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_formatter.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_message_chunk.dart';
import 'package:glaze_flutter/core/llm/prompt/runtime_prompt_block.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/llm/studio_regex_applicator.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

// These are top-level tear-offs: no test state, service or CancelToken capture.
Map<String, Object?> _tokenProbe(Object? input) => {
  'ready': o200kBaseLoaded,
  'tokens': estimateTokens(input as String),
  'isolate': Isolate.current.controlPort,
  'error': 'a legitimate data key, not a worker error',
};

SendPort _busyJob(Object? input) {
  (input as SendPort).send('started');
  final watch = Stopwatch()..start();
  while (watch.elapsedMilliseconds < 200) {}
  return Isolate.current.controlPort;
}

Object? _echo(Object? input) => input;
String _echoString(Object? input) => input as String;

Object? _throwingJob(Object? input) => throw StateError('job failed');

Map<String, Object?> _contextValue(StudioContext context) => {
  'slots': {
    for (final slot in StudioContextSlot.values)
      slot.name: context.messagesFor(slot).map((m) => m.toJson()).toList(),
  },
  'history': context.history.map((m) => m.toJson()).toList(),
  'continue': context.continueInstruction,
  'session': context.sessionVars,
  'global': context.globalVars,
  'memory': context.diagnostics.memoryCoverage,
  'triggeredLore': context.diagnostics.triggeredLorebooks
      .map((e) => e.toJson())
      .toList(),
  'triggeredMemory': context.diagnostics.triggeredMemories
      .map((e) => e.toJson())
      .toList(),
  'vectorTokens': context.diagnostics.vectorLoreTokens,
  'visible': context.diagnostics.visibleMessageIds,
  'ledgerIdentity': context.diagnostics.ledgerInjectionIdentity,
  'manifest': context.diagnostics.exactLorebookManifest?.toJson(),
  'reasoningStart': context.macroContext.reasoningStart,
  'reasoningEnd': context.macroContext.reasoningEnd,
};

GenerationContextInputs _inputs({
  List<ChatMessage>? history,
  ApiConfig? apiConfig,
}) => GenerationContextInputs(
  character: const Character(
    id: 'cat',
    name: 'Кот',
    description: 'A black cat',
    personality: 'Calm',
    scenario: 'At home',
    mesExample: 'Кот: Привет',
  ),
  history:
      history ??
      const [
        ChatMessage(id: 'source', role: 'assistant', content: 'Key: old fact'),
        ChatMessage(
          id: 'current',
          role: 'assistant',
          content: '_{{char}}_ waits 🐈‍⬛',
          reasoning: 'Selected reasoning',
          swipeId: 2,
          imagePath: 'first.png',
          extraImagePaths: ['second.png'],
        ),
        ChatMessage(
          id: 'hidden',
          role: 'user',
          content: 'Hidden',
          isHidden: true,
        ),
        ChatMessage(
          id: 'typing',
          role: 'assistant',
          content: '',
          isTyping: true,
        ),
      ],
  sessionId: 'session',
  apiConfig:
      apiConfig ?? const ApiConfig(id: 'api', reasoningTagStart: '<api-think>'),
  sessionVars: const {'place': 'home'},
  globalVars: const {'weather': 'rain'},
  summaryContent: 'A short summary',
  summaryPrefix: 'Summary: ',
  continueInstruction: 'Continue the reply',
  memorySelection: const MemorySelection(
    entries: [
      MemoryEntry(
        id: 'memory',
        title: 'Fact',
        content: 'Key memory fact',
        messageIds: ['source'],
      ),
    ],
    allScores: [
      MemoryCandidateScore(
        entry: MemoryEntry(
          id: 'memory',
          title: 'Fact',
          content: 'Key memory fact',
          messageIds: ['source'],
        ),
        score: 1,
        matchedKeys: ['Key'],
      ),
    ],
    entryCap: 1,
  ),
  lorebooks: const [
    Lorebook(
      id: 'book',
      name: 'World',
      entries: [
        LorebookEntry(
          id: 'keyword',
          lorebookId: 'book',
          lorebookName: 'World',
          keys: ['Key'],
          content: 'Lore for {{char}}',
          position: 'lorebooksMacro',
        ),
        LorebookEntry(
          id: 'vector',
          lorebookId: 'book',
          lorebookName: 'World',
          content: 'Vector lore',
          vectorSearch: true,
          useKeywordSearch: false,
        ),
      ],
    ),
  ],
  vectorEntries: const [
    LorebookEntry(
      id: 'vector',
      lorebookId: 'book',
      lorebookName: 'World',
      content: 'Vector lore',
      vectorSearch: true,
      useKeywordSearch: false,
    ),
  ],
  runtimePromptBlocks: const [
    RuntimePromptBlock(
      id: 'runtime',
      content: 'Now {{char}} at {{gametime}}',
      role: 'user',
      depth: 2,
    ),
  ],
  gameTime: '10:00',
  gameDate: '08.09.0755',
  gameDay: '0',
  effectiveCanonProjection: const EffectiveCanonPromptProjection(
    facts: [],
    trackers: [
      Tracker(
        sessionId: 'session',
        name: 'scene.immediate_thread',
        value: 'The door is open',
        provenance: 'messageId=source',
      ),
    ],
    unblockedTransitionClaims: ['The door is open.'],
    revisionNumber: 4,
    revisionHash: 'revision',
    cacheIdentity: 'canon/4',
  ),
  effectiveCanonRevisionNumber: 4,
  effectiveCanonRevisionHash: 'revision',
  effectiveCanonCacheIdentity: 'canon/4',
  recalledMessageChunks: const [
    RecalledMessageChunk(
      text: 'Key: old fact',
      messageIds: ['source'],
      score: 1,
    ),
    RecalledMessageChunk(
      text: 'Other evidence',
      messageIds: ['outside'],
      score: .5,
    ),
  ],
);

void main() {
  const preparer = StudioContextPreparer();
  late Directory fixture;
  late PromptWorker worker;

  setUpAll(() async {
    // Offline byte-only vocabulary: exercises a real encoder, without fetching
    // production data or touching the app's cache. The worker starts BPE-ready
    // while this test isolate remains in its genuine initial fallback state.
    final base = Directory('${Directory.systemTemp.path}/opencode');
    await base.create(recursive: true);
    fixture = await base.createTemp('studio-worker-test-');
    await File('${fixture.path}/o200k_base.tiktoken').writeAsString(
      [
        for (var byte = 0; byte < 256; byte++) '${base64Encode([byte])} $byte',
      ].join('\n'),
    );
    worker = await PromptWorker.createForTesting(appSupportPath: fixture.path);
  });

  tearDownAll(() async {
    worker.dispose();
    await fixture.delete(recursive: true);
  });

  test(
    'worker snapshot retains reasoning tags but no transport credentials',
    () async {
      const config = ApiConfig(
        id: 'transport-id',
        endpoint: 'https://synthetic-model.invalid',
        apiKey: 'synthetic-model-credential',
        embeddingEndpoint: 'https://synthetic-embedding.invalid',
        embeddingApiKey: 'synthetic-embedding-credential',
        reasoningTagStart: '<source-reasoning>',
        reasoningTagEnd: '</source-reasoning>',
        extraRequestParameters: [
          ExtraRequestParameter(
            key: 'Authorization',
            value: 'synthetic-extra-credential',
          ),
        ],
      );
      final inputs = _inputs(apiConfig: config);
      final snapshot = StudioContextPreparer.snapshotForWorker(inputs, {
        'current',
      });
      expect(
        snapshot.apiConfig.toJson(),
        const ApiConfig(
          id: 'transport-id',
          reasoningTagStart: '<source-reasoning>',
          reasoningTagEnd: '</source-reasoning>',
        ).toJson(),
      );
      expect(inputs.apiConfig, config);
      final prepared = await preparer.prepareAsync(
        inputs: inputs,
        visibleMessageIds: const {'current'},
        worker: worker,
      );
      expect(
        _contextValue(prepared),
        _contextValue(
          preparer.prepare(
            inputs: inputs,
            visibleMessageIds: const {'current'},
          ),
        ),
      );
    },
  );

  test(
    'actual worker prepare equals sync for full and chunk-first packing',
    () async {
      expect(o200kBaseLoaded, isFalse);
      for (final packing in ['full', 'hybrid', 'chunk_first']) {
        final source = _inputs();
        final inputs = GenerationContextInputs(
          character: source.character,
          history: source.history,
          apiConfig: source.apiConfig,
          sessionId: source.sessionId,
          sessionVars: source.sessionVars,
          globalVars: source.globalVars,
          summaryContent: source.summaryContent,
          summaryPrefix: source.summaryPrefix,
          continueInstruction: source.continueInstruction,
          lorebooks: source.lorebooks,
          vectorEntries: source.vectorEntries,
          memorySelection: source.memorySelection,
          memoryPackingMode: packing,
          recalledMessageChunks: source.recalledMessageChunks,
          runtimePromptBlocks: source.runtimePromptBlocks,
          effectiveCanonProjection: source.effectiveCanonProjection,
          effectiveCanonRevisionNumber: source.effectiveCanonRevisionNumber,
          effectiveCanonRevisionHash: source.effectiveCanonRevisionHash,
          effectiveCanonCacheIdentity: source.effectiveCanonCacheIdentity,
          gameTime: source.gameTime,
          gameDate: source.gameDate,
          gameDay: source.gameDay,
        );
        for (final visible in [
          <String>{'current'},
          <String>{'source', 'current'},
        ]) {
          final sync = preparer.prepare(
            inputs: inputs,
            visibleMessageIds: visible,
            reasoningTagStartOverride: '<studio-think>',
            studioPreset: const StudioPreset(id: 'studio'),
          );
          final prepared = await preparer.prepareAsync(
            inputs: inputs,
            visibleMessageIds: visible,
            reasoningTagStartOverride: '<studio-think>',
            studioPreset: const StudioPreset(id: 'studio'),
            worker: worker,
          );
          expect(
            _contextValue(prepared),
            _contextValue(sync),
            reason: '$packing/$visible',
          );
          expect(prepared.history.last.imagePaths, ['first.png', 'second.png']);
          expect(
            prepared.join(StudioContextSlot.loreMacro),
            contains('Lore for Кот'),
          );
        }
      }
    },
  );

  test(
    'Raw 5000 remains soft and counts source before Unicode transforms',
    () async {
      final crossing = 'Historical source with ordinary spaces. ' * 650;
      final inputs = GenerationContextInputs(
        character: const Character(id: 'cat', name: 'Кот'),
        history: const [],
        apiConfig: const ApiConfig(id: 'api'),
        recalledMessageChunks: [
          RecalledMessageChunk(
            text: crossing,
            messageIds: const ['old'],
            score: 1,
          ),
          const RecalledMessageChunk(
            text: 'Must not replace crossing source',
            messageIds: ['other'],
            score: .5,
          ),
        ],
      );
      final sync = preparer.prepare(
        inputs: inputs,
        visibleMessageIds: const {},
      );
      final prepared = await preparer.prepareAsync(
        inputs: inputs,
        visibleMessageIds: const {},
        worker: worker,
      );
      expect(_contextValue(prepared), _contextValue(sync));
      final source = prepared.join(StudioContextSlot.recalledMessages);
      expect(source, contains(crossing.trim()));
      expect(source, isNot(contains('Must not replace')));
      final packing =
          (prepared.diagnostics.memoryCoverage['rawRecall']
                  as Map)['finalPacking']
              as Map;
      expect(packing['tokenCounter'], 'approx_chars_per_4');
      expect(packing['estimatedTokens'], greaterThan(5000));
      expect(packing['budgetExceeded'], isTrue);
      expect(packing['stage'], 'prompt_context_packing');
      final transformed = applyStudioRegexesToText(
        text: source,
        stage: 'final',
        entries: const [
          StudioRegex(
            stages: {'final'},
            script: PresetRegex(
              id: 'unicode-spaces',
              name: 'Thin spaces',
              regex: '/ /g',
              replacement: '\u2009',
              placement: [1, 2, 4],
              ephemerality: [2],
            ),
          ),
        ],
        macroContext: prepared.macroContext,
        role: 'system',
      );
      expect(transformed, isNot(source));
      expect(prepared.join(StudioContextSlot.recalledMessages), source);
      expect(packing['budgetBasis'], 'source_before_prompt_transforms');
    },
  );

  test(
    'queue snapshot omits 21 MB variants and unsendable UI metadata',
    () async {
      final nonSendable = ReceivePort();
      addTearDown(nonSendable.close);
      final history = [
        ChatMessage(
          id: 'current',
          role: 'user',
          content: 'Selected text',
          swipes: ['x' * (21 * 1024 * 1024)],
          studioOutputs: [
            {'uiOnly': nonSendable},
          ],
          swipesMeta: [
            {'uiOnly': nonSendable},
          ],
        ),
      ];
      final visible = {'current'};
      final blocked = worker.debugBlock(
        const Duration(milliseconds: 40),
        'block',
      );
      final pending = preparer.prepareAsync(
        inputs: _inputs(history: history),
        visibleMessageIds: visible,
        worker: worker,
      );
      visible.clear();
      history.clear();
      await blocked;
      final context = await pending;
      expect(context.history.single.content, 'Selected text');
      expect(context.diagnostics.visibleMessageIds, {'current'});
    },
  );

  test(
    'tokenized job uses another isolate while main heartbeat runs',
    () async {
      final started = ReceivePort();
      addTearDown(started.close);
      var finished = false;
      final result = worker
          .runTokenized<SendPort>(_busyJob, started.sendPort)
          .then((value) {
            finished = true;
            return value;
          });
      await started.first;
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      timer.cancel();
      expect(ticks, greaterThan(0));
      expect(finished, isFalse);
      expect(await result, isNot(Isolate.current.controlPort));
    },
  );

  test('failed or unsendable jobs cannot wedge the existing queue', () async {
    final nonSendable = ReceivePort();
    addTearDown(nonSendable.close);
    await expectLater(
      worker.runTokenized<Object?>(_echo, nonSendable),
      throwsArgumentError,
    );
    await expectLater(
      worker.runTokenized<Object?>(_throwingJob, null),
      throwsException,
    );
    expect(
      await worker.runTokenized<String>(_echoString, 'retained'),
      'retained',
    );
    final value = await worker.runTokenized<Map<String, Object?>>(
      _tokenProbe,
      'test',
    );
    expect(
      value['ready'],
      isFalse,
    ); // worker BPE readiness must not override caller
    expect(value['tokens'], 1);
    expect(value['error'], contains('legitimate'));
  });

  test(
    'cancelled context consumer cannot publish or start the next call',
    () async {
      final token = CancelToken();
      var published = false;
      var nextCalls = 0;
      final blocked = worker.debugBlock(
        const Duration(milliseconds: 40),
        'block',
      );
      final pending = () async {
        final context = await preparer.prepareAsync(
          inputs: _inputs(),
          visibleMessageIds: const {'current'},
          worker: worker,
        );
        if (token.isCancelled) return;
        published = context.history.isNotEmpty;
        nextCalls++;
      }();
      token.cancel();
      await blocked;
      await pending;
      expect(published, isFalse);
      expect(nextCalls, 0);
      // Cancel belongs to the consumer, not the shared worker or another turn.
      expect(
        await worker.runTokenized<String>(_echoString, 'next turn'),
        'next turn',
      );
    },
  );

  test(
    'queued async context survives an earlier worker timeout/restart',
    () async {
      final previous = PromptWorker.requestTimeout;
      PromptWorker.requestTimeout = const Duration(milliseconds: 100);
      try {
        final timedOut = worker.debugBlock(
          const Duration(milliseconds: 400),
          'obsolete response',
        );
        final context = preparer.prepareAsync(
          inputs: const GenerationContextInputs(
            character: Character(id: 'cat', name: 'Кот'),
            history: [
              ChatMessage(id: 'current', role: 'user', content: 'Current'),
            ],
            apiConfig: ApiConfig(id: 'api'),
          ),
          visibleMessageIds: const {'current'},
          worker: worker,
        );
        await expectLater(timedOut, throwsA(isA<TimeoutException>()));
        expect((await context).history.single.content, 'Current');
        expect(
          await worker.runTokenized<String>(_echoString, 'fresh response'),
          'fresh response',
        );
      } finally {
        PromptWorker.requestTimeout = previous;
      }
    },
  );

  test(
    'dispose fails pending async contexts instead of publishing a late result',
    () async {
      final disposable = await PromptWorker.createForTesting(
        appSupportPath: fixture.path,
      );
      final block = disposable.debugBlock(
        const Duration(milliseconds: 200),
        'late',
      );
      final context = preparer.prepareAsync(
        inputs: _inputs(),
        visibleMessageIds: const {'current'},
        worker: disposable,
      );
      final blockFails = expectLater(block, throwsStateError);
      final contextFails = expectLater(context, throwsStateError);
      disposable.dispose();
      await Future.wait([blockFails, contextFails]);
    },
  );

  test(
    'ready caller gets real cached BPE parity and never silent fallback',
    () async {
      await preloadO200kBase(
        appSupportPath: fixture.path,
        allowDownload: false,
      );
      expect(o200kBaseLoaded, isTrue);
      const text = 'Кот 🐈‍⬛';
      final probe = await worker.runTokenized<Map<String, Object?>>(
        _tokenProbe,
        text,
      );
      expect(probe['ready'], isTrue);
      expect(probe['tokens'], estimateTokens(text));
      expect(
        probe['tokens'],
        utf8.encode(text).length,
      ); // real byte-only BPE fixture
      final inputs = _inputs();
      final sync = preparer.prepare(
        inputs: inputs,
        visibleMessageIds: const {'current'},
      );
      final prepared = await preparer.prepareAsync(
        inputs: inputs,
        visibleMessageIds: const {'current'},
        worker: worker,
      );
      expect(_contextValue(prepared), _contextValue(sync));
      final packing =
          (prepared.diagnostics.memoryCoverage['rawRecall']
                  as Map)['finalPacking']
              as Map;
      expect(packing['tokenCounter'], 'o200k_base_estimate');

      final missingCache = await fixture.parent.createTemp(
        'studio-worker-empty-',
      );
      final unavailable = await PromptWorker.createForTesting(
        appSupportPath: missingCache.path,
      );
      try {
        await expectLater(
          unavailable.runTokenized<Map<String, Object?>>(_tokenProbe, text),
          throwsA(
            predicate((Object? e) => e.toString().contains('cannot match')),
          ),
        );
      } finally {
        unavailable.dispose();
        await missingCache.delete();
      }
    },
  );
}
