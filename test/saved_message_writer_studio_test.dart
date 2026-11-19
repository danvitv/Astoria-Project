import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

const _writer = SavedMessageWriter();
const _checkpoint = <String, dynamic>{
  'version': 1,
  'presetId': 'preset',
  'source': 'source',
  'briefs': <dynamic>[],
};
const _outputs = <Map<String, dynamic>>[
  {'id': 'think', 'name': 'Think', 'content': 'Completed thought'},
];

ChatSession _session([ChatMessage? message]) => ChatSession(
  id: 'session',
  characterId: 'character',
  sessionIndex: 0,
  sessionVars: const {'accepted': 'value'},
  messages: [
    const ChatMessage(id: 'user', role: 'user', content: 'Hello'),
    ?message,
  ],
);

ChatMessage _healthy() => ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: 'cleaned',
  reasoning: 'old reasoning',
  genTime: '2.0s',
  tokens: 20,
  time: 'old clock',
  timestamp: 1,
  swipes: const ['sibling', 'original'],
  swipeId: 1,
  continuationOffset: 2,
  studioOutputs: _outputs,
  agentSwipes: const [
    AgentSwipe(content: 'original', reasoning: 'original reasoning'),
    AgentSwipe(
      content: 'cleaned',
      kind: 'cleaned',
      parentSwipeId: 0,
      reasoning: 'old reasoning',
      genTime: '2.0s',
      tokens: 20,
      studioOutputs: _outputs,
    ),
  ],
  agentSwipeId: 1,
  swipesMeta: const [
    {
      'custom': 'untouched sibling',
      'studioWriterCheckpoint': {'source': 'sibling source'},
      'agentSwipeId': 0,
      'agentSwipes': [
        {'content': 'sibling', 'kind': 'final'},
      ],
    },
    {
      'studioWriterCheckpoint': _checkpoint,
      // Deliberately no nested snapshot: the live variants must be captured.
      'custom': 'active',
      'continuationOffset': 2,
      'guidanceText': 'old guidance',
      'guidanceType': 'SWIPE',
    },
  ],
);

void _expectActiveMirrors(ChatMessage message) {
  final active = message.agentSwipes[message.agentSwipeId];
  final meta = message.swipesMeta[message.swipeId];
  expect(message.swipes[message.swipeId], message.content);
  expect(active.content, message.content);
  expect(active.reasoning, message.reasoning);
  expect(active.genTime, message.genTime);
  expect(active.tokens, message.tokens);
  expect(active.time, message.time);
  expect(active.studioOutputs, message.studioOutputs);
  expect(meta['reasoning'], message.reasoning);
  expect(meta['genTime'], message.genTime);
  expect(meta['tokens'], message.tokens);
  expect(meta['time'], message.time);
  expect(meta['studioOutputs'], message.studioOutputs);
  expect(meta['agentSwipeId'], message.agentSwipeId);
  expect(
    meta['agentSwipes'],
    message.agentSwipes.map((e) => e.toJson()).toList(),
  );
  expect(active.toJson().containsKey('studioWriterCheckpoint'), isFalse);
}

