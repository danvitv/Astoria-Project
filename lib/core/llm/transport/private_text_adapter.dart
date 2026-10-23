import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../credentials/secret_redactor.dart';

import 'private_text_event_decoder.dart';
import 'private_text_outcome.dart';
import 'private_text_request.dart';
import 'private_text_stream_guard.dart';

part 'private_text_dispatch_capsule.dart';

typedef PrivateTextAuthorization =
    Future<bool> Function(PrivateTextHandoff handoff);

/// Strong path: trusted H/native root admission, returning only after the DB
/// transaction releases. Never await HTTP or escape parallel DB work here.
typedef PrivateTextAdmission =
    Future<bool> Function(PrivateTextDispatchCapsule capsule);

/// Owns fresh adapters, including a new one for the native 408 retry. The
/// injected factory must create a capture-free, cancellation-capable adapter.
final class PrivateTextAdapter implements HttpClientAdapter {
  PrivateTextAdapter({
    required this.factory,
    required this.authorize,
    required this.plan,
    required this.cancelToken,
    required this.isCurrent,
    required this.currentRedactor,
    this.admit,
    this.onActivity,
  }) {
    unawaited(cancelToken.whenCancel.then((_) => close(force: true)));
  }
  final HttpClientAdapter Function() factory;
  final PrivateTextAuthorization authorize;
  final PrivateTextAdmission? admit;
  final PrivateTextRequestPlan plan;
  final CancelToken cancelToken;
  final bool Function() isCurrent;
  final SecretRedactor Function() currentRedactor;
  final void Function()? onActivity;
  HttpClientAdapter? _inner;
  bool _closed = false;
  int _attempt = 0;
  PrivateTextStreamGuard? guard;
  PrivateTextReason reason = PrivateTextReason.none;
  int? httpStatus;
  int dispatchCount = 0;
  bool admittedFailed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    try {
      _check(options);
      final handoff = PrivateTextHandoff(
        protocol: plan.protocol,
        recipient: plan.recipient,
        model: plan.request.model,
        attempt: ++_attempt,
      );
      final ResponseBody response;
      final HttpClientAdapter inner;
      if (admit != null) {
        // Factory/frozen upload/carrier are prepared BEFORE H's final reads.
        inner = factory();
        _inner = inner;
        _check(options);
        final capsule = PrivateTextDispatchCapsule._(
          this,
          inner,
          options,
          cancelFuture,
          handoff,
          Uint8List.fromList(utf8.encode(plan.bodyJson)),
        );
        response = await _reservedResponse(capsule);
      } else {
        // Preserved standalone API: async bool approval is NOT an exact-source
        // dispatch fence. Feature integration must use admit instead.
        final granted = await authorize(handoff);
        if (!granted) throw const PrivateTextFailure(PrivateTextReason.denied);
        _check(options);
        inner = factory();
        _inner = inner;
        _check(options);
        final wire = Uint8List.fromList(utf8.encode(plan.bodyJson));
        plan.recheckSanitation(currentRedactor());
        _check(options);
        dispatchCount++;
        response = await inner.fetch(options, Stream.value(wire), cancelFuture);
      }
      if (_closed || cancelToken.isCancelled || !isCurrent()) {
        inner.close(force: true);
        throw const PrivateTextFailure(PrivateTextReason.notCurrent);
      }
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.isRedirect) {
        httpStatus = response.statusCode;
        reason = PrivateTextReason.httpStatus;
        // Close the owned connection WITHOUT listening to rejected-body bytes.
        // Return status only: Dio/native error decoding cannot capture content,
        // Location, status text, provider JSON, or arbitrary response metadata.
        inner.close(force: true);
        _inner = null;
        return ResponseBody(const Stream.empty(), response.statusCode);
      }
      final contentType = response.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'content-type')
          .expand((entry) => entry.value)
          .toList();
      if (contentType.length != 1 ||
          contentType.single.split(';').first.trim().toLowerCase() !=
              'text/event-stream') {
        inner.close(force: true);
        throw const PrivateTextFailure(PrivateTextReason.unsupported);
      }
      reason = PrivateTextReason.none;
      httpStatus = null;
      guard = PrivateTextStreamGuard(
        decoder: PrivateTextEventDecoder(plan.decoderProtocol),
        cancelToken: cancelToken,
        isCurrent: isCurrent,
        onActivity: onActivity,
      );
      return ResponseBody(
        guard!.bind(response.stream),
        response.statusCode,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
    } on PrivateTextFailure catch (failure) {
      reason = failure.reason;
      rethrow;
    } catch (_) {
      reason = PrivateTextReason.transport;
      throw const PrivateTextFailure(PrivateTextReason.transport);
    }
  }

  Future<ResponseBody> _reservedResponse(
    PrivateTextDispatchCapsule capsule,
  ) async {
    // Convert callback errors IMMEDIATELY. Cancellation revokes this capsule and
    // native wait, but does not pretend to dequeue H's pending Drift operation.
    final completion = Future<bool>.sync(
      () => admit!(capsule),
    ).then((granted) => granted, onError: (Object _, StackTrace _) => false);
    final granted = await Future.any<bool>([
      completion,
      cancelToken.whenCancel.then((_) => false),
    ]);
    capsule._active = false;
    if (!granted) {
      if (capsule._started) {
        _failAdmitted();
      }
      if (cancelToken.isCancelled) {
        throw const PrivateTextFailure(PrivateTextReason.cancelled);
      }
      throw const PrivateTextFailure(PrivateTextReason.denied);
    }
    if (!capsule._started) {
      throw const PrivateTextFailure(PrivateTextReason.denied);
    }
    // No Future flattening through admission: only after H COMMIT/release.
    final handled = await Future.any<_HandledPrivateResponse>([
      capsule._carrier._response.future,
      cancelToken.whenCancel.then(
        // Let already-ready fetch handlers latch failure before cancellation is
        // classified. This never waits for a still-pending response Future.
        (_) => Future<_HandledPrivateResponse>.value(
          const _HandledPrivateResponse.cancelled(),
        ),
      ),
    ]);
    // An already captured fetch failure remains an error even if cancellation
    // wins the race callback order. Do not await a still-pending HTTP response.
    if (capsule._carrier._failed ||
        handled._kind == _PrivateResponseKind.failed) {
      _failAdmitted();
    }
    if (handled._kind == _PrivateResponseKind.cancelled) {
      throw const PrivateTextFailure(PrivateTextReason.cancelled);
    }
    return handled._body!;
  }

  Never _failAdmitted() {
    admittedFailed = true;
    cancelToken.cancel();
    close(force: true);
    throw const PrivateTextFailure(PrivateTextReason.admittedFailed);
  }

  void _check(RequestOptions options) {
    if (_closed || cancelToken.isCancelled) {
      throw const PrivateTextFailure(PrivateTextReason.cancelled);
    }
    if (!isCurrent()) {
      throw const PrivateTextFailure(PrivateTextReason.notCurrent);
    }
    final expected = {
      for (final entry in plan.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final actual = {
      for (final entry in options.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    // Case folding must not hide duplicate authentication/content headers.
    if (actual.length != options.headers.length) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
    final length = utf8.encode(plan.bodyJson).length;
    final contentLength = actual.remove('content-length');
    if (options.method != 'POST' ||
        options.uri != plan.wireUri ||
        options.followRedirects ||
        options.maxRedirects != 0 ||
        options.responseType != ResponseType.stream ||
        options.receiveDataWhenStatusError ||
        options.cancelToken != cancelToken ||
        actual.length != expected.length ||
        !expected.entries.every((entry) => actual[entry.key] == entry.value) ||
        (contentLength != null &&
            contentLength != '$length' &&
            contentLength != length) ||
        jsonEncode(options.data) != plan.bodyJson) {
      throw const PrivateTextFailure(PrivateTextReason.invalidRequest);
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    try {
      _inner?.close(force: true);
    } catch (_) {
      if (reason == PrivateTextReason.none) {
        reason = PrivateTextReason.transport;
      }
    }
    _inner = null;
  }
}
