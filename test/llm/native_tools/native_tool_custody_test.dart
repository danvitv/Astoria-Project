import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'native_tool_fixture.dart';

void main() {
  for (final mismatch in [
    'source',
    'model',
    'endpoint',
    'protocol',
    'purpose',
    'recipient',
    'stream',
    'responses',
  ]) {
    test('original $mismatch mismatch refuses final POST', () async {
      final h = ToolHarness('openai');
      await h.store();
      final original = h.native.core.reference(NativeProviderPurpose.astoria);
      var c = h.native.core.row;
      switch (mismatch) {
        case 'source':
          c = c.copyWith(id: 'different-row');
        case 'model':
          c = c.copyWith(model: 'different-model');
        case 'endpoint':
          c = c.copyWith(endpoint: 'https://other.example/v1/chat/completions');
        case 'protocol':
          c = c.copyWith(protocol: 'anthropic');
        case 'stream':
          c = c.copyWith(stream: !c.stream);
        case 'responses':
          c = c.copyWith(useResponsesApi: true);
      }
      final session = h.session(
        config: c,
        auth: mismatch == 'purpose'
            ? h.native.core.reference(NativeProviderPurpose.roleplay)
            : original,
        approvedRecipient: mismatch == 'recipient'
            ? Uri.parse('https://other.example/v1/chat/completions')
            : null,
      );
      final result = await session.start();
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(result.status, NativeToolStatus.error);
      expect(h.native.wires, isEmpty);
      expect(h.native.legacy.requests, isEmpty);
    });
  }

  test('roleplay native credential is not borrowed for Astoria', () async {
    final h = ToolHarness('openai');
    await h.native.store(purposes: {NativeProviderPurpose.roleplay});
    final result = await h.session().start();
    expect(result.dispatch, NativeToolDispatch.notAdmitted);
    expect(h.native.wires, isEmpty);
  });

  test(
    'recipient DTO refuses query-key and userinfo routes before retaining them',
    () {
      final h = ToolHarness('gemini');
      expect(
        () => h.session(
          approvedRecipient: h.recipient.replace(query: 'key=not-a-real-key'),
        ),
        throwsA(isA<NativeToolException>()),
      );
      expect(
        () => h.session(
          approvedRecipient: Uri.parse(
            'https://user:password@other.example/v1/messages',
          ),
        ),
        throwsA(isA<NativeToolException>()),
      );
      expect(h.native.wires, isEmpty);
    },
  );

  test(
    'boolean admission alone never fabricates POST; capsule cannot be reused',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      late NativeToolDispatchCapsule original;
      final result = await h
          .session(
            admit: (capsule) async {
              original = capsule;
              return true;
            },
          )
          .start();
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, isEmpty);
      expect(original.isCurrent, isFalse);
      expect(() => original.dispatch(), throwsA(isA<NativeToolException>()));
    },
  );

  for (final boundary in ['admission', 'factory', 'current-callback']) {
    test(
      'reentrant $boundary revocation refuses actual fake/native fetch',
      () async {
        final h = ToolHarness('openai');
        await h.store();
        h.reply(h.response());
        if (boundary == 'factory') {
          h.native.onFactory = h.native.core.ordinaryMutation;
        }
        var admissionEntered = false;
        final result = await h
            .session(
              isCurrent: boundary == 'current-callback'
                  ? () {
                      if (admissionEntered) h.token.cancel();
                      return true;
                    }
                  : null,
              admit: (capsule) async {
                admissionEntered = true;
                if (boundary == 'admission') h.native.core.ordinaryMutation();
                capsule.dispatch();
                return true;
              },
            )
            .start();
        expect(result.dispatch, NativeToolDispatch.notAdmitted);
        expect(result.status, NativeToolStatus.stopped);
        expect(h.native.wires, isEmpty);
        expect(h.native.adapters.every((adapter) => adapter.closed), isTrue);
      },
    );
  }

  for (final stop in ['cancel', 'saved-source']) {
    test('$stop during original admission await prevents final POST', () async {
      final h = ToolHarness('openai');
      await h.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = h
          .session(
            admit: (capsule) async {
              entered.complete();
              await release.future;
              capsule.dispatch();
              return true;
            },
          )
          .start();
      await entered.future;
      if (stop == 'cancel') {
        h.token.cancel();
      } else {
        h.native.core.ordinaryMutation();
      }
      release.complete();
      final result = await pending;
      expect(result.status, NativeToolStatus.stopped);
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, isEmpty);
    });
  }

  test(
    'one exact saved source remains bound across continuation and cannot be renewed',
    () async {
      final h = ToolHarness('gemini');
      await h.store();
      h.reply(h.response());
      final original = h.native.core.reference(NativeProviderPurpose.astoria);
      final session = h.session(auth: original);
      final first = await session.start();
      expect(first.status, NativeToolStatus.calls);
      h.native.core.ordinaryMutation();
      h.native.core.row = h.native.core.row.copyWith(
        model: 'replacement-model',
      );
      h.native.core.reference(NativeProviderPurpose.astoria);
      final result = await session.continueWith([
        NativeToolResult(
          callId: 'call_1',
          name: 'set_theme',
          content: {'applied': 'dark'},
        ),
      ]);
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(h.native.wires, hasLength(1));
    },
  );

  test(
    'wrong/missing/duplicate result identity refuses continuation POST',
    () async {
      for (final shape in ['id', 'name', 'missing', 'duplicate']) {
        final h = ToolHarness('anthropic');
        await h.store();
        h.reply(h.response());
        final session = h.session();
        await session.start();
        final value = NativeToolResult(
          callId: shape == 'id' ? 'other' : 'call_1',
          name: shape == 'name' ? 'other' : 'set_theme',
          content: {},
        );
        final result = await session.continueWith(
          shape == 'missing'
              ? []
              : shape == 'duplicate'
              ? [value, value]
              : [value],
        );
        expect(result.dispatch, NativeToolDispatch.notAdmitted);
        expect(h.native.wires, hasLength(1));
      }
    },
  );

  test(
    'already-started fetch failure remains admittedFailed and never retries',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      h.native.fetchError = StateError(nativeCanary);
      final result = await h.session().start();
      expect(result.dispatch, NativeToolDispatch.admittedFailed);
      expect(result.reason, NativeToolReason.transport);
      expect(result.toString(), isNot(contains(nativeCanary)));
      expect(h.native.wires, hasLength(1));
    },
  );

  test(
    'later admission bool cannot erase already-started factual success',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      h.reply(h.response(tool: false));
      final result = await h
          .session(
            admit: (capsule) async {
              capsule.dispatch();
              return false;
            },
          )
          .start();
      expect(result.status, NativeToolStatus.complete);
      expect(result.dispatch, NativeToolDispatch.admitted);
      expect(h.native.wires, hasLength(1));
    },
  );

  test(
    'CancelToken reaches native adapter and stops an admitted pending response',
    () async {
      final h = ToolHarness('openai');
      await h.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.native.beforeResponse = () async {
        entered.complete();
        await release.future;
      };
      final pending = h.session().start();
      await entered.future;
      expect(identical(h.native.wires.single.cancelToken, h.token), isTrue);
      h.token.cancel();
      final result = await pending;
      release.complete();
      expect(result.dispatch, NativeToolDispatch.admittedFailed);
      expect(result.status, NativeToolStatus.stopped);
      expect(h.native.adapters.single.closed, isTrue);
    },
  );
}
