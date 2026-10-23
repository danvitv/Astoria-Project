import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_adapter.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_private_text_fixture.dart';

/// Owned-memory T schedules only. A true callback result models the admission
/// contract, NOT physical H COMMIT, SQLite exclusion or remote receipt.
final class PrivateTextResponseCancelFixture {
  PrivateTextResponseCancelFixture({
    PrivateTextAdmission? admission,
    bool syncThrow = false,
  }) : http = PrivateTextResponseCancelAdapter(syncThrow: syncThrow) {
    _admit = (value) {
      capsule = value;
      return Future<bool>.sync(() {
        if (admission != null) return admission(value);
        value.dispatch();
        return true;
      }).then(
        (value) {
          granted = value;
          admissionReturned.complete();
          return value;
        },
        onError: (Object error, StackTrace stack) {
          admissionThrew = true;
          admissionReturned.complete();
          Error.throwWithStackTrace(error, stack);
        },
      );
    };
  }

  final PrivateTextResponseCancelAdapter http;
  final token = CancelToken();
  final admissionReturned = Completer<void>();
  late final PrivateTextAdmission _admit;
  PrivateTextDispatchCapsule? capsule;
  PrivateTextAdapter? direct;
  bool? granted;
  bool admissionThrew = false;
  int factoryCalls = 0;

  HttpClientAdapter _factory() {
    factoryCalls++;
    return http;
  }

  Future<PrivateTextOutcome> run() =>
      PrivateTextTransport(
        adapterFactory: _factory,
        currentRedactor: () => SecretRedactor(),
        authorize: (_) => throw StateError('Weak authorization must not run'),
        admit: _admit,
      ).generate(
        protocol: LlmProtocol.openai,
        request: privateRequest(),
        approvedRecipient: Uri.parse(privateRequest().endpoint),
        cancelToken: token,
        isCurrent: () => true,
      );

  /// Direct adapter controls exclude Dio's independent cancellation race so the
  /// carrier/cancel tie has an observable private classification boundary.
  Future<ResponseBody> startDirect() {
    final plan = PrivateTextRequestPlan(
      LlmProtocol.openai,
      privateRequest(),
      Uri.parse(privateRequest().endpoint),
      SecretRedactor(),
    );
    final adapter = PrivateTextAdapter(
      factory: _factory,
      authorize: (_) => throw StateError('Weak authorization must not run'),
      plan: plan,
      cancelToken: token,
      isCurrent: () => true,
      currentRedactor: () => SecretRedactor(),
      admit: _admit,
    );
    direct = adapter;
    return adapter.fetch(
      RequestOptions(
        path: plan.wireUri.toString(),
        method: 'POST',
        headers: Map.of(plan.headers),
        data: jsonDecode(plan.bodyJson),
        followRedirects: false,
        maxRedirects: 0,
        responseType: ResponseType.stream,
        receiveDataWhenStatusError: false,
        cancelToken: token,
      ),
      null,
      token.whenCancel,
    );
  }

  Future<void> afterSuccessfulReturn() async {
    await admissionReturned.future;
    // An event-queue barrier drains the admission/race microtasks before the
    // test acts. No elapsed-time assumption or additional source await.
    await drainMicrotasks();
  }

  void close() {
    direct?.close(force: true);
    http.close(force: true);
  }
}

/// Uses the unchanged real native-upload fixture, but controls the Future handed
/// back to the private carrier. No HTTP, DB, vault or startup code is invoked.
final class PrivateTextResponseCancelAdapter implements HttpClientAdapter {
  PrivateTextResponseCancelAdapter({this.syncThrow = false});
  final bool syncThrow;
  final actual = PrivateFixtureAdapter(chatComplete('Safe reply'));
  late final Completer<ResponseBody> headers;
  final prepared = Completer<void>();
  final rawError = PrivateTextResponseCancelRawError();
  ResponseBody? _body;
  int fetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    headers = Completer<ResponseBody>();
    fetches++;
    unawaited(
      actual.fetch(options, requestStream, cancelFuture).then<void>((body) {
        _body = body;
        prepared.complete();
      }),
    );
    if (syncThrow) throw rawError;
    return headers.future;
  }

  void complete() => headers.complete(_body!);
  void reject() => headers.completeError(rawError, StackTrace.current);

  @override
  void close({bool force = false}) => actual.close(force: force);
}

final class PrivateTextResponseCancelRawError implements Exception {
  int formats = 0;
  @override
  String toString() {
    formats++;
    return 'RAW_PROVIDER_CANARY fixture-credential';
  }
}

Future<void> drainMicrotasks() => Future<void>(() {});
