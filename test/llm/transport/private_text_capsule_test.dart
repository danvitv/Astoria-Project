import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_adapter.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_outcome.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';

import '_private_text_fixture.dart' show privateRequest;

/// T-only fixtures; they do NOT assert H root/reservation/policy correctness.
void main() {
  for (final mutation in [
    'method',
    'route',
    'auth',
    'duplicate-header',
    'body',
    'redirect',
    'response-mode',
    'error-body',
    'redactor',
    'current',
    'cancel',
  ]) {
    test(
      'capsule rechecks exact raw wire/native state after admission await: $mutation',
      () async {
        final plan = PrivateTextRequestPlan(
          LlmProtocol.openai,
          privateRequest(),
          Uri.parse(privateRequest().endpoint),
          SecretRedactor(),
        );
        final token = CancelToken();
        var current = true;
        var redactor = SecretRedactor();
        final actual = _CountOnlyAdapter();
        final options = RequestOptions(
          path: plan.wireUri.toString(),
          method: 'POST',
          headers: Map.of(plan.headers),
          data: jsonDecode(plan.bodyJson),
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.stream,
          receiveDataWhenStatusError: false,
          cancelToken: token,
        );
        final entered = Completer<void>();
        final resume = Completer<void>();
        late PrivateTextDispatchCapsule escaped;
        final adapter = PrivateTextAdapter(
          factory: () => actual,
          authorize: (_) async => throw StateError('Weak authorizer invoked'),
          plan: plan,
          cancelToken: token,
          isCurrent: () => current,
          currentRedactor: () => redactor,
          admit: (capsule) async {
            escaped = capsule;
            entered.complete();
            await resume.future;
            capsule.dispatch();
            return true;
          },
        );
        final pending = adapter.fetch(options, null, token.whenCancel);
        // Attach error handling before any injected rejection or cancellation.
        final observed = expectLater(
          pending,
          throwsA(isA<PrivateTextFailure>()),
        );
        await entered.future;
        switch (mutation) {
          case 'method':
            options.method = 'GET';
          case 'route':
            options.path = 'https://other.invalid/v1/chat/completions';
          case 'auth':
            options.headers['Authorization'] = 'Bearer replaced';
          case 'duplicate-header':
            // Dio's map is case-insensitive; repeated auth values must not pass.
            options.headers['authorization'] = [
              plan.headers['Authorization'],
              plan.headers['Authorization'],
            ];
          case 'body':
            options.data = {'model': 'replacement'};
          case 'redirect':
            options.followRedirects = true;
          case 'response-mode':
            options.responseType = ResponseType.json;
          case 'error-body':
            options.receiveDataWhenStatusError = true;
          case 'redactor':
            redactor = SecretRedactor(knownSecrets: ['CURRENT_TEXT_CANARY']);
          case 'current':
            current = false;
          case 'cancel':
            token.cancel();
        }
        resume.complete();
        await observed;
        expect(actual.fetches, 0);
        expect(adapter.dispatchCount, 0);
        expect(adapter.admittedFailed, false);
        expect(escaped.isCurrent, false);
        expect(() => escaped.dispatch(), throwsA(isA<PrivateTextFailure>()));
        expect(actual.fetches, 0);
        adapter.close(force: true);
      },
    );
  }

  test(
    'granted boolean without capsule dispatch is not fabricated admission',
    () async {
      final plan = PrivateTextRequestPlan(
        LlmProtocol.openai,
        privateRequest(),
        Uri.parse(privateRequest().endpoint),
        SecretRedactor(),
      );
      final token = CancelToken();
      final actual = _CountOnlyAdapter();
      final adapter = PrivateTextAdapter(
        factory: () => actual,
        authorize: (_) async => false,
        plan: plan,
        cancelToken: token,
        isCurrent: () => true,
        currentRedactor: () => SecretRedactor(),
        admit: (_) async => true,
      );
      final options = RequestOptions(
        path: plan.wireUri.toString(),
        method: 'POST',
        headers: Map.of(plan.headers),
        data: jsonDecode(plan.bodyJson),
        followRedirects: false,
        maxRedirects: 0,
        responseType: ResponseType.stream,
        receiveDataWhenStatusError: false,
        cancelToken: token,
      );
      await expectLater(
        adapter.fetch(options, null, token.whenCancel),
        throwsA(isA<PrivateTextFailure>()),
      );
      expect(actual.fetches, 0);
      expect(adapter.reason, PrivateTextReason.denied);
      adapter.close(force: true);
    },
  );
}

final class _CountOnlyAdapter implements HttpClientAdapter {
  int fetches = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    fetches++;
    return Future.value(
      ResponseBody(
        const Stream.empty(),
        200,
        headers: {
          'content-type': ['text/event-stream'],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}
