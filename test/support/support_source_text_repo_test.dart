import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text/support_source_json.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/models/card_rewriter_settings.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

import 'helpers/support_source_text_native_fixture.dart';
import 'helpers/support_text_context_fixture.dart';

final class _Authority implements SupportSourceReadAuthority {
  _Authority(this.observation);
  @override
  final SupportSourceObservation observation;
  bool current = true;
  @override
  bool get isCurrent => current;
}

final class _UnformattableSourceFailure {
  const _UnformattableSourceFailure();
  @override
  String toString() =>
      throw StateError('Synthetic error must not be formatted');
}

/// Hold the original SELECT result after the native executor has completed,
/// while the repository is still awaiting it. No SQL/result substitution.
final class _AwaitActualStamp extends QueryInterceptor {
  final reached = Completer<void>();
  final release = Completer<void>();
  int stampReads = 0;
  bool attemptedBodyProjection = false;
  bool attemptedStudioDefinitionProjection = false;
  List<Map<String, Object?>> stampRows = [];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (RegExp(r'\bAS\s+body\b', caseSensitive: false).hasMatch(statement)) {
      attemptedBodyProjection = true;
    }
    if (statement.contains('SELECT blocks_json, agents_json')) {
      attemptedStudioDefinitionProjection = true;
    }
    final rows = await super.runSelect(executor, statement, args);
    if (statement.contains('total_changes()')) {
      stampReads++;
      stampRows = rows;
      if (!reached.isCompleted) reached.complete();
      await release.future;
    }
    return rows;
  }
}

