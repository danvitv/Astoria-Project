import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../llm/native_tools/native_tool_fixture.dart';

/// Reuses the existing synthetic adapter/vault. No ordinary key-slot reads,
/// platform storage, provider requests, database, environment or app composition.
final class _LegacyTools {
  _LegacyTools(String protocol) : h = ToolHarness(protocol) {
    h.native.core.row =
        (protocol == 'gemini'
                ? nativeTransportRow(protocol, stream: false)
                : h.native.core.row)
            .copyWith(apiKey: nativeCanary);
  }
  final ToolHarness h;

  NativeToolRequest request({
    ApiConfig? config,
    NativeConnectionStamp? sourceStamp,
    Uri? recipient,
    List<NativeToolMessage>? messages,
  }) {
    final c = config ?? h.native.core.row;
    return NativeToolRequest.legacySaved(
      config: c,
      sourceStamp: sourceStamp ?? h.native.core.mutations.observe()!,
      approvedRecipient: recipient ?? Uri.parse(c.endpoint),
      tools: h.tools,
      messages:
          messages ??
          [
            NativeToolMessage(
              role: NativeToolRole.user,
              text: 'Use a dark theme',
            ),
          ],
    );
  }

  NativeToolSession session({
    NativeToolRequest? input,
    NativeToolAdmission? admit,
    bool Function()? isCurrent,
  }) {
    final original = h.native.core.row;
    return h.transport.open(
      request: input ?? request(),
      cancelToken: h.token,
      isCurrent: isCurrent ?? () => h.current,
      beforeWire:
          admit ??
          (capsule) async {
            // Synthetic original ROOT, not a tool/model-supplied approval. Recheck
            // the SAME full saved row and fresh native absence, then sync dispatch.
            final presence = await h.native.core.credentials
                .inspectNativePresence(
                  connectionId: original.id,
                  isCurrent: () => h.current && capsule.isCurrent,
                );
            if (!h.current ||
                h.native.core.row != original ||
                presence != NativeProviderCredentialPresence.absent ||
                !capsule.isCurrent ||
                capsule.handoff.recipient.toString() != original.endpoint ||
                capsule.handoff.protocol != original.protocol ||
                capsule.handoff.model != original.model) {
              return false;
            }
            capsule.dispatch();
            return true;
          },
    );
  }

  // Prepare only fake fixture bytes before a session exists. Optionally retain
  // them off-slot to simulate a changed backend without a same-process fence.
  Future<String?> seed(String state, {bool install = true}) async {
    final core = h.native.core;
    final original = core.row;
    switch (state) {
      case 'present':
        core.row = original.copyWith(apiKey: '');
        await h.store();
        core.row = original;
      case 'corrupt':
        core.storage.values[core.nativeStorageKey] = 'synthetic-corrupt';
      case 'prepared':
        await core.genericVault.store(
          core.preparationSlot,
          jsonEncode({
            'v': 1,
            'kind': 'keyless-native-preparation',
            'connectionId': original.id,
          }),
        );
      case 'unavailable':
        core.storage.readError = StateError(nativeCanary);
    }
    final key = state == 'prepared'
        ? core.preparationStorageKey
        : core.nativeStorageKey;
    final encoded = core.storage.values[key];
    if (!install) core.storage.values.remove(key);
    core.storage.writeKeys.clear();
    core.storage.deleteKeys.clear();
    return encoded;
  }

  void expectNoVaultMutation() {
    expect(h.native.core.storage.writeKeys, isEmpty);
    expect(h.native.core.storage.deleteKeys, isEmpty);
    expect(h.native.legacy.requests, isEmpty);
  }
}

List<NativeToolResult> _applied({
  String value = 'dark',
  String id = 'call_1',
}) => [
  NativeToolResult(callId: id, name: 'set_theme', content: {'applied': value}),
];