void main() {
  test('new success stores a checkpoint only on its outer swipe', () {
    final state = _writer.writeAssistant(
      text: 'reply',
      reasoning: 'Think reasoning',
      currentSession: _session(),
      isAborted: () => false,
      studioWriterCheckpoint: _checkpoint,
      studioOutputs: _outputs,
      pendingSessionVars: const {'accepted': 'next'},
      memoryCoverage: const {'diagnostics': 'ephemeral', 'durable': true},
      rawResponse: 'raw',
      visibleStartIndex: 4,
    );
    final message = state.session!.messages.last;
    expect(message.swipesMeta.single['studioWriterCheckpoint'], _checkpoint);
    expect(
      message.agentSwipes.single.toJson().containsKey('studioWriterCheckpoint'),
      isFalse,
    );
    expect(message.memoryCoverage, {'durable': true});
    expect(state.session!.sessionVars, {'accepted': 'next'});
    expect(state.lastRawResponse, 'raw');
    expect(state.visibleStartIndex, 4);
    expect(state.isGenerating, isFalse);
  });

  test('full regen checkpoint is bound to the new outer, not its sibling', () {
    final original = _healthy();
    final message = _writer
        .writeAssistant(
          text: 'new full reply',
          reasoning: null,
          currentSession: _session(original),
          isAborted: () => false,
          regenTargetId: original.id,
          previousSwipes: original.swipes,
          previousSwipeId: original.swipeId,
          previousSwipesMeta: original.swipesMeta,
          studioWriterCheckpoint: const {'source': 'new source'},
        )
        .session!
        .messages
        .last;
    expect(message.swipes, ['sibling', 'original', 'new full reply']);
    expect(message.swipeId, 2);
    expect(message.agentSwipes.single.content, 'new full reply');
    expect(message.swipesMeta[0], original.swipesMeta[0]);
    expect(message.swipesMeta[1], original.swipesMeta[1]);
    expect(message.swipesMeta[2]['studioWriterCheckpoint'], {
      'source': 'new source',
    });
  });

  test('final-only appends a final and synchronizes the selected outer', () {
    final original = _healthy();
    final session = _session(original);
    final before = jsonEncode(session.toJson());
    final state = _writer.writeAssistant(
      text: 'new final',
      reasoning: 'new reasoning',
      currentSession: session,
      isAborted: () => false,
      regenTargetId: original.id,
      studioFinalOnly: true,
      studioOutputs: _outputs,
      genTime: '3.0s',
      tokens: 30,
      time: 'new clock',
      // These full-regen inputs must not create or select another outer.
      previousSwipes: const ['wrong'],
      previousSwipeId: 0,
      previousSwipesMeta: const [
        {'wrong': true},
      ],
      visibleStartIndex: 3,
    );
    final message = state.session!.messages.last;
    expect(message.swipes, ['sibling', 'new final']);
    expect(message.swipeId, 1);
    expect(message.agentSwipes.map((e) => e.content), [
      'original',
      'cleaned',
      'new final',
    ]);
    expect(message.agentSwipes.last.kind, 'final');
    expect(message.agentSwipeId, 2);
    expect(message.agentSwipes[1].parentSwipeId, 0);
    expect(message.agentSwipes[1].time, 'old clock');
    expect(message.swipesMeta[0], original.swipesMeta[0]);
    expect(message.swipesMeta[1]['studioWriterCheckpoint'], _checkpoint);
    expect(message.swipesMeta[1]['custom'], 'active');
    expect(message.swipesMeta[1]['isError'], isFalse);
    expect(message.swipesMeta[1]['guidanceText'], isNull);
    expect(message.continuationOffset, isNull);
    expect(message.timestamp, greaterThan(1));
    expect(state.regenTargetId, original.id);
    expect(state.visibleStartIndex, 3);
    expect(state.isGenerating, isFalse);
    _expectActiveMirrors(message);
    expect(jsonEncode(session.toJson()), before);
  });

  test('final-only backfills healthy legacy content with its own metadata', () {
    const original = ChatMessage(
      id: 'assistant',
      role: 'assistant',
      content: 'legacy',
      reasoning: 'legacy reasoning',
      genTime: '1.0s',
      tokens: 10,
      time: 'legacy clock',
      studioOutputs: _outputs,
    );
    final message = _writer
        .writeAssistant(
          text: 'next',
          reasoning: null,
          currentSession: _session(original),
          isAborted: () => false,
          regenTargetId: original.id,
          studioFinalOnly: true,
          studioWriterCheckpoint: _checkpoint,
        )
        .session!
        .messages
        .last;
    expect(message.swipes, ['next']);
    expect(message.agentSwipes.length, 2);
    final previous = message.agentSwipes.first;
    expect(previous.content, 'legacy');
    expect(previous.reasoning, 'legacy reasoning');
    expect(previous.genTime, '1.0s');
    expect(previous.tokens, 10);
    expect(previous.time, 'legacy clock');
    expect(previous.studioOutputs, _outputs);
    expect(message.swipesMeta.single['studioWriterCheckpoint'], _checkpoint);
    _expectActiveMirrors(message);
  });

  for (final errorFlag in [true, false]) {
    test('final-only replaces an error marked on its outer ($errorFlag)', () {
      final original = _healthy().copyWith(
        content: 'writer failed',
        swipes: const ['sibling', 'writer failed'],
        isError: errorFlag,
        swipesMeta: [
          _healthy().swipesMeta.first,
          {'isError': true, 'studioWriterCheckpoint': _checkpoint},
        ],
      );
      final message = _writer
          .writeAssistant(
            text: 'recovered',
            reasoning: 'completed Think',
            currentSession: _session(original),
            isAborted: () => false,
            regenTargetId: original.id,
            studioFinalOnly: true,
            studioOutputs: _outputs,
          )
          .session!
          .messages
          .last;
      expect(message.swipes, ['sibling', 'recovered']);
      expect(message.swipeId, 1);
      expect(message.agentSwipes.single.content, 'recovered');
      expect(message.agentSwipes.single.kind, 'final');
      expect(message.agentSwipeId, 0);
      expect(message.isError, isFalse);
      expect(message.swipesMeta.first, original.swipesMeta.first);
      expect(message.swipesMeta.last['studioWriterCheckpoint'], _checkpoint);
      _expectActiveMirrors(message);
    });
  }

  test(
    'aborted and missing-target final-only writes leave the session intact',
    () {
      final session = _session(_healthy());
      for (final aborted in [true, false]) {
        final state = _writer.writeAssistant(
          text: 'must not persist',
          reasoning: 'must not persist',
          currentSession: session,
          isAborted: () => aborted,
          regenTargetId: aborted ? 'assistant' : 'missing',
          studioFinalOnly: true,
          studioWriterCheckpoint: _checkpoint,
          pendingSessionVars: const {'bad': 'delta'},
          visibleStartIndex: 3,
        );
        expect(state.session, same(session));
        expect(state.isGenerating, isFalse);
        expect(state.visibleStartIndex, 3);
      }
    },
  );

  test(
    'error display retains completed Think only with a supplied checkpoint',
    () {
      for (final checkpoint in [null, _checkpoint]) {
        final session = _session();
        final state = _writer.writeError(
          errorText: 'writer failed',
          currentSession: session,
          studioWriterCheckpoint: checkpoint,
          studioOutputs: _outputs,
          reasoning: 'completed Think',
          visibleStartIndex: 2,
        );
        final message = state.session!.messages.last;
        expect(message.isError, isTrue);
        expect(message.content, 'writer failed');
        expect(message.agentSwipes, isEmpty);
        expect(
          message.reasoning,
          checkpoint == null ? null : 'completed Think',
        );
        expect(message.studioOutputs, checkpoint == null ? isEmpty : _outputs);
        expect(message.swipesMeta.single['studioWriterCheckpoint'], checkpoint);
        expect(state.session!.sessionVars, session.sessionVars);
        expect(state.visibleStartIndex, 2);
        expect(state.isGenerating, isFalse);
        if (checkpoint == null) {
          expect(message.swipesMeta.single, {'isError': true});
        } else {
          expect(message.swipesMeta.single['reasoning'], 'completed Think');
          expect(message.swipesMeta.single['studioOutputs'], _outputs);
        }
      }
    },
  );

  test(
    'failed full regen snapshots healthy nested siblings under their outer',
    () {
      final original = _healthy();
      final session = _session(original);
      final before = jsonEncode(session.toJson());
      final state = _writer.writeRegenError(
        errorText: 'new writer failed',
        saveSession: session,
        regenTargetId: original.id,
        studioWriterCheckpoint: const {'source': 'failed source'},
        studioOutputs: _outputs,
        reasoning: 'completed new Think',
        guidanceText: 'new guidance',
        guidanceType: 'SWIPE',
      );
      final message = state.session!.messages.last;
      expect(message.swipes, ['sibling', 'original', 'new writer failed']);
      expect(message.swipeId, 2);
      expect(message.agentSwipes, isEmpty);
      expect(message.agentSwipeId, 0);
      expect(message.reasoning, 'completed new Think');
      expect(message.studioOutputs, _outputs);
      expect(message.guidanceText, 'new guidance');
      expect(message.guidanceType, 'SWIPE');
      expect(message.genTime, isNull);
      expect(message.tokens, isNull);
      expect(message.time, isNull);
      expect(message.swipesMeta.first, original.swipesMeta.first);
      final healthyMeta = message.swipesMeta[1];
      expect(healthyMeta['isError'], isNot(true));
      expect(healthyMeta['studioWriterCheckpoint'], _checkpoint);
      expect(healthyMeta['guidanceText'], 'old guidance');
      expect(healthyMeta['guidanceType'], 'SWIPE');
      expect(healthyMeta['agentSwipeId'], 1);
      final nested = (healthyMeta['agentSwipes'] as List)
          .map((e) => AgentSwipe.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      expect(nested.map((e) => e.content), ['original', 'cleaned']);
      expect(nested[1].reasoning, 'old reasoning');
      expect(nested[1].time, 'old clock');
      expect(nested[1].parentSwipeId, 0);
      final errorMeta = message.swipesMeta.last;
      expect(errorMeta['studioWriterCheckpoint'], {'source': 'failed source'});
      expect(errorMeta['agentSwipes'], isNull);
      expect(errorMeta['guidanceText'], 'new guidance');
      expect(errorMeta['guidanceType'], 'SWIPE');
      expect(state.session!.sessionVars, session.sessionVars);
      expect(jsonEncode(session.toJson()), before);

      final retried = _writer
          .writeAssistant(
            text: 'recovered',
            reasoning: message.reasoning,
            currentSession: state.session!,
            isAborted: () => false,
            regenTargetId: message.id,
            studioFinalOnly: true,
            studioOutputs: message.studioOutputs,
            guidanceText: message.guidanceText,
            guidanceType: message.guidanceType,
          )
          .session!
          .messages
          .last;
      expect(retried.swipes, ['sibling', 'original', 'recovered']);
      expect(retried.swipesMeta.take(2), message.swipesMeta.take(2));
      expect(retried.swipesMeta.last['studioWriterCheckpoint'], {
        'source': 'failed source',
      });
      expect(retried.guidanceText, 'new guidance');
      expect(retried.agentSwipes.single.content, 'recovered');
      expect(retried.isError, isFalse);
    },
  );

  test('regen error fallback forwards checkpoint and Think display', () {
    final message = _writer
        .writeRegenError(
          errorText: 'writer failed',
          saveSession: _session(),
          regenTargetId: 'missing',
          studioWriterCheckpoint: _checkpoint,
          studioOutputs: _outputs,
          reasoning: 'completed Think',
          guidanceText: 'composer guidance',
        )
        .session!
        .messages
        .last;
    expect(message.reasoning, 'completed Think');
    expect(message.studioOutputs, _outputs);
    expect(message.guidanceText, 'composer guidance');
    expect(message.guidanceType, 'GENERATION');
    expect(message.swipesMeta.single['guidanceText'], 'composer guidance');
    expect(message.swipesMeta.single['guidanceType'], 'GENERATION');
    expect(message.swipesMeta.single['studioWriterCheckpoint'], _checkpoint);
    expect(message.isError, isTrue);
  });
}
