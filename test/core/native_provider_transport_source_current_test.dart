import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import 'native_provider_transport_fixture.dart';

ChatTransportRequest _request(
  NativeTransportHarness h,
  bool Function()? predicate, {
  NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
  SavedConnectionAuth? auth,
  bool includeAuth = true,
}) => ChatTransportRequest.fromApiConfig(
  h.core.row,
  savedConnectionAuth: includeAuth ? auth ?? h.core.reference(purpose) : null,
  nativeSourceIsCurrent: predicate,
  messages: const [
    {'role': 'user', 'content': 'Hello'},
  ],
);

NativeProviderPrivateTextDispatcher _private(
  NativeTransportHarness h, {
  HttpClientAdapter Function()? factory,
  PrivateTextAdmission? admit,
}) => NativeProviderPrivateTextDispatcher(
  credentials: h.core.credentials,
  authIssuer: h.core.auth,
  mutations: h.core.mutations,
  routes: h.core.policy,
  privateTextTransport: PrivateTextTransport(
    adapterFactory: factory ?? h.adapter,
    currentRedactor: () => h.core.redaction.redactor,
    authorize: (_) async => true,
    admit: admit,
  ),
);

/// A native-only source stand-in: same original policy pointer, never a refreshed
/// reader. No model/config permission is granted by its boolean value.
final class _SourceSnapshot {
  _SourceSnapshot(this.h) : policy = h.core.redaction.redactor;
  final NativeTransportHarness h;
  final Object policy;
  bool live = true;
  int calls = 0;
  bool current() {
    calls++;
    return live && identical(policy, h.core.redaction.redactor);
  }
}

final class _CloseRetiringAdapter implements HttpClientAdapter {
  _CloseRetiringAdapter(this.inner, this.retire);
  final HttpClientAdapter inner;
  final void Function() retire;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => inner.fetch(options, stream, cancelFuture);
  @override
  void close({bool force = false}) {
    inner.close(force: true);
    retire();
  }
}