void main() {
  for (final protocol in nativeTransportProtocols) {
    test(
      '$protocol legacy saved-row tools use correlated JSON rounds and actual usage',
      () async {
        final f = _LegacyTools(protocol);
        final h = f.h;
        final request = f.request();
        expect(request.savedConnectionAuth, isNull);
        expect(request.config.apiKey, isEmpty);
        expect(
          jsonEncode(request.config.toJson()),
          isNot(contains(nativeCanary)),
        );
        h.reply(h.response());
        final session = f.session(input: request);
        final first = await session.start();
        expect(first.status, NativeToolStatus.calls);
        expect(first.dispatch, NativeToolDispatch.admitted);
        expect(first.calls.single.id, 'call_1');
        expect(first.calls.single.arguments, {'value': 'dark'});
        expect(first.actualUsage?.inputTokens, 11);
        expect(first.actualUsage?.cachedInputTokens, 3);
        h.reply(h.response(tool: false));
        final last = await session.continueWith(_applied());
        expect(last.status, NativeToolStatus.complete);
        expect(last.dispatch, NativeToolDispatch.admitted);
        expect(last.text, 'Theme is dark.');
        expect(last.calls, isEmpty);
        expect(last.actualUsage?.outputTokens, 5);
        expect(
          last.actualUsage?.totalTokens,
          protocol == 'anthropic' ? null : 16,
        );
        expect(h.native.wires, hasLength(2));
        final wire = h.native.wires.last;
        expect(wire.uri.toString(), h.native.core.row.endpoint);
        expect(wire.method, 'POST');
        expect(identical(wire.cancelToken, h.token), isTrue);
        expect(wire.headers['Content-Type'], 'application/json');
        final authHeader = protocol == 'anthropic'
            ? 'x-api-key'
            : protocol == 'gemini'
            ? 'x-goog-api-key'
            : 'Authorization';
        expect(
          wire.headers[authHeader],
          protocol == 'anthropic' || protocol == 'gemini'
              ? nativeCanary
              : 'Bearer $nativeCanary',
        );
        final body = wire.body;
        switch (protocol) {
          case 'openai_responses':
            expect(body['store'], isFalse);
            expect(body['input'][2]['call_id'], 'call_1');
            expect(jsonDecode(body['input'][2]['output'] as String), {
              'applied': 'dark',
            });
          case 'anthropic':
            expect(
              body['messages'][1]['content'][0]['signature'],
              'native_signature',
            );
            expect(body['messages'][2]['content'][0]['tool_use_id'], 'call_1');
            expect(
              jsonDecode(
                body['messages'][2]['content'][0]['content'] as String,
              ),
              {'applied': 'dark'},
            );
          case 'gemini':
            expect(
              body['contents'][1]['parts'][0]['thoughtSignature'],
              'native_thought_signature',
            );
            expect(body['contents'][2]['parts'][0]['functionResponse'], {
              'id': 'call_1',
              'name': 'set_theme',
              'response': {'applied': 'dark'},
            });
          default:
            expect(body['messages'][1]['tool_calls'][0]['id'], 'call_1');
            expect(body['messages'][2]['tool_call_id'], 'call_1');
            expect(jsonDecode(body['messages'][2]['content'] as String), {
              'applied': 'dark',
            });
        }
        expect(jsonEncode(body), isNot(contains(nativeCanary)));
        expect(last.toString(), isNot(contains(nativeCanary)));
        expect(h.native.adapters.every((adapter) => adapter.closed), isTrue);
        expect(h.native.core.storage.readKeys, isNotEmpty);
        expect(
          h.native.core.storage.readKeys.toSet().difference({
            h.native.core.nativeStorageKey,
            h.native.core.preparationStorageKey,
          }),
          isEmpty,
        );
        f.expectNoVaultMutation();
      },
    );
  }

  test(
    'legacy custom recipient is exact saved ordinary route, not native destination approval',
    () async {
      final f = _LegacyTools('custom_chat_completion');
      f.h.native.core.row = f.h.native.core.row.copyWith(
        endpoint: 'https://synthetic.example/selected/llm',
      );
      f.h.reply(f.h.response(tool: false));
      expect((await f.session().start()).status, NativeToolStatus.complete);
      expect(
        f.h.native.wires.single.uri.toString(),
        f.h.native.core.row.endpoint,
      );
      f.expectNoVaultMutation();
    },
  );

  for (final state in ['present', 'corrupt', 'prepared', 'unavailable']) {
    test(
      '$state native slot denies legacy first wire without mutation/fallback',
      () async {
        final f = _LegacyTools('openai');
        await f.seed(state);
        final result = await f.session().start();
        expect(result.dispatch, NativeToolDispatch.notAdmitted);
        expect(result.reason, NativeToolReason.denied);
        expect(f.h.native.wires, isEmpty);
        expect(result.toString(), isNot(contains(nativeCanary)));
        f.expectNoVaultMutation();
      },
    );
    test(
      '$state native slot is freshly checked before legacy continuation',
      () async {
        final f = _LegacyTools('openai');
        final encoded = state == 'unavailable'
            ? null
            : await f.seed(state, install: false);
        f.h.reply(f.h.response());
        final session = f.session();
        expect((await session.start()).status, NativeToolStatus.calls);
        final core = f.h.native.core;
        if (state == 'unavailable') {
          core.storage.readError = StateError(nativeCanary);
        } else {
          core.storage.values[state == 'prepared'
                  ? core.preparationStorageKey
                  : core.nativeStorageKey] =
              encoded!;
        }
        final result = await session.continueWith(_applied());
        expect(result.dispatch, NativeToolDispatch.notAdmitted);
        expect(result.reason, NativeToolReason.denied);
        expect(f.h.native.wires, hasLength(1));
        f.expectNoVaultMutation();
      },
    );
  }

  for (final stop in ['cancel', 'current', 'source-fence']) {
    test(
      'legacy $stop during original admission await prevents POST',
      () async {
        final f = _LegacyTools('openai');
        final entered = Completer<void>();
        final release = Completer<void>();
        final pending = f
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
        switch (stop) {
          case 'cancel':
            f.h.token.cancel();
          case 'current':
            f.h.current = false;
          case 'source-fence':
            f.h.native.core.ordinaryMutation();
        }
        release.complete();
        final result = await pending;
        expect(result.status, NativeToolStatus.stopped);
        expect(result.dispatch, NativeToolDispatch.notAdmitted);
        expect(f.h.native.wires, isEmpty);
        f.expectNoVaultMutation();
      },
    );
    test('legacy $stop between rounds cannot renew original source', () async {
      final f = _LegacyTools('openai');
      f.h.reply(f.h.response());
      final session = f.session();
      expect((await session.start()).status, NativeToolStatus.calls);
      switch (stop) {
        case 'cancel':
          f.h.token.cancel();
        case 'current':
          f.h.current = false;
        case 'source-fence':
          f.h.native.core.ordinaryMutation();
      }
      final result = await session.continueWith(_applied());
      expect(result.status, NativeToolStatus.stopped);
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(f.h.native.wires, hasLength(1));
      f.expectNoVaultMutation();
    });
  }

  test(
    'legacy original mutation stamp cannot rebase after ABA or cross owners',
    () async {
      for (final foreign in [false, true]) {
        final f = _LegacyTools('openai');
        final request = f.request(
          sourceStamp: foreign
              ? _LegacyTools('openai').h.native.core.mutations.observe()
              : null,
        );
        if (!foreign) f.h.native.core.ordinaryMutation();
        final result = await f.session(input: request).start();
        expect(result.reason, NativeToolReason.notCurrent);
        expect(f.h.native.wires, isEmpty);
        f.expectNoVaultMutation();
      }
    },
  );

  test('legacy adapter factory revocation prevents actual fetch', () async {
    final f = _LegacyTools('openai');
    f.h.native.onFactory = f.h.native.core.ordinaryMutation;
    final result = await f.session().start();
    expect(result.status, NativeToolStatus.stopped);
    expect(result.dispatch, NativeToolDispatch.notAdmitted);
    expect(f.h.native.wires, isEmpty);
    expect(f.h.native.adapters.single.closed, isTrue);
    f.expectNoVaultMutation();
  });

  test(
    'legacy ROOT rejects a changed saved row without recipient substitution',
    () async {
      final f = _LegacyTools('openai');
      final session = f.session();
      f.h.native.core.row = f.h.native.core.row.copyWith(
        model: 'replacement-model',
      );
      final result = await session.start();
      expect(result.dispatch, NativeToolDispatch.notAdmitted);
      expect(f.h.native.wires, isEmpty);
      f.expectNoVaultMutation();
    },
  );

  test(
    'legacy cancel token stops admitted pending response and closes adapter',
    () async {
      final f = _LegacyTools('openai');
      final entered = Completer<void>();
      final release = Completer<void>();
      f.h.native.beforeResponse = () async {
        entered.complete();
        await release.future;
      };
      final pending = f.session().start();
      await entered.future;
      expect(identical(f.h.native.wires.single.cancelToken, f.h.token), isTrue);
      f.h.token.cancel();
      final result = await pending;
      release.complete();
      expect(result.status, NativeToolStatus.stopped);
      expect(result.dispatch, NativeToolDispatch.admittedFailed);
      expect(f.h.native.adapters.single.closed, isTrue);
      f.expectNoVaultMutation();
    },
  );

  for (final location in ['prompt', 'arguments', 'response', 'result']) {
    test('legacy saved key never escapes through $location', () async {
      final f = _LegacyTools('openai');
      final request = f.request(
        messages: location == 'prompt'
            ? [
                NativeToolMessage(
                  role: NativeToolRole.user,
                  text: 'Echo $nativeCanary',
                ),
              ]
            : null,
      );
      f.h.reply(
        f.h.response(
          tool: location != 'response',
          prose: location == 'response' ? nativeCanary : null,
          arguments: {'value': location == 'arguments' ? nativeCanary : 'dark'},
        ),
      );
      final session = f.session(input: request);
      var result = await session.start();
      if (location == 'result') {
        expect(result.status, NativeToolStatus.calls);
        result = await session.continueWith(_applied(value: nativeCanary));
      }
      expect(result.reason, NativeToolReason.denied);
      expect(result.calls, isEmpty);
      expect(result.text, isEmpty);
      expect(result.toString(), isNot(contains(nativeCanary)));
      expect(f.h.native.wires.length, location == 'prompt' ? 0 : 1);
      for (final wire in f.h.native.wires) {
        expect(jsonEncode(wire.body), isNot(contains(nativeCanary)));
      }
      f.expectNoVaultMutation();
    });
  }

  test('legacy tool-like prose remains prose, not executable calls', () async {
    final f = _LegacyTools('openai');
    const prose =
        '{"id":"call_1","name":"set_theme","arguments":{"value":"dark"}}';
    f.h.reply(f.h.response(tool: false, prose: prose));
    final result = await f.session().start();
    expect(result.status, NativeToolStatus.complete);
    expect(result.text, prose);
    expect(result.calls, isEmpty);
    f.expectNoVaultMutation();
  });

  test(
    'native constructor still refuses row keys; keyless native absence never falls back',
    () async {
      final h = ToolHarness('openai');
      expect(
        () =>
            h.session(config: h.native.core.row.copyWith(apiKey: nativeCanary)),
        throwsA(isA<NativeToolException>()),
      );
      final result = await h.session().start();
      expect(result.reason, NativeToolReason.denied);
      expect(h.native.wires, isEmpty);
      expect(h.native.legacy.requests, isEmpty);
      expect(h.native.core.storage.writeKeys, isEmpty);
    },
  );

  test(
    'legacy request refuses recipient mismatch, query auth and Gemini action substitution',
    () {
      final f = _LegacyTools('openai');
      for (final recipient in [
        Uri.parse('https://other.example/v1/chat/completions'),
        Uri.parse('${f.h.native.core.row.endpoint}?key=synthetic'),
      ]) {
        expect(
          () => f.request(recipient: recipient),
          throwsA(isA<NativeToolException>()),
        );
      }
      final gemini = _LegacyTools('gemini');
      expect(
        () => gemini.request(
          config: nativeTransportRow('gemini').copyWith(apiKey: nativeCanary),
        ),
        throwsA(isA<NativeToolException>()),
      );
      f.expectNoVaultMutation();
      gemini.expectNoVaultMutation();
    },
  );
}
