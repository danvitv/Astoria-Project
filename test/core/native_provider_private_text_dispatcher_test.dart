import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import 'native_provider_transport_fixture.dart';

NativeProviderPrivateTextDispatcher _dispatcher(
  NativeTransportHarness h, {
  PrivateTextAuthorization? authorize,
  PrivateTextAdmission? admit,
}) => NativeProviderPrivateTextDispatcher(
  credentials: h.core.credentials,
  authIssuer: h.core.auth,
  mutations: h.core.mutations,
  routes: h.core.policy,
  privateTextTransport: PrivateTextTransport(
    adapterFactory: h.adapter,
    currentRedactor: () => h.core.redaction.redactor,
    authorize: authorize ?? (_) async => true,
    admit: admit,
  ),
);

Future<PrivateTextOutcome> _run(
  NativeTransportHarness h, {
  NativeProviderPrivateTextDispatcher? dispatcher,
  ChatTransportRequest? request,
  SavedConnectionAuth? auth,
  Uri? recipient,
  CancelToken? token,
  bool Function()? current,
  void Function()? activity,
}) {
  final original = auth ?? h.core.reference(NativeProviderPurpose.astoria);
  return (dispatcher ?? _dispatcher(h)).generate(
    savedConnectionAuth: original,
    request:
        request ??
        h.request(purpose: NativeProviderPurpose.astoria, auth: original),
    protocol: h.protocol,
    approvedRecipient: recipient ?? Uri.parse(h.core.row.endpoint),
    cancelToken: token ?? CancelToken(),
    isCurrent: current ?? () => true,
    onActivity: activity,
  );
}

