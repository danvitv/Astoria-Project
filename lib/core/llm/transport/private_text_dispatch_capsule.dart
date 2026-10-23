part of 'private_text_adapter.dart';

/// Native-private attempt-bound one-shot capability; no public constructor,
/// subclassing, request/response/key/body/fingerprint or response-Future getter.
/// Only the trusted admission callback may invoke dispatch, at H's final
/// synchronous boundary. That callback is source-audited, not arbitrary model
/// code. Late, canceled or double use cannot invoke another actual fetch.
final class PrivateTextDispatchCapsule {
  PrivateTextDispatchCapsule._(
    this._owner,
    this._inner,
    this._options,
    this._cancelFuture,
    this.handoff,
    this._wire,
  );
  final PrivateTextAdapter _owner;
  final HttpClientAdapter _inner;
  final RequestOptions _options;
  final Future<void>? _cancelFuture;
  final Uint8List _wire;
  final _PrivateResponseCarrier _carrier = _PrivateResponseCarrier();
  final PrivateTextHandoff handoff;
  bool _active = true;
  bool _used = false;
  bool _started = false;

  /// Payload-free current checkpoint suitable for H/native read guards.
  bool get isCurrent {
    try {
      if (!_active ||
          _used ||
          _owner._attempt != handoff.attempt ||
          !identical(_owner._inner, _inner)) {
        return false;
      }
      _owner._check(_options);
      return true;
    } catch (_) {
      return false;
    }
  }

  void dispatch() {
    if (!_active ||
        _used ||
        _owner._attempt != handoff.attempt ||
        !identical(_owner._inner, _inner)) {
      throw const PrivateTextFailure(PrivateTextReason.denied);
    }
    _used = true;
    _owner._check(_options);
    _owner.plan.recheckSanitation(_owner.currentRedactor());
    _owner._check(_options);
    _started = true;
    _owner.dispatchCount++;
    // The handled NON-Future carrier already exists. Mark started before actual
    // invocation, including synchronous throw. No await after final wire checks.
    _carrier._capture(
      () =>
          _inner.fetch(_options, Stream<Uint8List>.value(_wire), _cancelFuture),
    );
  }

  @override
  String toString() => 'PrivateTextDispatchCapsule';
}

/// Explicitly NOT a Future. Neither this carrier nor its private response is
/// returned by H's transaction/callback. Fast errors are consumed immediately.
final class _PrivateResponseCarrier {
  final _response = Completer<_HandledPrivateResponse>();
  bool _failed = false;
  void _capture(Future<ResponseBody> Function() fetch) {
    try {
      unawaited(
        fetch().then<void>(
          (body) => _response.complete(_HandledPrivateResponse._(body)),
          onError: (Object _, StackTrace _) => _fail(),
        ),
      );
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    _failed = true;
    _response.complete(const _HandledPrivateResponse.failed());
  }
}

enum _PrivateResponseKind { body, failed, cancelled }

final class _HandledPrivateResponse {
  const _HandledPrivateResponse._(this._body)
    : _kind = _PrivateResponseKind.body;
  const _HandledPrivateResponse.failed()
    : _body = null,
      _kind = _PrivateResponseKind.failed;
  const _HandledPrivateResponse.cancelled()
    : _body = null,
      _kind = _PrivateResponseKind.cancelled;
  final ResponseBody? _body;
  final _PrivateResponseKind _kind;
}
