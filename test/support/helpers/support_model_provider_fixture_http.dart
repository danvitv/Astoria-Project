import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../llm/transport/_private_text_fixture.dart';

/// Count the ACTUAL synchronous private adapter fetch, not a fake service result.
/// Underlying upload/response/cancel primitives remain synthetic and socket-free.
final class ModelProviderHttpAdapter implements HttpClientAdapter {
  ModelProviderHttpAdapter(this.native);
  final PrivateFixtureAdapter native;
  final _responseListening = Completer<void>();
  int fetches = 0;
  RequestOptions? get options => native.options;
  String? get upload => native.upload;
  Completer<void> get fetched => native.fetched;

  /// Fetch-start does not prove upload completion, headers or SSE subscription.
  /// This completes only AFTER the underlying response stream has been listened.
  Future<void> get responseListening => _responseListening.future;
  Completer<void> get cancelObserved => native.cancelObserved;
  bool get closed => native.closed;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetches++;
    final response = await native.fetch(options, requestStream, cancelFuture);
    // Keep the actual body, status, headers and all other response metadata.
    response.stream = _ResponseListeningStream(
      response.stream,
      _responseListening,
    );
    return response;
  }

  @override
  void close({bool force = false}) => native.close(force: force);
}

/// Observe subscription, not events. Returning the actual subscription preserves
/// cancellation, backpressure, pause/resume and handler replacement unchanged.
final class _ResponseListeningStream extends Stream<Uint8List> {
  _ResponseListeningStream(this.source, this.listening);
  final Stream<Uint8List> source;
  final Completer<void> listening;

  @override
  bool get isBroadcast => source.isBroadcast;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    if (!listening.isCompleted) listening.complete();
    return subscription;
  }
}
