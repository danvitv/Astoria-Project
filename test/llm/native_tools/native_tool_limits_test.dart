import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'native_tool_fixture.dart';

void main() {
  test('request token limit refuses before admission/POST', () async {
    final h = ToolHarness('openai');
    await h.store();
    final result = await h
        .session(
          config: h.native.core.row.copyWith(
            maxTokens: NativeToolLimits.maxOutputTokens + 1,
          ),
        )
        .start();
    expect(result.reason, NativeToolReason.invalidRequest);
    expect(result.dispatch, NativeToolDispatch.notAdmitted);
    expect(h.native.wires, isEmpty);
  });

  test(
    'UTF8 request byte ceiling refuses without clipping original transcript',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      final messages = List.generate(
        4,
        (_) => NativeToolMessage(
          role: NativeToolRole.user,
          text: List.filled(32767, '😺').join(),
        ),
      );
      // Leave room for JSON quotes without hitting a per-message limit.
      for (final message in messages) {
        expect(
          jsonEncode(message.text).length,
          lessThanOrEqualTo(NativeToolLimits.textCharacters),
        );
      }
      expect(
        messages.fold<int>(0, (total, message) => total + message.text.length),
        lessThan(NativeToolLimits.contextCharacters),
      );
      final result = await h.session(messages: messages).start();
      expect(result.reason, NativeToolReason.limit);
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, isEmpty);
    },
  );

  test(
    'response byte limit refuses typed calls and force-closes native adapter',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      h.native.response = List.filled(
        NativeToolLimits.responseBytes + 1,
        'x',
      ).join();
      final result = await h.session().start();
      expect(result.reason, NativeToolReason.limit);
      expect(result.calls, isEmpty);
      expect(result.dispatch, NativeToolDispatch.admittedFailed);
      expect(h.native.adapters.single.closed, isTrue);
    },
  );

  test(
    'oversized returned output and provider-reported output refuse before execution',
    () async {
      for (final shape in ['text', 'tokens']) {
        final h = ToolHarness('openai');
        await h.store();
        h.reply(
          h.response(
            tool: shape == 'tokens',
            prose: shape == 'text'
                ? List.filled(NativeToolLimits.textCharacters + 1, 'x').join()
                : null,
            outputTokens: shape == 'tokens'
                ? h.native.core.row.maxTokens + 1
                : 5,
          ),
        );
        final result = await h.session().start();
        expect(result.reason, NativeToolReason.limit);
        expect(result.calls, isEmpty);
        expect(result.dispatch, NativeToolDispatch.admittedFailed);
      }
    },
  );

  test(
    'JSON depth/node ceilings bound provider parsing and caller arguments',
    () async {
      Map<String, Object?> object = {};
      for (var i = 0; i <= NativeToolLimits.jsonDepth; i++) {
        object = {'nested': object};
      }
      expect(
        () => NativeToolCall(id: 'c', name: 'set_theme', arguments: object),
        throwsA(isA<NativeToolException>()),
      );
      expect(
        () => NativeToolResult(
          callId: 'c',
          name: 'set_theme',
          content: {'many': List.filled(NativeToolLimits.jsonNodes + 1, 0)},
        ),
        throwsA(isA<NativeToolException>()),
      );
      final h = ToolHarness('openai');
      await h.store();
      h.native.response =
          '${List.filled(NativeToolLimits.responseDepth + 1, '[').join()}0'
          '${List.filled(NativeToolLimits.responseDepth + 1, ']').join()}';
      expect((await h.session().start()).reason, NativeToolReason.limit);
    },
  );

  test(
    'finite rounds retain full original history and refuse ninth POST',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      final session = h.session();
      NativeToolTurn? turn;
      for (var i = 0; i < NativeToolLimits.rounds; i++) {
        h.reply(h.response(id: 'call_$i'));
        turn = i == 0
            ? await session.start()
            : await session.continueWith([
                NativeToolResult(
                  callId: 'call_${i - 1}',
                  name: 'set_theme',
                  content: {'round': i},
                ),
              ]);
        expect(turn.status, NativeToolStatus.calls);
      }
      expect(
        h.native.wires.last.body['messages'],
        hasLength(1 + 2 * (NativeToolLimits.rounds - 1)),
      );
      final rejected = await session.continueWith([
        NativeToolResult(
          callId: turn!.calls.single.id,
          name: 'set_theme',
          content: {},
        ),
      ]);
      expect(rejected.reason, NativeToolReason.limit);
      expect(rejected.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, hasLength(NativeToolLimits.rounds));
    },
  );

  test(
    'single overall deadline covers the gap spent executing app results',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      h.reply(h.response());
      final session = h.session();
      expect((await session.start()).status, NativeToolStatus.calls);
      h.expire!();
      final result = await session.continueWith([
        NativeToolResult(callId: 'call_1', name: 'set_theme', content: {}),
      ]);
      expect(result.reason, NativeToolReason.deadline);
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, hasLength(1));
    },
  );

  test(
    'session call ceiling refuses an entire fifth eight-call batch before execution',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      final session = h.session();
      NativeToolTurn? previous;
      for (var round = 0; round < 5; round++) {
        final response = h.response();
        final message = (response['choices'] as List)[0]['message'] as Map;
        final original = (message['tool_calls'] as List).single as Map;
        message['tool_calls'] = List.generate(
          NativeToolLimits.callsPerTurn,
          (index) => {...original, 'id': 'call_${round}_$index'},
        );
        h.reply(response);
        final turn = previous == null
            ? await session.start()
            : await session.continueWith(
                previous.calls
                    .map(
                      (c) => NativeToolResult(
                        callId: c.id,
                        name: c.name,
                        content: {},
                      ),
                    )
                    .toList(),
              );
        if (round < 4) {
          expect(turn.status, NativeToolStatus.calls);
          previous = turn;
        } else {
          expect(turn.reason, NativeToolReason.limit);
          expect(turn.calls, isEmpty);
          expect(turn.dispatch, NativeToolDispatch.admittedFailed);
        }
      }
      expect(h.native.wires, hasLength(5));
    },
  );

  test(
    'HTTP redirect/status metadata never becomes a retry or output',
    () async {
      for (final status in [302, 408, 429, 500]) {
        final h = ToolHarness('openai');
        await h.store();
        h.native.status = status;
        h.native.response = nativeCanary;
        final result = await h.session().start();
        expect(result.reason, NativeToolReason.httpStatus);
        expect(result.text, isEmpty);
        expect(h.native.wires, hasLength(1));
        expect(h.native.adapters.single.closed, isTrue);
      }
    },
  );
}
