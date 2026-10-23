import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_provider_transport_fixture.dart';

void main() {
  for (final raw in ['', 'malformed', '{"secret":"$nativeCanary"}']) {
    test(
      'native presence ($raw) denies keyless legacy fallback without a reference',
      () async {
        final h = NativeTransportHarness('openai');
        h.core.storage.values[h.core.nativeStorageKey] = raw;
        await h.run(input: h.request(includeAuth: false));
        expect(h.wires, isEmpty);
        expect(h.legacy.requests, isEmpty);
        expect(h.errors.single, isA<NativeProviderTransportException>());
        expect(h.errors.single.toString(), isNot(contains(nativeCanary)));
      },
    );
  }

  test('unavailable native presence never falls back', () async {
    final h = NativeTransportHarness('openai');
    h.core.storage.readError = StateError(nativeCanary);
    await h.run(input: h.request(includeAuth: false));
    expect(h.wires, isEmpty);
    expect(h.legacy.requests, isEmpty);
    expect(h.errors, hasLength(1));
    expect(h.errors.single.toString(), isNot(contains(nativeCanary)));
  });

  test(
    'absent saved provenance without auth preserves ORIGINAL legacy request',
    () async {
      final h = NativeTransportHarness('openai');
      final request = h.request(includeAuth: false, key: 'SYNTHETIC_LEGACY');
      await h.run(input: request);
      expect(h.wires, isEmpty);
      expect(h.errors, isEmpty);
      expect(identical(h.legacy.requests.single, request), isTrue);
      expect(h.completions.single.$1, 'legacy');
    },
  );

  test('no source ID/reference direct legacy callers stay unchanged', () async {
    final h = NativeTransportHarness('openai');
    h.core.mutations.dispose();
    const request = ChatTransportRequest(
      endpoint: 'legacy-original',
      apiKey: 'SYNTHETIC_LEGACY',
      model: 'legacy',
      messages: [],
      maxTokens: 1,
      temperature: 0,
      topP: 1,
    );
    await h.run(input: request);
    expect(identical(h.legacy.requests.single, request), isTrue);
    expect(h.core.storage.operations, isEmpty);
  });

  test(
    'an original auth with missing/disabled native record cannot fall back',
    () async {
      final absent = NativeTransportHarness('openai');
      await absent.run();
      expect(absent.wires, isEmpty);
      expect(absent.legacy.requests, isEmpty);
      expect(absent.errors, hasLength(1));
      final disabled = NativeTransportHarness('openai');
      await disabled.store();
      await disabled.core.credentials
          .disableNativeConnectionForOrdinaryMutation(
            connectionId: disabled.core.row.id,
          );
      await disabled.run();
      expect(disabled.wires, isEmpty);
      expect(disabled.legacy.requests, isEmpty);
      expect(disabled.errors, hasLength(1));
    },
  );

  test(
    'native plus nonempty request/row key is conflicting, never a legacy send',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      await h.run(input: h.request(key: nativeCanary));
      h.core.row = h.core.row.copyWith(apiKey: nativeCanary);
      await h.run();
      expect(h.wires, isEmpty);
      expect(h.legacy.requests, isEmpty);
      expect(h.errors, hasLength(2));
    },
  );

  for (final override in [
    'model',
    'endpoint',
    'foreign-id',
    'wrong-protocol',
    'purpose',
  ]) {
    test('unbound $override is refused, not silently rewritten', () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final request = override == 'model'
          ? h.request(model: 'other-model')
          : override == 'endpoint'
          ? h.request(endpoint: 'https://synthetic.example/v1/chat/completions')
          : override == 'purpose'
          ? h.request(purpose: NativeProviderPurpose.studio)
          : h.request();
      if (override == 'foreign-id') {
        final foreign = NativeTransportHarness('openai');
        await foreign.store();
        await h.run(input: foreign.request());
      } else if (override == 'wrong-protocol') {
        await h.factory
            .pick('anthropic')
            .stream(request: request, onError: h.errors.add);
      } else {
        await h.run(input: request);
      }
      expect(h.wires, isEmpty);
      expect(h.legacy.requests, isEmpty);
    });
  }

  test(
    'stale original source and same-content ABA cannot mint at dispatch',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final original = h.request();
      h.core.ordinaryMutation();
      h.core.reference(); // Equal row, new stamp must not replace the original.
      await h.run(input: original);
      expect(h.wires, isEmpty);
      expect(h.legacy.requests, isEmpty);
      expect(h.updates, isEmpty);
      expect(h.completions, isEmpty);
    },
  );

  test('revoke while credential read is held: zero actual wire', () async {
    final h = NativeTransportHarness('openai');
    await h.store();
    final request = h.request();
    final entered = Completer<void>();
    final release = Completer<void>();
    h.core.storage.beforeRead = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final run = h.run(input: request);
    await entered.future;
    h.core.ordinaryMutation();
    release.complete();
    await run;
    expect(h.wires, isEmpty);
    expect(h.updates, isEmpty);
    expect(h.completions, isEmpty);
  });

  test(
    'final factory callback revocation fences before the actual adapter fetch',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.onFactory = h.core.ordinaryMutation;
      await h.run();
      expect(h.adapters, hasLength(1));
      expect(h.wires, isEmpty);
      expect(h.completions, isEmpty);
      expect(h.adapters.single.closed, isTrue);
    },
  );

  test(
    'revoke after actual adapter await drops all late body/callbacks',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.beforeResponse = () async {
        entered.complete();
        await release.future;
      };
      final run = h.run();
      await entered.future;
      h.core.mutations.dispose();
      release.complete();
      await run;
      expect(h.wires, hasLength(1));
      expect(h.updates, isEmpty);
      expect(h.completions, isEmpty);
      expect(h.adapters.single.closed, isTrue);
    },
  );

  test('callback revocation stops further updates and completion', () async {
    final h = NativeTransportHarness('openai');
    await h.store();
    await h.run(update: (_, _) => h.core.ordinaryMutation());
    expect(h.updates, hasLength(1));
    expect(h.completions, isEmpty);
    expect(h.wires, hasLength(1));
    expect(h.adapters.single.closed, isTrue);
  });

  test('Stop drains owned streaming adapter without completion', () async {
    final h = NativeTransportHarness('openai');
    await h.store();
    final body = StreamController<Uint8List>.broadcast();
    h.responseStream = body.stream;
    final token = CancelToken();
    final run = h.run(token: token);
    final ready = Completer<void>();
    h.beforeResponse = () async {
      ready.complete();
    };
    await ready.future;
    token.cancel();
    await run;
    await body.close();
    expect(h.completions, isEmpty);
    expect(h.adapters.single.closed, isTrue);
  });

  test(
    'owned deadline cancels held actual fetch, returns fixed diagnostic once',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final ready = Completer<void>();
      final release = Completer<void>();
      h.beforeResponse = () async {
        ready.complete();
        await release.future;
      };
      final token = CancelToken();
      final run = h.run(token: token);
      await ready.future;
      h.deadlineCallback!();
      await run;
      release.complete();
      expect(token.isCancelled, isTrue);
      expect(h.completions, isEmpty);
      expect(
        h.errors.single,
        isA<NativeProviderTransportException>().having(
          (failure) => failure.reason,
          'deadline reason',
          NativeProviderTransportReason.deadline,
        ),
      );
      expect(h.adapters.single.closed, isTrue);
    },
  );

  test(
    'deadline during held protected read settles safely without late wire',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.core.storage.beforeRead = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final pending = h.run();
      await entered.future;
      h.deadlineCallback!();
      await pending;
      expect(
        h.errors.single,
        isA<NativeProviderTransportException>().having(
          (failure) => failure.reason,
          'whole-job deadline',
          NativeProviderTransportReason.deadline,
        ),
      );
      expect(h.wires, isEmpty);
      expect(h.completions, isEmpty);
      release.complete();
      await h.core.credentials.settleOrdinaryInvalidations();
      expect(h.wires, isEmpty);
    },
  );

  for (final status in [301, 307, 308, 408, 404]) {
    test(
      '$status never reads rejected bytes or makes a second paid wire',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store();
        h.status = status;
        var listened = false;
        h.responseStream = StreamController<Uint8List>(
          onListen: () {
            listened = true;
          },
        ).stream;
        await h.run();
        expect(h.wires, hasLength(1));
        expect(h.adapters, hasLength(1));
        expect(listened, isFalse);
        expect(h.completions, isEmpty);
        expect(
          h.errors.single,
          isA<NativeProviderTransportException>().having(
            (error) => error.reason,
            'status refusal',
            NativeProviderTransportReason.httpStatus,
          ),
        );
      },
    );
  }

  test(
    'model listing has no generic native key helper or paid fallback',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final models = await h.factory
          .pick('openai')
          .fetchModels(endpoint: h.core.row.endpoint, apiKey: '');
      expect(models, isEmpty);
      expect(h.wires, isEmpty);
      expect(h.legacy.requests, isEmpty);
    },
  );
}