void main() {
  late SupportSourceTextNativeFixture f;
  late SupportSourceTextRepo repo;
  setUp(() async {
    f = SupportSourceTextNativeFixture();
    await f.initialize();
    await f.seed();
    repo = SupportSourceTextRepo(
      db: f.db,
      cipher: f.cipher,
      currentRedactor: () => f.redactor,
    );
  });
  tearDown(() => f.close());

  // This public Drift scope wraps the SAME openedNative executor, including
  // each transaction. f.spy therefore records actual native SQL primitives.
  void sourceTest(String name, Future<void> Function() body) {
    test(name, () => f.db.runWithInterceptor(body, interceptor: f.spy));
  }

  Future<SupportSourceObservation> game() async {
    final page = await repo.catalog(
      domain: SupportSourceDomain.game,
      isCurrent: () => true,
    );
    final entry = page.entries.singleWhere(
      (e) => e.sourceId == SupportTextContextFixture.roleplayId,
    );
    return repo.observe(entry: entry, isCurrent: () => true);
  }

  Future<SupportSourceObservation> studio({int studioPage = 0}) async {
    final page = await repo.catalog(
      domain: SupportSourceDomain.studioPreset,
      isCurrent: () => true,
    );
    return repo.observe(
      entry: page.entries.single,
      studioPage: studioPage,
      isCurrent: () => true,
    );
  }

  String repeat(String value, int count) => List.filled(count, value).join();

  Future<void> savedStudio(String blocks, {String runtime = '{}'}) async {
    await f.db
        .into(f.db.studioPresetRows)
        .insert(
          StudioPresetRowsCompanion.insert(
            presetId: 'synthetic-paged-studio',
            name: 'Synthetic paged Studio',
            blocksJson: Value(blocks),
            runtimeSettingsJson: Value(runtime),
          ),
        );
  }

  String instruction(String content) => jsonEncode([
    {'id': 'a', 'type': 'instruction', 'content': content},
  ]);

  void expectNativePart(String sourceText, Map<dynamic, dynamic> result) {
    // The SAME actual result shape and constructor used by the native adapter;
    // sourceText is a string containing JSON, not a flattened metadata object.
    final native = NativeToolResult(
      callId: repeat('c', 128),
      name: 'astoria_source_read',
      content: {
        'ok': true,
        'code': 'completed',
        'effect': 'none',
        'data': {'sourceText': sourceText},
      },
    );
    final encodedJson = jsonEncode(native.content);
    expect(utf8.encode(encodedJson).length, lessThanOrEqualTo(65536));
    // Also account for identity fields around the actual content conservatively.
    expect(
      utf8
          .encode(
            jsonEncode({
              'callId': native.callId,
              'name': native.name,
              'content': native.content,
            }),
          )
          .length,
      lessThanOrEqualTo(65536),
    );
    final chunk = result['definitionChunk'] as String;
    expect(chunk.length, lessThanOrEqualTo(32768));
    expect(
      utf8.encode(jsonEncode(jsonEncode(chunk))).length - 6,
      lessThanOrEqualTo(40000),
    );
    expect(utf8.decode(utf8.encode(chunk)), chunk);
    expect(result.containsKey('definition'), isFalse);
    expect(result['completeDefinition'], isFalse);
    expect(result['encoding'], contains('one part is not the full definition'));
  }

  Future<StudioPresetRepo> saveCanonicalStudio() async {
    final writer = StudioPresetRepo(f.db);
    await writer.upsert(
      const StudioPreset(
        id: 'synthetic-canonical-studio',
        name: 'Synthetic canonical Studio',
        blocks: [
          StudioPresetBlock(
            id: 'synthetic-instruction',
            title: 'Synthetic instruction',
            content: 'SYNTHETIC_CANONICAL_INSTRUCTION',
            section: '',
            injectionPoint: 'final',
            insertionMode: 'depth',
            depth: 2,
            appendToLastMessage: true,
          ),
          StudioPresetBlock(
            id: 'synthetic-context',
            type: StudioBlockType.context,
            contextSlot: StudioContextSlot.characterCard,
            section: '',
          ),
          StudioPresetBlock(
            id: 'synthetic-history',
            type: StudioBlockType.history,
            section: '',
          ),
          StudioPresetBlock(
            id: 'synthetic-briefs',
            type: StudioBlockType.priorBriefs,
            section: '',
          ),
        ],
        agents: [
          StudioAgent(id: 'final', controllerId: 'final', specId: 'final'),
          StudioAgent(
            id: 'continuity',
            controllerId: 'continuity',
            specId: 'continuity',
            order: 1,
          ),
        ],
        agentEnabled: {'final': true, 'continuity': true},
        agentBlockRestoreState: {
          'continuity': ['synthetic-instruction'],
        },
        controllerAlternativeBlockIds: {
          'continuity': ['synthetic-instruction'],
        },
        expensiveApiConfigId: 'synthetic-expensive-api',
        cheapApiConfigId: 'synthetic-cheap-api',
        cleanerApiConfigId: 'synthetic-cleaner-api',
        ledgerApiConfigId: 'synthetic-ledger-api',
        runtime: StudioRuntimeSettings(
          cleaner: CleanerSettings(
            postCleanerStyleInstructions: 'SYNTHETIC_CLEANER_INSTRUCTION',
          ),
          ledger: LedgerSettings(),
          cardRewriter: CardRewriterSettings(),
          broadcastBlocks: ['synthetic-instruction'],
        ),
        updatedAt: 7,
      ),
    );
    return writer;
  }

  Matcher sourceFailure(SupportSourceReadFailure failure) =>
      isA<SupportSourceReadException>().having(
        (error) => error.failure,
        'safe refusal category',
        failure,
      );

  sourceTest(
    'catalog and exact observation never return body, decrypt, or hydrate',
    () async {
      f.observe();
      final observation = await game();
      expect(observation.orderedSourceIds, [
        'roleplay-a',
        'roleplay-unselected',
        'roleplay-b',
      ]);
      expect(f.spy.values, isNotEmpty);
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      final values = jsonEncode(f.spy.values);
      for (final canary in [
        SupportTextContextFixture.selected,
        SupportTextContextFixture.unselected,
        SupportTextContextFixture.card,
        SupportTextContextFixture.reasoning,
        SupportTextContextFixture.attachment,
      ]) {
        expect(values, isNot(contains(canary)));
      }
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'no body grant from wrong observation, reader owner, database, or retired authority',
    () async {
      final a = await game(), b = await game();
      f.observe();
      await expectLater(
        repo.read(observation: a, authority: _Authority(b)),
        throwsA(isA<SupportSourceReadException>()),
      );
      final sameDbOtherOwner = SupportSourceTextRepo(
        db: f.db,
        cipher: f.cipher,
        currentRedactor: () => f.redactor,
      );
      await expectLater(
        sameDbOtherOwner.read(observation: a, authority: _Authority(a)),
        throwsA(isA<SupportSourceReadException>()),
      );
      final other = SupportSourceTextNativeFixture();
      addTearDown(other.close);
      await other.initialize();
      final otherDb = SupportSourceTextRepo(
        db: other.db,
        cipher: other.cipher,
        currentRedactor: () => other.redactor,
      );
      await expectLater(
        otherDb.read(observation: a, authority: _Authority(a)),
        throwsA(isA<SupportSourceReadException>()),
      );
      final cancelled = _Authority(a)..current = false;
      await expectLater(
        repo.read(observation: a, authority: cancelled),
        throwsA(isA<SupportSourceReadException>()),
      );
      expect(f.spy.values, isEmpty);
    },
  );

  sourceTest(
    'exact current memory observation cannot confer native file authority',
    () async {
      final memory = SupportTextContextFixture();
      addTearDown(memory.close);
      await memory.seed();
      final reader = SupportSourceTextRepo(
        db: memory.db,
        cipher: memory.cipher,
        currentRedactor: () => memory.redactor,
      );
      final page = await reader.catalog(
        domain: SupportSourceDomain.game,
        isCurrent: () => true,
      );
      final entry = page.entries.singleWhere(
        (e) => e.sourceId == SupportTextContextFixture.roleplayId,
      );
      final observation = await reader.observe(
        entry: entry,
        isCurrent: () => true,
      );
      expect(observation.orderedSourceIds, isNotEmpty);
      expect(memory.db.nativeDataSourceIdentity, isNull);
      memory.observe();
      await expectLater(
        reader.read(
          observation: observation,
          authority: _Authority(observation),
        ),
        throwsA(isA<SupportSourceReadException>()),
      );
      expect(memory.spy.values, isEmpty);
      expect(memory.primitive.decryptAads, isEmpty);
      expect(memory.storage.operations, isEmpty);
    },
  );

  sourceTest(
    'exact trailing 16 active IDs, no hidden/variant/attachment fields, no digest egress',
    () async {
      await f.replaceRoleplay([
        for (var i = 0; i < 20; i++)
          SupportTextContextFixture.message('game-$i', body: 'Active $i'),
        {
          ...SupportTextContextFixture.message(
            'hidden',
            body: SupportTextContextFixture.other,
          ),
          'isHidden': true,
        },
      ]);
      final observation = await game(), authority = _Authority(await game());
      // Native authority must retain the very same original observation pointer.
      final exact = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: exact,
      );
      final result = await repo.toolResult(
        snapshot: snapshot,
        authority: exact,
      );
      expect(observation.orderedSourceIds, [
        for (var i = 4; i < 20; i++) 'game-$i',
      ]);
      expect(result, contains('Active 19'));
      for (final canary in [
        SupportTextContextFixture.card,
        SupportTextContextFixture.reasoning,
        SupportTextContextFixture.attachment,
        SupportTextContextFixture.unselected,
        SupportTextContextFixture.other,
        snapshot.snapshotDigestForEncryptedProvenance,
      ]) {
        expect(result, isNot(contains(canary)));
      }
      expect(utf8.encode(result).length, lessThanOrEqualTo(65536));
      expect(
        await repo.revalidate(snapshot: snapshot, authority: authority),
        isFalse,
      );
    },
  );

  sourceTest(
    'actual ChatRepo serializer admits plain, swipe and cleaned active text only',
    () async {
      await ChatRepo(f.db).put(
        const ChatSession(
          id: SupportTextContextFixture.roleplayId,
          characterId: 'synthetic-character',
          sessionIndex: 0,
          messages: [
            ChatMessage(
              id: 'serialized-user',
              role: 'user',
              content: 'SYNTHETIC_SERIALIZED_USER',
              imagePath: SupportTextContextFixture.attachment,
            ),
            ChatMessage(
              id: 'serialized-plain',
              role: 'assistant',
              content: 'SYNTHETIC_SERIALIZED_PLAIN',
            ),
            ChatMessage(
              id: 'serialized-swipe',
              role: 'assistant',
              content: 'SYNTHETIC_SERIALIZED_SWIPE',
              swipeId: 1,
              swipes: [
                SupportTextContextFixture.unselected,
                'SYNTHETIC_SERIALIZED_SWIPE',
              ],
            ),
            ChatMessage(
              id: 'serialized-cleaned',
              role: 'assistant',
              content: 'SYNTHETIC_SERIALIZED_CLEANED',
              swipes: [SupportTextContextFixture.unselected],
              reasoning: SupportTextContextFixture.reasoning,
              agentSwipeId: 1,
              agentSwipes: [
                AgentSwipe(content: SupportTextContextFixture.unselected),
                AgentSwipe(
                  content: 'SYNTHETIC_SERIALIZED_CLEANED',
                  kind: 'cleaned',
                  reasoning: SupportTextContextFixture.reasoning,
                ),
              ],
              swipesMeta: [
                {'rawPrompt': SupportTextContextFixture.card},
              ],
            ),
          ],
          updatedAt: 7,
        ),
      );
      f.observe();
      final observation = await game();
      expect(observation.orderedSourceIds, [
        'serialized-user',
        'serialized-plain',
        'serialized-swipe',
        'serialized-cleaned',
      ]);
      expect(
        jsonEncode(f.spy.values),
        isNot(contains('SYNTHETIC_SERIALIZED_')),
      );
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final wire = await repo.toolResult(
        snapshot: snapshot,
        authority: authority,
      );
      final result = jsonDecode(wire) as Map;
      expect(
        (result['messages'] as List).map((m) => (m as Map)['text']).toList(),
        [
          'SYNTHETIC_SERIALIZED_USER',
          'SYNTHETIC_SERIALIZED_PLAIN',
          'SYNTHETIC_SERIALIZED_SWIPE',
          'SYNTHETIC_SERIALIZED_CLEANED',
        ],
      );
      for (final canary in [
        SupportTextContextFixture.unselected,
        SupportTextContextFixture.reasoning,
        SupportTextContextFixture.attachment,
        SupportTextContextFixture.card,
      ]) {
        expect(wire, isNot(contains(canary)));
      }
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'changed raw active text refuses even if redaction hides the change',
    () async {
      const otherSecret = 'SYNTHETIC_HISTORY_SECRET_9c21';
      f.redactor = SecretRedactor(
        knownSecrets: [SupportTextContextFixture.secret, otherSecret],
      );
      final observation = await game();
      final exact = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: exact,
      );
      await f.replaceRoleplay([
        SupportTextContextFixture.message(
          'roleplay-a',
          role: 'user',
          body: '${SupportTextContextFixture.selected} $otherSecret',
        ),
        SupportTextContextFixture.message(
          'roleplay-unselected',
          body: SupportTextContextFixture.unselected,
        ),
        SupportTextContextFixture.message(
          'roleplay-b',
          body: 'Synthetic second',
        ),
      ]);
      expect(
        await repo.revalidate(snapshot: snapshot, authority: exact),
        isFalse,
      );
      await expectLater(
        repo.toolResult(snapshot: snapshot, authority: exact),
        throwsA(sourceFailure(SupportSourceReadFailure.changed)),
      );
    },
  );

  sourceTest(
    'metadata-ordered catalog is bounded; approved body changes before read refuse',
    () async {
      for (var i = 0; i < 17; i++) {
        await f.db
            .into(f.db.chatSessions)
            .insert(
              ChatSessionsCompanion.insert(
                sessionId: 'new-$i',
                characterId: 'synthetic-character',
                sessionIndex: i + 2,
                messagesJson: jsonEncode([
                  SupportTextContextFixture.message('msg-$i'),
                ]),
                updatedAt: Value(100 + i),
              ),
            );
      }
      final page = await repo.catalog(
        domain: SupportSourceDomain.game,
        isCurrent: () => true,
      );
      expect(page.entries.length, 16);
      expect(page.entries.first.sourceId, 'new-16');
      expect(page.nextOffset, 16);
      final next = await repo.catalog(
        domain: SupportSourceDomain.game,
        offset: page.nextOffset!,
        isCurrent: () => true,
      );
      expect(next.entries.first.sourceId, 'new-0');
      final observation = await repo.observe(
        entry: next.entries.singleWhere(
          (e) => e.sourceId == SupportTextContextFixture.roleplayId,
        ),
        isCurrent: () => true,
      );
      await f.replaceRoleplay([
        SupportTextContextFixture.message('replacement'),
      ]);
      await expectLater(
        repo.read(observation: observation, authority: _Authority(observation)),
        throwsA(sourceFailure(SupportSourceReadFailure.changed)),
      );
    },
  );

  sourceTest(
    'unchanged exact game source survives unrelated own-chat writes',
    () async {
      final observation = await game(), authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      await f.supportMessage(
        'unrelated-user',
        role: 'user',
        body: 'Synthetic unrelated update',
      );
      expect(
        await repo.revalidate(snapshot: snapshot, authority: authority),
        isTrue,
      );
      expect(
        await repo.toolResult(snapshot: snapshot, authority: authority),
        contains(SupportTextContextFixture.selected),
      );
      authority.current = false;
      await expectLater(
        repo.toolResult(snapshot: snapshot, authority: authority),
        throwsA(isA<SupportSourceReadException>()),
      );
    },
  );

  sourceTest(
    'active Studio metadata precedes newer inactive presets and missing selection falls back without body reads',
    () async {
      for (final id in [
        'default',
        'selected',
        for (var i = 0; i < 17; i++) 'inactive-$i',
      ]) {
        await f.db
            .into(f.db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: id,
                name: id,
                blocksJson: const Value(
                  '[{"id":"a","type":"instruction","content":"PRIVATE_SELECTED_STUDIO_BODY"}]',
                ),
                updatedAt: Value(id.startsWith('inactive') ? 1000 : 1),
              ),
            );
      }
      f.observe();
      final selected = await repo.catalog(
        domain: SupportSourceDomain.studioPreset,
        activeStudioPresetId: 'selected',
        isCurrent: () => true,
      );
      expect(selected.entries, hasLength(16));
      expect(selected.entries.first.sourceId, 'selected');
      expect(selected.activeStudioSourceId, 'selected');
      final fallback = await repo.catalog(
        domain: SupportSourceDomain.studioPreset,
        activeStudioPresetId: 'deleted-selection',
        isCurrent: () => true,
      );
      expect(fallback.entries.first.sourceId, 'default');
      expect(fallback.activeStudioSourceId, 'default');
      expect(
        jsonEncode(f.spy.values),
        isNot(contains('PRIVATE_SELECTED_STUDIO_BODY')),
      );
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'oversize escaped tool JSON refuses, never silently clips active text',
    () async {
      await f.replaceRoleplay([
        SupportTextContextFixture.message(
          'escaped',
          body: List.filled(60000, '\n').join(),
        ),
      ]);
      final observation = await game();
      expect(observation.textBytes, 60000);
      await expectLater(
        repo.read(observation: observation, authority: _Authority(observation)),
        throwsA(sourceFailure(SupportSourceReadFailure.tooLarge)),
      );
    },
  );

  sourceTest(
    'actual StudioPresetRepo serializer roundtrips every configured saved lane exactly',
    () async {
      await saveCanonicalStudio();
      final saved = await f.db.select(f.db.studioPresetRows).getSingle();
      f.observe();
      final observation = await studio();
      for (final text in [
        'SYNTHETIC_CANONICAL_INSTRUCTION',
        'SYNTHETIC_CLEANER_INSTRUCTION',
      ]) {
        expect(jsonEncode(f.spy.values), isNot(contains(text)));
      }
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final result =
          jsonDecode(
                await repo.toolResult(snapshot: snapshot, authority: authority),
              )
              as Map;
      expect(result['definition'], {
        'blocks': jsonDecode(saved.blocksJson),
        'agents': jsonDecode(saved.agentsJson),
        'agentEnabled': jsonDecode(saved.agentEnabledJson),
        'runtime': jsonDecode(saved.runtimeSettingsJson),
        'maxFinalHistoryMessages': saved.maxFinalHistoryMessages,
        'executionMode': saved.executionMode,
        'expensiveApiConfigId': saved.expensiveApiConfigId,
        'cheapApiConfigId': saved.cheapApiConfigId,
        'cleanerApiConfigId': saved.cleanerApiConfigId,
        'ledgerApiConfigId': saved.ledgerApiConfigId,
      });
      expect(f.db.nativeDataSourceIdentity?.belongsTo(f.db), isTrue);
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'actual native Studio toggle restoration map remains exact saved configuration',
    () async {
      final writer = await saveCanonicalStudio();
      final expected = (await writer.controlObserve(
        'synthetic-canonical-studio',
      ))!;
      expect(
        await writer.controlAgentToggle(
          expected: expected,
          toggled: expected.copyWith(
            agentEnabled: {'final': true, 'continuity': false},
            agentEnabledBeforeDependencyOff: {'continuity': true},
          ),
          timestamp: 8,
          current: () => true,
        ),
        isTrue,
      );
      final saved = await f.db.select(f.db.studioPresetRows).getSingle();
      final savedRuntime = jsonDecode(saved.runtimeSettingsJson) as Map;
      expect(savedRuntime['agentEnabledBeforeDependencyOff'], {
        'continuity': true,
      });
      f.observe();
      final observation = await studio();
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final result =
          jsonDecode(
                await repo.toolResult(snapshot: snapshot, authority: authority),
              )
              as Map;
      expect((result['definition'] as Map)['runtime'], savedRuntime);
      expect((result['definition'] as Map)['agentEnabled'], {
        'final': true,
        'continuity': false,
      });
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'actual raw Studio seed dialect is preserved without canonicalization or macro execution',
    () async {
      // Exercise every actual seed record shape, with synthetic authored text.
      // Production onCreate uses the same jsonEncode of raw seed maps. The
      // Preserve every record even when metadata size selects paged disclosure.
      final blocks = [
        for (final block in defaultStudioPresetSeedBlocks())
          {
            ...block,
            'content': 'SYNTHETIC_SEED_${block['id']} {{description}}',
          },
      ];
      await f.db
          .into(f.db.studioPresetRows)
          .insert(
            StudioPresetRowsCompanion.insert(
              presetId: 'synthetic-raw-seed',
              name: 'Synthetic raw seed',
              blocksJson: Value(jsonEncode(blocks)),
            ),
          );
      f.observe();
      final observation = await studio();
      expect(jsonEncode(f.spy.values), isNot(contains('SYNTHETIC_SEED_')));
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      var wire = await repo.toolResult(
        snapshot: snapshot,
        authority: authority,
      );
      final result = jsonDecode(wire) as Map;
      Map<dynamic, dynamic> definition;
      if (result.containsKey('definition')) {
        definition = result['definition'] as Map<dynamic, dynamic>;
      } else {
        final chunks = <String>[result['definitionChunk'] as String];
        var next = result['nextStudioPage'] as int?;
        while (next != null) {
          final nextObservation = await studio(studioPage: next);
          final nextAuthority = _Authority(nextObservation);
          final nextSnapshot = await repo.read(
            observation: nextObservation,
            authority: nextAuthority,
          );
          final nextWire = await repo.toolResult(
            snapshot: nextSnapshot,
            authority: nextAuthority,
          );
          final nextResult = jsonDecode(nextWire) as Map<String, dynamic>;
          expect(nextResult['studioPage'], next);
          expect(nextResult['completeDefinition'], isFalse);
          chunks.add(nextResult['definitionChunk'] as String);
          wire += nextWire;
          next = nextResult['nextStudioPage'] as int?;
        }
        expect(chunks, hasLength(result['totalStudioPages'] as int));
        definition = jsonDecode(chunks.join()) as Map<String, dynamic>;
      }
      expect(definition['blocks'], blocks);
      expect(wire, contains('{{description}}'));
      expect(wire, isNot(contains(SupportTextContextFixture.card)));
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'saved Studio JSON stays exact, with no historical prompt claim or game association',
    () async {
      final blocks = [
        {
          'id': 'instruction',
          'type': 'instruction',
          'content': 'SAVED INSTRUCTION',
          'section': '',
          'injectionPoint': 'final',
          'mode': 'direct',
          'locked': false,
          'role': 'system',
        },
      ];
      await f.db
          .into(f.db.studioPresetRows)
          .insert(
            StudioPresetRowsCompanion.insert(
              presetId: 'studio-current',
              name: 'Synthetic Studio',
              blocksJson: Value(jsonEncode(blocks)),
              runtimeSettingsJson: const Value(
                '{"version":1,"broadcastBlocks":[]}',
              ),
              updatedAt: const Value(7),
            ),
          );
      f.observe();
      final page = await repo.catalog(
        domain: SupportSourceDomain.studioPreset,
        isCurrent: () => true,
      );
      final observation = await repo.observe(
        entry: page.entries.single,
        isCurrent: () => true,
      );
      expect(f.spy.values, isNotEmpty);
      expect(jsonEncode(f.spy.values), isNot(contains('SAVED INSTRUCTION')));
      expect(f.primitive.decryptAads, isEmpty);
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final result =
          jsonDecode(
                await repo.toolResult(snapshot: snapshot, authority: authority),
              )
              as Map;
      expect(result['state'], 'CURRENT SAVED');
      expect((result['definition'] as Map)['blocks'], blocks);
      expect(result['scope'], contains('Not a historical assembled prompt'));
      expect(result, isNot(contains('gameSessionId')));
    },
  );

  sourceTest(
    'single huge Studio instruction reconstructs across scalar-safe bounded native parts',
    () async {
      const prefix = '{"blocks":[{"id":"a","type":"instruction","content":"';
      final content =
          '${repeat('x', 32767 - prefix.length)}😀'
          '${repeat('😀界', 14000)}${repeat('"\\\n', 12000)}END_OF_HUGE_INSTRUCTION';
      final blocks = instruction(content);
      expect(utf8.encode(blocks).length, greaterThan(65536));
      await savedStudio(blocks);
      f.observe();
      final observation = await studio();
      expect(observation.studioPage, 0);
      expect(observation.studioIsPaged, isTrue);
      expect(observation.extentDescription, contains('FULL preset'));
      expect(observation.extentDescription, contains('ONLY Part 1'));
      expect(observation.extentDescription, contains('after consent'));
      expect(observation.extentDescription, contains('independent consent'));
      expect(observation.orderedSourceIds, [
        'synthetic-paged-studio',
        'studio-page:0',
      ]);
      expect(jsonEncode(f.spy.values), isNot(contains('blocks_json')));
      expect(
        jsonEncode(f.spy.values),
        isNot(contains('END_OF_HUGE_INSTRUCTION')),
      );
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);

      final chunks = <String>[];
      final digests = <String>{}, provenanceIds = <String>{};
      var next = 0;
      int? total;
      do {
        final original = next == 0
            ? observation
            : await studio(studioPage: next);
        final authority = _Authority(original);
        final snapshot = await repo.read(
          observation: original,
          authority: authority,
        );
        final wire = await repo.toolResult(
          snapshot: snapshot,
          authority: authority,
        );
        final result = jsonDecode(wire) as Map;
        expectNativePart(wire, result);
        expect(result['state'], 'CURRENT SAVED');
        expect(result['studioPage'], next);
        total ??= result['totalStudioPages'] as int;
        expect(result['totalStudioPages'], total);
        expect(result['nextStudioPage'], next + 1 < total ? next + 1 : null);
        expect(
          wire,
          isNot(contains(snapshot.snapshotDigestForEncryptedProvenance)),
        );
        expect(snapshot.toString(), 'SupportSourceSnapshot');
        expect(
          digests.add(snapshot.snapshotDigestForEncryptedProvenance),
          isTrue,
        );
        expect(provenanceIds.add(snapshot.orderedSourceIds.last), isTrue);
        chunks.add(result['definitionChunk'] as String);
        next++;
      } while (next < total);
      expect(chunks.first.length, 32767);
      expect(chunks[1], startsWith('😀'));
      final reconstructed = jsonDecode(chunks.join()) as Map;
      expect(reconstructed['blocks'], jsonDecode(blocks));
      expect((reconstructed['blocks'] as List), hasLength(1));
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'Studio redacts a known secret spanning the unsanitized part boundary before splitting',
    () async {
      const prefix = '{"blocks":[{"id":"a","type":"instruction","content":"';
      const secret = 'SYNTHETIC_BOUNDARY_SECRET_82af';
      f.redactor = SecretRedactor(knownSecrets: [secret]);
      final content =
          '${repeat('a', 32768 - prefix.length - secret.length ~/ 2)}'
          '$secret${repeat('b', 70000)}';
      await savedStudio(instruction(content));
      final parts = <String>[];
      int? total;
      for (var page = 0; total == null || page < total; page++) {
        final observation = await studio(studioPage: page);
        final authority = _Authority(observation);
        final snapshot = await repo.read(
          observation: observation,
          authority: authority,
        );
        final wire = await repo.toolResult(
          snapshot: snapshot,
          authority: authority,
        );
        final result = jsonDecode(wire) as Map;
        expectNativePart(wire, result);
        total = result['totalStudioPages'] as int;
        expect(wire, isNot(contains(secret)));
        expect(wire, isNot(contains('SYNTHETIC_BOUNDARY_')));
        expect(wire, isNot(contains('SECRET_82af')));
        parts.add(result['definitionChunk'] as String);
      }
      final definition = jsonDecode(parts.join()) as Map;
      expect(
        ((definition['blocks'] as List).single as Map)['content'],
        content.replaceAll(secret, SecretRedactor.removed),
      );
    },
  );

  sourceTest(
    'paged Studio denies wrong and cancelled authority without raw projection',
    () async {
      await savedStudio(instruction(repeat('x', 90000)));
      final first = await studio(), second = await studio(studioPage: 1);
      f.observe();
      await expectLater(
        repo.read(observation: first, authority: _Authority(second)),
        throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
      );
      await expectLater(
        repo.read(
          observation: first,
          authority: _Authority(first)..current = false,
        ),
        throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
      );
      expect(f.spy.values, isEmpty);
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
    },
  );

  sourceTest(
    'mutation outside disclosed Studio part revokes whole-raw snapshot even with identical sanitized output',
    () async {
      const a = 'SYNTHETIC_TAIL_SECRET_aa01', b = 'SYNTHETIC_TAIL_SECRET_bb02';
      f.redactor = SecretRedactor(knownSecrets: [a, b]);
      await savedStudio(instruction('${repeat('x', 90000)}$a'));
      final observation = await studio(), authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final before = await repo.toolResult(
        snapshot: snapshot,
        authority: authority,
      );
      final otherPage = await studio(studioPage: 1);
      final otherAuthority = _Authority(otherPage);
      final otherSnapshot = await repo.read(
        observation: otherPage,
        authority: otherAuthority,
      );
      await f.db
          .update(f.db.studioPresetRows)
          .write(
            StudioPresetRowsCompanion(
              blocksJson: Value(instruction('${repeat('x', 90000)}$b')),
            ),
          );
      final fresh = await studio(), freshAuthority = _Authority(fresh);
      final freshSnapshot = await repo.read(
        observation: fresh,
        authority: freshAuthority,
      );
      expect(
        await repo.toolResult(
          snapshot: freshSnapshot,
          authority: freshAuthority,
        ),
        before,
      );
      expect(
        freshSnapshot.snapshotDigestForEncryptedProvenance,
        isNot(snapshot.snapshotDigestForEncryptedProvenance),
      );
      expect(
        await repo.revalidate(snapshot: snapshot, authority: authority),
        isFalse,
      );
      expect(
        await repo.revalidate(
          snapshot: otherSnapshot,
          authority: otherAuthority,
        ),
        isFalse,
      );
      await expectLater(
        repo.toolResult(snapshot: snapshot, authority: authority),
        throwsA(sourceFailure(SupportSourceReadFailure.changed)),
      );
      expect(before, isNot(contains(a)));
      expect(before, isNot(contains(b)));
      f.observe();
      await expectLater(
        repo.read(observation: observation, authority: authority),
        throwsA(sourceFailure(SupportSourceReadFailure.changed)),
      );
      expect(jsonEncode(f.spy.values), isNot(contains('blocks_json')));
    },
  );

  sourceTest(
    'Studio pages are exact extents, never message offsets or partial definitions as whole',
    () async {
      final blocks = [
        {
          'id': 'a',
          'name': 'Synthetic raw seed',
          'kind': 'custom_text',
          'content': '${repeat('x', 13000)}{{description}}',
          'enabled': false,
        },
      ];
      const runtime = '{"agentEnabledBeforeDependencyOff":{"continuity":true}}';
      await savedStudio(jsonEncode(blocks), runtime: runtime);
      final page = await repo.catalog(
        domain: SupportSourceDomain.studioPreset,
        isCurrent: () => true,
      );
      f.observe();
      for (final args in [(0, -1), (0, 256), (1, 0)]) {
        await expectLater(
          repo.observe(
            entry: page.entries.single,
            activeMessageOffset: args.$1,
            studioPage: args.$2,
            isCurrent: () => true,
          ),
          throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
        );
      }
      expect(f.spy.values, isEmpty);
      final outOfRange = await studio(studioPage: 255);
      expect(outOfRange.extentDescription, contains('ONLY Part 256'));
      expect(jsonEncode(f.spy.values), isNot(contains('blocks_json')));
      await expectLater(
        repo.read(observation: outOfRange, authority: _Authority(outOfRange)),
        throwsA(sourceFailure(SupportSourceReadFailure.notFound)),
      );
      final original = await studio(), authority = _Authority(original);
      final snapshot = await repo.read(
        observation: original,
        authority: authority,
      );
      final wire = await repo.toolResult(
        snapshot: snapshot,
        authority: authority,
      );
      final result = jsonDecode(wire) as Map;
      expectNativePart(wire, result);
      expect(result['totalStudioPages'], 1);
      expect(result['nextStudioPage'], isNull);
      expect(result['completeDefinition'], isFalse);
      final definition = jsonDecode(result['definitionChunk'] as String) as Map;
      expect(definition['blocks'], blocks);
      expect(definition['runtime'], jsonDecode(runtime));
      expect(wire, contains('{{description}}'));
      expect(wire, isNot(contains(SupportTextContextFixture.card)));
      final games = await repo.catalog(
        domain: SupportSourceDomain.game,
        isCurrent: () => true,
      );
      f.observe();
      await expectLater(
        repo.observe(
          entry: games.entries.first,
          studioPage: 1,
          isCurrent: () => true,
        ),
        throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
      );
      expect(f.spy.values, isEmpty);
    },
  );

  sourceTest(
    'small Studio keeps complete definition and permits only page zero',
    () async {
      await savedStudio(instruction('SMALL_SYNTHETIC_INSTRUCTION'));
      final observation = await studio();
      expect(observation.studioIsPaged, isFalse);
      expect(observation.orderedSourceIds, ['synthetic-paged-studio']);
      expect(
        observation.extentDescription,
        contains('complete saved definition disclosed'),
      );
      await expectLater(
        studio(studioPage: 1),
        throwsA(sourceFailure(SupportSourceReadFailure.notFound)),
      );
      final authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final result =
          jsonDecode(
                await repo.toolResult(snapshot: snapshot, authority: authority),
              )
              as Map;
      expect(result.containsKey('definitionChunk'), isFalse);
      expect(result['definition'], isA<Map<dynamic, dynamic>>());
    },
  );

  for (final tail in [
    '{"id":"bad","type":"instruction","content":"x","locked":true}',
    '{"id":"bad","type":"instruction","content":"x","unknownFutureField":"x"}',
    '{"id":"bad","type":"instruction","content":"x","content":"y"}',
    '{"id":"bad","type":"instruction","content":"\\ud800"}',
    'not-json',
  ]) {
    sourceTest(
      'Studio paged whole validation refuses unsupported tail: $tail',
      () async {
        final valid = instruction(repeat('x', 90000));
        await savedStudio('${valid.substring(0, valid.length - 1)},$tail]');
        final observation = await studio();
        expect(observation.studioIsPaged, isTrue);
        await expectLater(
          repo.read(
            observation: observation,
            authority: _Authority(observation),
          ),
          throwsA(
            sourceFailure(
              tail.contains('"locked":true')
                  ? SupportSourceReadFailure.locked
                  : SupportSourceReadFailure.unsupportedFormat,
            ),
          ),
        );
        expect(observation.toString(), 'SupportSourceObservation');
        expect(
          const SupportSourceReadException().toString(),
          'Support source unavailable.',
        );
      },
    );
  }

  sourceTest(
    'Studio paged validation includes runtime outside the disclosed part',
    () async {
      await savedStudio(
        instruction(repeat('x', 90000)),
        runtime: '{"future":true}',
      );
      final observation = await studio();
      await expectLater(
        repo.read(observation: observation, authority: _Authority(observation)),
        throwsA(sourceFailure(SupportSourceReadFailure.unsupportedFormat)),
      );
    },
  );

  sourceTest(
    'Studio complete safe JSON has a local hard cap without partial disclosure',
    () async {
      f.redactor = SecretRedactor(knownSecrets: ['~']);
      await savedStudio(
        jsonEncode([
          for (final id in ['a', 'b', 'c'])
            {'id': id, 'type': 'instruction', 'content': repeat('~', 150000)},
        ]),
      );
      final observation = await studio();
      expect(observation.textBytes, lessThan(2 * 1024 * 1024));
      await expectLater(
        repo.read(observation: observation, authority: _Authority(observation)),
        throwsA(sourceFailure(SupportSourceReadFailure.tooLarge)),
      );
    },
  );

  sourceTest(
    'Studio-only JSON byte override leaves strict parser budgets unchanged',
    () async {
      final large = jsonEncode(repeat('x', 70000));
      expect(() => SupportSourceJson.decode(large), throwsFormatException);
      expect(
        SupportSourceJson.decode(large, maxBytes: 2 * 1024 * 1024),
        repeat('x', 70000),
      );
      for (final bad in [
        '{"a":1,"a":2}',
        '[${List.filled(513, '0').join(',')}]',
        '${repeat('[', 26)}0${repeat(']', 26)}',
        jsonEncode(List.generate(17, (_) => List.filled(512, 0))),
        '"\\ud800"',
        '1e999',
      ]) {
        expect(
          () => SupportSourceJson.decode(bad, maxBytes: 2 * 1024 * 1024),
          throwsFormatException,
        );
      }
    },
  );

  for (final bad in [
    '[{"id":"a","type":"instruction","content":"x","futureCode":"x"}]',
    '[{"id":"a","id":"b","type":"instruction","content":"x"}]',
    '[{"id":"a","type":"instruction","content":"x","locked":true}]',
    '[{"id":"a","name":"Synthetic seed","kind":"future_code","content":"x"}]',
    '[{"id":"a","name":"Synthetic seed","kind":"instruction","content":"x","futureCode":"x"}]',
    '[{"id":"a","name":"Synthetic seed","kind":"instruction","content":"x","locked":true}]',
    '[{"id":"a","name":"Synthetic seed","kind":"instruction","kind":"custom_text","content":"x"}]',
    'not-json',
  ]) {
    sourceTest(
      'unsupported/malformed/locked Studio definition refuses whole snapshot: ${bad.length}',
      () async {
        await f.db
            .into(f.db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: 'bad-studio',
                name: 'Synthetic bad',
                blocksJson: Value(bad),
              ),
            );
        final page = await repo.catalog(
          domain: SupportSourceDomain.studioPreset,
          isCurrent: () => true,
        );
        final observation = await repo.observe(
          entry: page.entries.single,
          isCurrent: () => true,
        );
        await expectLater(
          repo.read(
            observation: observation,
            authority: _Authority(observation),
          ),
          throwsA(
            sourceFailure(
              bad.contains('"locked":true')
                  ? SupportSourceReadFailure.locked
                  : SupportSourceReadFailure.unsupportedFormat,
            ),
          ),
        );
      },
    );
  }

  for (final bad in [
    'null',
    '[]',
    '{"continuity":1}',
    '{"invalid id":true}',
    '{"continuity":true,"continuity":false}',
  ]) {
    sourceTest(
      'malformed native Studio toggle state refuses whole source: $bad',
      () async {
        await f.db
            .into(f.db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: 'synthetic-bad-toggle-state',
                name: 'Synthetic bad toggle state',
                blocksJson: const Value(
                  '[{"id":"a","type":"instruction","content":"SYNTHETIC_REFUSED_BODY"}]',
                ),
                runtimeSettingsJson: Value(
                  '{"agentEnabledBeforeDependencyOff":$bad}',
                ),
              ),
            );
        final observation = await studio();
        await expectLater(
          repo.read(
            observation: observation,
            authority: _Authority(observation),
          ),
          throwsA(sourceFailure(SupportSourceReadFailure.unsupportedFormat)),
        );
        expect(
          const SupportSourceReadException(
            failure: SupportSourceReadFailure.unsupportedFormat,
          ).toString(),
          'Support source unavailable.',
        );
      },
    );
  }

  sourceTest(
    'Studio local hard cap refuses before definition projection; game malformed/locked refuses',
    () async {
      await f.db
          .into(f.db.studioPresetRows)
          .insert(
            StudioPresetRowsCompanion.insert(
              presetId: 'oversize',
              name: 'Synthetic large',
              blocksJson: Value(
                jsonEncode([
                  {
                    'id': 'a',
                    'type': 'instruction',
                    'content': repeat('x', 2 * 1024 * 1024),
                  },
                ]),
              ),
            ),
          );
      f.observe();
      final page = await repo.catalog(
        domain: SupportSourceDomain.studioPreset,
        isCurrent: () => true,
      );
      await expectLater(
        repo.observe(entry: page.entries.single, isCurrent: () => true),
        throwsA(sourceFailure(SupportSourceReadFailure.tooLarge)),
      );
      expect(f.spy.values, isNotEmpty);
      expect(jsonEncode(f.spy.values), isNot(contains('blocks_json')));
      f.stopObserving();
      await f.replaceRoleplayJson('{"invalid":"source"}');
      await expectLater(
        game(),
        throwsA(sourceFailure(SupportSourceReadFailure.unsupportedFormat)),
      );
      await f.replaceRoleplay([
        {...SupportTextContextFixture.message('locked'), 'isLocked': true},
      ]);
      await expectLater(game(), throwsA(isA<SupportSourceReadException>()));
    },
  );

  sourceTest(
    'safe not-found and unknown-failure categories retain no private error details',
    () async {
      final page = await repo.catalog(
        domain: SupportSourceDomain.game,
        isCurrent: () => true,
      );
      final entry = page.entries.singleWhere(
        (e) => e.sourceId == SupportTextContextFixture.roleplayId,
      );
      await (f.db.delete(f.db.chatSessions)..where(
            (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
          ))
          .go();
      f.observe();
      await expectLater(
        repo.observe(entry: entry, isCurrent: () => true),
        throwsA(sourceFailure(SupportSourceReadFailure.notFound)),
      );
      f.spy.selectError = const _UnformattableSourceFailure();
      await expectLater(
        repo.catalog(domain: SupportSourceDomain.game, isCurrent: () => true),
        throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
      );
      for (final failure in SupportSourceReadFailure.values) {
        expect(
          SupportSourceReadException(failure: failure).toString(),
          'Support source unavailable.',
        );
      }
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'late Studio cancellation during real native await denies before full definition projection',
    () async {
      await savedStudio(instruction(repeat('x', 90000)));
      final observation = await studio(), authority = _Authority(observation);
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      final positive = await repo.toolResult(
        snapshot: snapshot,
        authority: authority,
      );
      expectNativePart(positive, jsonDecode(positive) as Map);
      f.observe();
      final sql = _AwaitActualStamp();
      final pending = f.db.runWithInterceptor(
        () => repo.read(observation: observation, authority: authority),
        interceptor: sql,
      );
      final denied = expectLater(
        pending,
        throwsA(sourceFailure(SupportSourceReadFailure.unavailable)),
      );
      try {
        await Future.any<void>([
          sql.reached.future,
          denied.then<void>(
            (_) => throw TestFailure(
              'Studio refused before actual native stamp SELECT',
            ),
          ),
        ]).timeout(const Duration(seconds: 5));
        expect(sql.stampRows.single['changes'], isA<int>());
        expect(sql.stampRows.single['version'], isA<int>());
        authority.current = false;
      } finally {
        sql.release.complete();
        await denied;
      }
      expect(sql.stampReads, 1);
      expect(sql.attemptedStudioDefinitionProjection, isFalse);
      expect(jsonEncode(f.spy.values), isNot(contains('blocks_json')));
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );

  sourceTest(
    'late cancellation during real native SQL await denies before body projection',
    () async {
      final observation = await game(), authority = _Authority(observation);
      // First prove the same native owner and exact authority genuinely admit a
      // positive body read. A memory pre-refusal cannot satisfy this control.
      final snapshot = await repo.read(
        observation: observation,
        authority: authority,
      );
      expect(
        await repo.toolResult(snapshot: snapshot, authority: authority),
        contains(SupportTextContextFixture.selected),
      );
      expect(f.db.nativeDataSourceIdentity?.belongsTo(f.db), isTrue);
      f.observe();
      final sql = _AwaitActualStamp();
      final pending = f.db.runWithInterceptor(
        () => repo.read(observation: observation, authority: authority),
        interceptor: sql,
      );
      final denied = expectLater(
        pending,
        throwsA(isA<SupportSourceReadException>()),
      );
      try {
        // An early rejection fails promptly instead of leaving a dormant gate.
        await Future.any<void>([
          sql.reached.future,
          denied.then<void>(
            (_) => throw TestFailure(
              'Read refused before real native stamp SELECT',
            ),
          ),
        ]).timeout(const Duration(seconds: 5));
        expect(sql.stampRows.single['changes'], isA<int>());
        expect(sql.stampRows.single['version'], isA<int>());
        expect(authority.current, isTrue);
        authority.current = false;
      } finally {
        sql.release.complete();
        await denied;
      }
      expect(sql.stampReads, 1);
      expect(sql.attemptedBodyProjection, isFalse);
      expect(f.spy.values, isNotEmpty);
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
      expect(
        jsonEncode(f.spy.values),
        isNot(contains(SupportTextContextFixture.selected)),
      );
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(f.spy.writes, 0);
    },
  );
}