void main() {
  for (final protocol in nativeTransportProtocols) {
    test(
      '$protocol actual accepted private text transport consumes native original authority',
      () async {
        final h = NativeTransportHarness(protocol);
        await h.store(purposes: {NativeProviderPurpose.astoria});
        final handoffs = <PrivateTextHandoff>[];
        final auth = h.core.reference(NativeProviderPurpose.astoria);
        final request = h.request(
          purpose: NativeProviderPurpose.astoria,
          auth: auth,
        );
        final result = await _run(
          h,
          auth: auth,
          request: request,
          dispatcher: _dispatcher(
            h,
            authorize: (handoff) async {
              handoffs.add(handoff);
              return true;
            },
          ),
        );
        expect(result.status, PrivateTextStatus.complete);
        expect(result.reason, PrivateTextReason.none);
        expect(result.text, 'Visible text ');
        expect(result.dispatch, PrivateTextDispatch.admitted);
        expect(h.wires, hasLength(1));
        expect(h.legacy.requests, isEmpty);
        expect(request.apiKey, isEmpty);
        expect(h.core.row.apiKey, isEmpty);
        expect(identical(request.savedConnectionAuth, auth), isTrue);
        expect(handoffs.single.recipient, Uri.parse(h.core.row.endpoint));
        expect(handoffs.single.model, h.core.row.model);
        expect(handoffs.single.attempt, 1);
        expect(handoffs.single.toString(), isNot(contains(nativeCanary)));
        expect(jsonEncode(h.wires.single.body), isNot(contains(nativeCanary)));
        expect(
          jsonEncode(h.wires.single.body),
          isNot(contains('SavedConnectionAuth')),
        );
        expect(h.adapters.single.closed, isTrue);
        expect(result.toString(), isNot(contains(nativeCanary)));
      },
    );
  }

  test(
    'Gemini accepted query-auth capsule delegates only translated header-auth wire',
    () async {
      final h = NativeTransportHarness('gemini');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final result = await _run(h);
      expect(result.reason, PrivateTextReason.none);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(h.wires, hasLength(1));
      expect(h.wires.single.uri, Uri.parse('${h.core.row.endpoint}?alt=sse'));
      expect(h.wires.single.uri.queryParameters, {'alt': 'sse'});
      expect(h.wires.single.headers['x-goog-api-key'], nativeCanary);
      expect(h.wires.single.headers['Authorization'], isNull);
      expect(h.core.row.apiKey, isEmpty);
    },
  );

  test(
    'original accepted admission capsule is one-shot and credential-free',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      late PrivateTextDispatchCapsule original;
      var admissions = 0;
      final result = await _run(
        h,
        dispatcher: _dispatcher(
          h,
          authorize: (_) async =>
              throw StateError('Weak authorize should not be called'),
          admit: (capsule) async {
            admissions++;
            original = capsule;
            expect(capsule.isCurrent, isTrue);
            expect(capsule.handoff.recipient, Uri.parse(h.core.row.endpoint));
            expect(capsule.toString(), isNot(contains(nativeCanary)));
            capsule.dispatch();
            expect(capsule.isCurrent, isFalse);
            expect(
              () => capsule.dispatch(),
              throwsA(isA<PrivateTextFailure>()),
            );
            return true;
          },
        ),
      );
      expect(result.status, PrivateTextStatus.complete);
      expect(admissions, 1);
      expect(h.wires, hasLength(1));
      expect(original.isCurrent, isFalse);
      expect(() => original.dispatch(), throwsA(isA<PrivateTextFailure>()));
      expect(h.wires, hasLength(1));
    },
  );

  test(
    'boolean without capsule dispatch does not fabricate an admitted run',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final result = await _run(
        h,
        dispatcher: _dispatcher(h, admit: (_) async => true),
      );
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(h.wires, isEmpty);
      expect(result.reason, PrivateTextReason.denied);
    },
  );

  test(
    'revocation during original admission await prevents actual fetch',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final entered = Completer<void>();
      final release = Completer<void>();
      late PrivateTextDispatchCapsule capsule;
      final pending = _run(
        h,
        dispatcher: _dispatcher(
          h,
          admit: (original) async {
            capsule = original;
            entered.complete();
            await release.future;
            original.dispatch();
            return true;
          },
        ),
      );
      await entered.future;
      h.core.ordinaryMutation();
      release.complete();
      final result = await pending;
      expect(result.status, PrivateTextStatus.stopped);
      expect(h.wires, isEmpty);
      expect(capsule.isCurrent, isFalse);
    },
  );

  test(
    'revocation during authorization await denies before adapter construction',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final entered = Completer<void>();
      final release = Completer<void>();
      var current = true;
      final pending = _run(
        h,
        current: () => current,
        dispatcher: _dispatcher(
          h,
          authorize: (_) async {
            entered.complete();
            await release.future;
            return true;
          },
        ),
      );
      await entered.future;
      current = false;
      release.complete();
      final result = await pending;
      expect(result.status, PrivateTextStatus.stopped);
      expect(h.wires, isEmpty);
    },
  );

  test(
    'admitted original fetch failure remains admittedFailed with no second wire',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      h.fetchError = StateError(nativeCanary);
      final result = await _run(
        h,
        dispatcher: _dispatcher(
          h,
          admit: (capsule) async {
            capsule.dispatch();
            return true;
          },
        ),
      );
      expect(result.dispatch, PrivateTextDispatch.admittedFailed);
      expect(result.reason, PrivateTextReason.admittedFailed);
      expect(result.status, PrivateTextStatus.error);
      expect(result.text, isEmpty);
      expect(result.toString(), isNot(contains(nativeCanary)));
      expect(h.wires, hasLength(1));
      expect(h.adapters.single.closed, isTrue);
    },
  );

  test(
    'accepted private text remains whole-buffer sanitized with split key echo',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      String frame(String text) =>
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': text},
              },
            ],
          })}\n\n';
      h.response =
          '${frame('before ${nativeCanary.substring(0, 12)}')}'
          '${frame('${nativeCanary.substring(12)} after')}'
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
      var activities = 0;
      final result = await _run(
        h,
        activity: () {
          activities++;
        },
      );
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, 'before [REDACTED] after');
      expect(activities, 1);
      expect(result.text, isNot(contains(nativeCanary)));
      expect(h.completions, isEmpty);
      expect(h.updates, isEmpty);
    },
  );

  test(
    'activity callback currentness is checked before and after, never repaired',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      var current = true;
      var activities = 0;
      final result = await _run(
        h,
        current: () => current,
        activity: () {
          activities++;
          current = false;
        },
      );
      expect(result.status, PrivateTextStatus.stopped);
      expect(activities, 1);
      expect(h.wires, hasLength(1));
      expect(h.adapters.single.closed, isTrue);
    },
  );

  for (final shape in [
    'schema',
    'tools',
    'nonstream',
    'history-tool',
    'paid-purpose',
    'recipient',
    'model',
    'key',
  ]) {
    test(
      'native dispatch does not relax accepted plan or binding: $shape',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store(purposes: {NativeProviderPurpose.astoria});
        final auth = h.core.reference(
          shape == 'paid-purpose'
              ? NativeProviderPurpose.roleplay
              : NativeProviderPurpose.astoria,
        );
        final request = h.request(
          auth: auth,
          purpose: auth.purpose,
          schema: shape == 'schema' ? const {'type': 'object'} : null,
          tools: shape == 'tools' ? const [] : null,
          stream: shape != 'nonstream',
          model: shape == 'model' ? 'unbound-model' : null,
          key: shape == 'key' ? nativeCanary : null,
          messages: shape == 'history-tool'
              ? const [
                  {'role': 'tool', 'content': 'result'},
                ]
              : null,
        );
        final result = await _run(
          h,
          auth: auth,
          request: request,
          recipient: shape == 'recipient'
              ? Uri.parse('https://synthetic.example/v1/chat/completions')
              : null,
        );
        expect(result.status, PrivateTextStatus.error);
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
        expect(h.wires, isEmpty);
        expect(h.legacy.requests, isEmpty);
      },
    );
  }

  test(
    'stale original authority and missing native record never become preview/dummy auth',
    () async {
      final absent = NativeTransportHarness('openai');
      final result = await _run(absent);
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(absent.wires, isEmpty);
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final auth = h.core.reference(NativeProviderPurpose.astoria);
      final request = h.request(
        auth: auth,
        purpose: NativeProviderPurpose.astoria,
      );
      h.core.ordinaryMutation();
      h.core.reference(NativeProviderPurpose.astoria);
      final stale = await _run(h, auth: auth, request: request);
      expect(stale.status, PrivateTextStatus.stopped);
      expect(stale.dispatch, PrivateTextDispatch.notAdmitted);
      expect(h.wires, isEmpty);
    },
  );
}