void main() {
  test(
    'original source function pointer is nonserialized and retained by actual copies',
    () async {
      final h = NativeTransportHarness('openrouter');
      await h.store();
      final source = _SourceSnapshot(h);
      final bool Function() pointer = source.current;
      final request = _request(h, pointer);
      final copy = request.withMessages(const [
        {'role': 'user', 'content': 'copy'},
      ]);
      final routed = OpenRouterChatTransport.buildRouterRequest(copy);
      expect(identical(request.nativeSourceIsCurrent, pointer), isTrue);
      expect(identical(copy.nativeSourceIsCurrent, pointer), isTrue);
      expect(identical(routed.nativeSourceIsCurrent, pointer), isTrue);
      expect(
        identical(routed.savedConnectionAuth, request.savedConnectionAuth),
        isTrue,
      );
      expect(routed.savedConnectionId, request.savedConnectionId);
      final body = jsonEncode(
        OpenAiChatTransport.buildBody(routed, protocol: 'openrouter'),
      );
      expect(body, isNot(contains('nativeSourceIsCurrent')));
      expect(body, isNot(contains('SavedConnectionAuth')));
      expect(body, isNot(contains(nativeCanary)));
      await h.run(input: routed);
      expect(source.calls, greaterThan(1));
      expect(h.wires, hasLength(1));
      expect(h.completions, hasLength(1));
      expect(h.errors, isEmpty);
    },
  );

  for (final predicate in [
    null,
    () => false,
    () => throw StateError(nativeCanary),
  ]) {
    test(
      'null/authless legacy preserves original request and does not evaluate native predicate',
      () async {
        final h = NativeTransportHarness('openai');
        final request = _request(h, predicate, includeAuth: false);
        await h.run(input: request);
        expect(identical(h.legacy.requests.single, request), isTrue);
        expect(h.completions.single.$1, 'legacy');
        expect(h.errors, isEmpty);
        expect(h.wires, isEmpty);
      },
    );
  }

  test(
    'FALSE/throwing native source denies before metadata with no late error/fallback',
    () async {
      for (final predicate in [
        () => false,
        () => throw StateError(nativeCanary),
      ]) {
        final h = NativeTransportHarness('openai');
        await h.store();
        final request = _request(h, predicate);
        h.core.storage.operations.clear();
        await h.run(input: request);
        expect(h.core.storage.operations, isEmpty);
        expect(h.wires, isEmpty);
        expect(h.updates, isEmpty);
        expect(h.completions, isEmpty);
        expect(h.errors, isEmpty);
        expect(h.legacy.requests, isEmpty);
      }
    },
  );

  for (final phase in [1, 2]) {
    for (final change in ['policy', 'source', 'Stop', 'dispose', 'ABA']) {
      test(
        '${phase == 1 ? 'metadata' : 'broker'} held read fences $change before actual wire',
        () async {
          final h = NativeTransportHarness('openai');
          await h.store();
          final source = _SourceSnapshot(h);
          final request = _request(h, source.current);
          final entered = Completer<void>();
          final release = Completer<void>();
          var reads = 0;
          // Ready records use one actual storage read for metadata, then another
          // inside the real broker. No fake observation or key consumer is used.
          h.core.storage.beforeRead = () async {
            if (++reads == phase) {
              entered.complete();
              await release.future;
            }
          };
          final token = CancelToken();
          final pending = h.run(input: request, token: token);
          await entered.future;
          switch (change) {
            case 'policy':
              h.core.redaction.registerSecret('TEST_ONLY_NEW_SOURCE_POLICY');
            case 'source':
              source.live = false;
            case 'Stop':
              token.cancel();
            case 'dispose':
              h.core.mutations.dispose();
            case 'ABA':
              h.core.ordinaryMutation();
              h.core.reference();
          }
          release.complete();
          await pending;
          expect(h.wires, isEmpty);
          expect(h.adapters, isEmpty);
          expect(h.legacy.requests, isEmpty);
          expect(h.updates, isEmpty);
          expect(h.completions, isEmpty);
          expect(h.errors, isEmpty);
        },
      );
    }
  }

  for (final change in ['policy', 'source', 'Stop', 'dispose', 'ABA']) {
    test(
      'actual final factory $change is checked before delegate fetch',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store();
        final source = _SourceSnapshot(h);
        final request = _request(h, source.current);
        final token = CancelToken();
        h.onFactory = () {
          switch (change) {
            case 'policy':
              h.core.redaction.registerSecret('TEST_ONLY_FINAL_SOURCE_POLICY');
            case 'source':
              source.live = false;
            case 'Stop':
              token.cancel();
            case 'dispose':
              h.core.mutations.dispose();
            case 'ABA':
              h.core.ordinaryMutation();
              h.core.reference();
          }
        };
        await h.run(input: request, token: token);
        expect(h.adapters, hasLength(1));
        expect(h.adapters.single.closed, isTrue);
        expect(h.wires, isEmpty);
        expect(h.legacy.requests, isEmpty);
        expect(h.updates, isEmpty);
        expect(h.completions, isEmpty);
        expect(h.errors, isEmpty);
      },
    );
  }

  test(
    'reentrant native owner disposal returning TRUE is denial, never renewed authority',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      var inFactory = false;
      bool source() {
        if (inFactory) h.core.mutations.dispose();
        return true;
      }

      h.onFactory = () {
        inFactory = true;
      };
      await h.run(input: _request(h, source));
      expect(h.wires, isEmpty);
      expect(h.adapters.single.closed, isTrue);
      expect(h.completions, isEmpty);
      expect(h.errors, isEmpty);
    },
  );

  test(
    'error source predicate calling Stop and returning TRUE cannot publish after cancellation',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final token = CancelToken();
      var calls = 0;
      bool source() {
        if (++calls == 2) token.cancel();
        return true;
      }

      // Source validation fails synchronously, so both predicate calls are the
      // actual error publisher's checkpoints, not a counted metadata/broker path.
      final request = ChatTransportRequest.fromApiConfig(
        h.core.row,
        savedConnectionAuth: h.core.reference(),
        nativeSourceIsCurrent: source,
        model: 'UNBOUND_MODEL',
        messages: const [
          {'role': 'user', 'content': 'Hello'},
        ],
      );
      await h.run(input: request, token: token);
      expect(calls, 2);
      expect(token.isCancelled, isTrue);
      expect(h.errors, isEmpty);
      expect(h.updates, isEmpty);
      expect(h.completions, isEmpty);
      expect(h.wires, isEmpty);
      expect(h.adapters, isEmpty);
      expect(h.legacy.requests, isEmpty);
    },
  );

  test(
    'source policy replacement during actual adapter await emits no late callbacks',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final source = _SourceSnapshot(h);
      final request = _request(h, source.current);
      final entered = Completer<void>();
      final release = Completer<void>();
      h.beforeResponse = () async {
        entered.complete();
        await release.future;
      };
      final pending = h.run(input: request);
      await entered.future;
      h.core.redaction.registerSecret('TEST_ONLY_LATE_SOURCE_POLICY');
      release.complete();
      await pending;
      expect(
        h.wires,
        hasLength(1),
        reason: 'Only the already started original wire is a fact',
      );
      expect(h.updates, isEmpty);
      expect(h.completions, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.adapters.single.closed, isTrue);
    },
  );

  test(
    'safe callback source retirement stops remaining deltas/completion without repair',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final source = _SourceSnapshot(h);
      await h.run(
        input: _request(h, source.current),
        update: (_, _) {
          h.core.redaction.registerSecret('TEST_ONLY_CALLBACK_SOURCE_POLICY');
        },
      );
      expect(h.updates, hasLength(1));
      expect(h.completions, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.wires, hasLength(1));
    },
  );

  test(
    'TRUE cannot grant foreign auth, disabled record, purpose or model override',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final foreign = NativeTransportHarness('openai');
      await foreign.store();
      final foreignRef = foreign.core.reference();
      await h.run(input: _request(foreign, () => true, auth: foreignRef));
      await h.run(
        input: _request(h, () => true, purpose: NativeProviderPurpose.studio),
      );
      final auth = h.core.reference();
      await h.run(
        input: ChatTransportRequest.fromApiConfig(
          h.core.row,
          savedConnectionAuth: auth,
          nativeSourceIsCurrent: () => true,
          model: 'UNBOUND_MODEL',
          messages: const [
            {'role': 'user', 'content': 'safe'},
          ],
        ),
      );
      await h.core.credentials.disableNativeConnectionForOrdinaryMutation(
        connectionId: h.core.row.id,
      );
      await h.run(input: _request(h, () => true));
      expect(h.wires, isEmpty);
      expect(h.legacy.requests, isEmpty);
    },
  );

  for (final change in ['policy', 'source', 'Stop', 'dispose']) {
    test(
      'actual Gemini ORIGINAL upload prefetch source $change never delegates',
      () async {
        final h = NativeTransportHarness('gemini');
        await h.store(purposes: {NativeProviderPurpose.astoria});
        final source = _SourceSnapshot(h);
        final token = CancelToken();
        final request = _request(
          h,
          source.current,
          purpose: NativeProviderPurpose.astoria,
        );
        final dispatcher = _private(
          h,
          admit: (capsule) async {
            capsule
                .dispatch(); // Actual bridge starts and awaits ORIGINAL upload.
            switch (change) {
              case 'policy':
                h.core.redaction.registerSecret(
                  'TEST_ONLY_UPLOAD_SOURCE_POLICY',
                );
              case 'source':
                source.live = false;
              case 'Stop':
                token.cancel();
              case 'dispose':
                h.core.mutations.dispose();
            }
            return true; // Preserve original admission settlement, do not invent a new grant.
          },
        );
        final result = await dispatcher.generate(
          savedConnectionAuth: request.savedConnectionAuth!,
          request: request,
          protocol: 'gemini',
          approvedRecipient: Uri.parse(h.core.row.endpoint),
          cancelToken: token,
          isCurrent: () => true,
        );
        expect(h.wires, isEmpty);
        expect(h.adapters, isEmpty);
        expect(h.legacy.requests, isEmpty);
        expect(result.status, isNot(PrivateTextStatus.complete));
        expect(
          result.dispatch,
          anyOf(
            PrivateTextDispatch.admitted,
            PrivateTextDispatch.admittedFailed,
          ),
        );
      },
    );
  }

  test(
    'request source predicate cannot rewrite an ACTUAL completed private outcome fact',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(purposes: {NativeProviderPurpose.astoria});
      final source = _SourceSnapshot(h);
      final request = _request(
        h,
        source.current,
        purpose: NativeProviderPurpose.astoria,
      );
      final dispatcher = _private(
        h,
        factory: () => _CloseRetiringAdapter(h.adapter(), () {
          source.live = false;
        }),
      );
      final result = await dispatcher.generate(
        savedConnectionAuth: request.savedConnectionAuth!,
        request: request,
        protocol: 'openai',
        approvedRecipient: Uri.parse(h.core.row.endpoint),
        cancelToken: CancelToken(),
        isCurrent: () => true,
      );
      expect(source.live, isFalse);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.reason, PrivateTextReason.none);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.text, 'Visible text ');
      expect(h.wires, hasLength(1));
      // Caller MUST still deny publication under this now-retired ORIGINAL source.
      expect(request.nativeSourceIsCurrent!(), isFalse);
    },
  );
}
