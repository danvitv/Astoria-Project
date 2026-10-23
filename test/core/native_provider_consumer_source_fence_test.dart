import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

import 'native_provider_consumer_source_fence_fixture.dart';

void _expectOriginalRequest(NativeConsumerSourceFenceFixture f) {
  final request = f.tap.requests.single;
  expect(request.savedConnectionAuth, same(f.scope.savedConnectionAuth));
  expect(request.savedConnectionId, f.scope.savedConnectionId);
  expect(request.apiKey, isEmpty);
  expect(request.nativeSourceIsCurrent, isNotNull);
  final rewritten = request.withMessages(request.messages);
  expect(rewritten.savedConnectionAuth, same(request.savedConnectionAuth));
  expect(rewritten.nativeSourceIsCurrent, same(request.nativeSourceIsCurrent));
}

void _expectNoEgress(NativeConsumerSourceFenceFixture f) {
  expect(f.source.wire.wires, isEmpty);
  expect(f.source.wire.legacy.requests, isEmpty);
  expect(f.updates, isEmpty);
  expect(f.completions, isEmpty);
  expect(f.rawResponses, isEmpty);
  expect(f.tap.requests.single.nativeSourceIsCurrent!(), isFalse);
}

void main() {
  for (final protocol in ['openai', 'gemini']) {
    for (final consumer in ['agent', 'aux_once', 'aux_stream']) {
      for (final change in ['redactor', 'Stop', 'session', 'ABA']) {
        test(
          '$consumer $protocol original source revoked during METADATA: $change',
          () async {
            final f = NativeConsumerSourceFenceFixture(
              consumer,
              protocol: protocol,
            );
            await f.prepare();
            final gate = NativeSourceHeldGate();
            f.source.wire.core.storage.beforeRead = gate.hold;
            final pending = f.run();
            await gate.entered.future;
            _expectOriginalRequest(f);
            expect(f.tap.requests.single.nativeSourceIsCurrent!(), isTrue);
            f.revoke(change);
            if (change == 'redactor' || change == 'session') {
              // The auth/mutation stamp alone is STILL current. Only the ORIGINAL
              // source callback can deny this job after the metadata await.
              expect(
                f.source.wire.core.auth.isCurrent(f.scope.savedConnectionAuth!),
                isTrue,
              );
            }
            gate.release();
            await pending;
            // Cancellation can return before the held original storage task.
            // Keep the strict fake-wire/no-default harness through its full drain.
            await f.source.wire.core.credentials.settleOrdinaryInvalidations();
            _expectNoEgress(f);
            expect(f.source.wire.adapters, isEmpty);
          },
        );

        test(
          '$consumer $protocol FINAL FACTORY checkpoint revokes source: $change',
          () async {
            final f = NativeConsumerSourceFenceFixture(
              consumer,
              protocol: protocol,
            );
            await f.prepare();
            var crossedFactory = false;
            // adapterFactory is SYNCHRONOUS. Hold custody of this callback turn,
            // revoke inside it, then return the actual declared fake adapter. Do
            // NOT insert a fake admission guard into that adapter's fetch method.
            f.source.wire.onFactory = () {
              crossedFactory = true;
              _expectOriginalRequest(f);
              expect(f.tap.requests.single.nativeSourceIsCurrent!(), isTrue);
              f.revoke(change);
            };
            await f.run();
            await f.source.wire.core.credentials.settleOrdinaryInvalidations();
            expect(crossedFactory, isTrue);
            _expectNoEgress(f);
            expect(f.source.wire.adapters, hasLength(1));
            expect(f.source.wire.adapters.single.closed, isTrue);
          },
        );
      }
    }
  }

  test(
    'actual OpenRouter consumer, withMessages and router copies retain predicate POINTER',
    () async {
      final f = NativeConsumerSourceFenceFixture(
        'agent',
        protocol: 'openrouter',
      );
      await f.prepare();
      final gate = NativeSourceHeldGate();
      f.source.wire.core.storage.beforeRead = gate.hold;
      final pending = f.run();
      await gate.entered.future;
      _expectOriginalRequest(f);
      final request = f.tap.requests.single;
      final rewritten = request.withMessages(request.messages);
      final routed = OpenRouterChatTransport.buildRouterRequest(rewritten);
      expect(routed.nativeSourceIsCurrent, same(request.nativeSourceIsCurrent));
      expect(routed.savedConnectionAuth, same(f.scope.savedConnectionAuth));
      f.revoke('session');
      expect(routed.nativeSourceIsCurrent!(), isFalse);
      gate.release();
      await pending;
      await f.source.wire.core.credentials.settleOrdinaryInvalidations();
      _expectNoEgress(f);
    },
  );

  test(
    'bindNativeCurrent cannot promote a legacy scope or renew a native scope',
    () async {
      final legacy = NativeSourceConsumerFixture();
      final legacyScope = await legacy.prepare();
      var calls = 0;
      expect(
        legacyScope.bindNativeCurrent(
          isCurrent: () {
            calls++;
            return false;
          },
        ),
        isNull,
      );
      expect(calls, 0);
      final f = NativeConsumerSourceFenceFixture('agent');
      await f.prepare();
      final predicate = f.scope.bindNativeCurrent(
        isCurrent: () {
          f.revoke('ABA');
          return true;
        },
      )!;
      expect(predicate(), isFalse);
      expect(predicate(), isFalse);
      expect(f.source.wire.wires, isEmpty);
    },
  );

  test(
    'roleplay/Gemini fromApiConfig copies keep original scope and run predicate',
    () async {
      final f = NativeSourceConsumerFixture(protocol: 'gemini');
      await f.wire.store();
      final scope = await f.prepare();
      var runCurrent = true;
      final predicate = scope.bindNativeCurrent(isCurrent: () => runCurrent)!;
      final request = ChatTransportRequest.fromApiConfig(
        scope.configuration,
        savedConnectionAuth: scope.savedConnectionAuth,
        nativeSourceIsCurrent: predicate,
        messages: const [
          {'role': 'user', 'content': 'Synthetic prompt'},
        ],
      );
      final copy = request.withMessages(request.messages);
      expect(request.savedConnectionAuth, same(scope.savedConnectionAuth));
      expect(copy.nativeSourceIsCurrent, same(predicate));
      expect(copy.apiKey, isEmpty);
      expect(copy.nativeSourceIsCurrent!(), isTrue);
      runCurrent = false;
      expect(scope.isCurrent, isTrue);
      expect(copy.nativeSourceIsCurrent!(), isFalse);
      runCurrent = true;
      expect(copy.nativeSourceIsCurrent!(), isFalse);
      expect(f.wire.wires, isEmpty);
    },
  );

  test(
    'arbitrary caller-current error is denial-only, never a raw diagnostic',
    () async {
      final f = NativeConsumerSourceFenceFixture('agent');
      await f.prepare();
      final predicate = f.scope.bindNativeCurrent(
        isCurrent: () => throw StateError(nativeCanary),
      )!;
      expect(predicate(), isFalse);
      expect(f.scope.isCurrent, isTrue);
      expect(f.source.wire.wires, isEmpty);
    },
  );

  test(
    'pure Agent request builder keeps null current predicate for legacy config',
    () {
      final request = AgentStreamRunner.buildRequest(
        agent: const StudioAgent(id: 'continuity'),
        messages: const [],
        resolved: const ResolvedAgentConfig(
          endpoint: 'legacy',
          apiKey: 'SYNTHETIC_LEGACY',
          model: 'model',
          protocol: 'openai',
        ),
        sessionId: 'session',
        isFinalResponse: false,
        isCurrent: () => false,
      );
      expect(request.nativeSourceIsCurrent, isNull);
      expect(
        request.withMessages(request.messages).nativeSourceIsCurrent,
        isNull,
      );
    },
  );
}
