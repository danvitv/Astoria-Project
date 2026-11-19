import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_writer_checkpoint.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/studio_writer_pending.dart';

const _ownerId = 'run-owner';
const _guidance = 'Answer briefly.';
const _interrupted = 'Writer interrupted';
const _pendingKey = StudioWriterCheckpoint.pendingSessionKey;
const _user = ChatMessage(id: 'u', role: 'user', content: 'Open the gate.');
const _prompt = ChatSession(
  id: 'session',
  characterId: 'character',
  sessionIndex: 0,
  messages: [_user],
  sessionVars: {'unrelated': 'keep me'},
);

StudioWriterCheckpoint _checkpoint() => StudioWriterCheckpoint(
  presetId: 'preset',
  source: StudioWriterCheckpoint.sourceFor(_prompt, _guidance),
  phaseInputs: 'phase fingerprint',
  briefs: const [
    StudioStageBrief(
      agentId: 'think',
      agentName: 'Think',
      brief: '<audit>The gate is locked.</audit>',
      nativeReasoning: 'Check the gate.',
      isThinkReplacement: true,
    ),
  ],
);

ChatSession _withPending(ChatSession base, {String? targetId}) {
  final pending = StudioWriterPending.capture(
    ownerId: _ownerId,
    baseSession: base,
    targetId: targetId,
    guidanceText: _guidance,
    guidanceType: targetId == null ? 'GENERATION' : 'SWIPE',
    checkpoint: _checkpoint(),
  )!;
  return base.copyWith(
    sessionVars: {...base.sessionVars, _pendingKey: pending.encode()},
  );
}

void main() {
  test('checkpoint preserves the full-regeneration context projection', () {
    final checkpoint = StudioWriterCheckpoint(
      presetId: 'preset',
      source: 'source',
      phaseInputs: 'phase fingerprint',
      excludeSnapshotMessageId: 'replaced-message',
      briefs: const [],
    );

    final decoded = StudioWriterCheckpoint.fromJson(checkpoint.toJson());
    expect(decoded?.excludeSnapshotMessageId, 'replaced-message');
    expect(decoded?.toJson(), checkpoint.toJson());
  });

  test(
    'orphaned new turn promotes one retryable variation and clears slot',
    () {
      final recovered = StudioWriterPending.recover(
        _withPending(_prompt),
        interruptedText: _interrupted,
      )!;

      expect(recovered.sessionVars, _prompt.sessionVars);
      expect(recovered.messages, hasLength(2));
      expect(recovered.messages.first, _user);
      final reply = recovered.messages.last;
      expect(reply.content, _interrupted);
      expect(reply.isError, isTrue);
      expect(reply.swipeId, 0);
      expect(reply.guidanceText, _guidance);
      expect(
        reply.reasoning,
        allOf(contains('The gate is locked.'), contains('Check the gate.')),
      );
      expect(
        StudioWriterCheckpoint.forMessage(reply)?.toJson(),
        _checkpoint().toJson(),
      );
      expect(
        StudioWriterPending.recover(recovered, interruptedText: _interrupted),
        isNull,
      );
    },
  );

  test('Stop on full regen preserves existing outer and nested siblings', () {
    const nested = [
      AgentSwipe(content: 'Current writer text'),
      AgentSwipe(content: 'Current clean text', kind: 'cleaned'),
    ];
    final selectedMeta = <String, dynamic>{
      'agentSwipes': nested.map((swipe) => swipe.toJson()).toList(),
      'agentSwipeId': 1,
    };
    const siblingMeta = {'guidanceText': 'Sibling instruction'};
    final original = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: nested.last.content,
      swipes: const ['Earlier writer text', 'Current writer text'],
      swipeId: 1,
      swipesMeta: [siblingMeta, selectedMeta],
      agentSwipes: nested,
      agentSwipeId: 1,
    );
    final base = _prompt.copyWith(messages: [_user, original]);
    final durable = _withPending(base, targetId: original.id);
    final recovered = StudioWriterPending.recover(
      durable,
      ownerId: _ownerId,
      interruptedText: _interrupted,
      partialText: 'The writer began...',
      partialReasoning: 'Streamed writer reasoning',
    )!;

    expect(recovered.sessionVars, _prompt.sessionVars);
    expect(recovered.messages, hasLength(2));
    final reply = recovered.messages.last;
    expect(reply.id, original.id);
    expect(reply.swipeId, 2);
    expect(reply.swipes, [...original.swipes, 'The writer began...']);
    expect(reply.swipesMeta[0], siblingMeta);
    expect(reply.swipesMeta[1]['agentSwipes'], selectedMeta['agentSwipes']);
    expect(reply.swipesMeta[1]['agentSwipeId'], 1);
    expect(reply.agentSwipes, isEmpty);
    expect(reply.isError, isTrue);
    expect(reply.reasoning, 'Streamed writer reasoning');
    expect(reply.guidanceType, 'SWIPE');
    expect(
      StudioWriterCheckpoint.forMessage(reply)?.toJson(),
      _checkpoint().toJson(),
    );

    final switched = original.copyWith(
      swipeId: 0,
      content: 'Earlier writer text',
    );
    final wrongTarget = durable.copyWith(messages: [_user, switched]);
    final discarded = StudioWriterPending.recover(
      wrongTarget,
      interruptedText: _interrupted,
    )!;
    expect(discarded.messages, wrongTarget.messages);
    expect(discarded.sessionVars, _prompt.sessionVars);
  });

  test('newer owner is untouched; changed history discards only its slot', () {
    final durable = _withPending(_prompt);
    expect(
      StudioWriterPending.recover(
        durable,
        ownerId: 'stale-owner',
        interruptedText: _interrupted,
      ),
      isNull,
    );
    expect(
      StudioWriterPending.owns(durable.sessionVars[_pendingKey], _ownerId),
      isTrue,
    );

    final edited = durable.copyWith(
      messages: [_user.copyWith(content: 'Wait.')],
    );
    final discarded = StudioWriterPending.recover(
      edited,
      ownerId: _ownerId,
      interruptedText: _interrupted,
      partialText: 'Stale writer text',
    )!;
    expect(discarded.messages, edited.messages);
    expect(discarded.sessionVars, _prompt.sessionVars);
  });
}
