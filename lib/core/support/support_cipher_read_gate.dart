part of 'support_payload_cipher.dart';

/// Trusted native cancel/budget policy for ONE entire pure decrypt. Invoke the
/// thunk at most once while the gate is active; return its unchanged completed
/// plaintext or throw a fixed-safe [SupportCipherException]. Check ownership
/// before invocation and after awaits. No SQL, key access, retries or caching.
typedef SupportCipherReadGate =
    Future<String> Function(Future<String> Function() decryptPure);

final class _SupportCipherReadDelegate {
  const _SupportCipherReadDelegate(this.delegate, this.gate);
  final SupportPayloadCipher delegate;
  final SupportCipherReadGate gate;

  Future<String> run(Future<String> Function() decryptPure) =>
      _SupportCipherReadOperation(decryptPure).run(gate);
}

/// Per-read custody only. Clear closure/plaintext references on EVERY gate exit.
/// Original late crypto can finish cleanup, but cannot complete its exposed
/// thunk with plaintext once closed. No extra key/primitive/vault owner exists.
final class _SupportCipherReadOperation {
  _SupportCipherReadOperation(this._decryptPure);
  Future<String> Function()? _decryptPure;
  bool _open = true;
  bool _started = false;
  bool _violated = false;
  bool _completed = false;
  String? _plaintext;

  Future<String> run(SupportCipherReadGate gate) async {
    try {
      final result = await gate(_once);
      if (_violated || !_completed || result != _plaintext) _refuse();
      return result;
    } on SupportCipherException {
      rethrow;
    } catch (_) {
      _refuse();
    } finally {
      _open = false;
      _decryptPure = null;
      _plaintext = null;
    }
  }

  Future<String> _once() {
    final decryptPure = _decryptPure;
    if (!_open || _started || decryptPure == null) {
      _violated = true;
      return _observed(Future<String>.error(_failure));
    }
    _started = true;
    _decryptPure = null; // Escaped thunk no longer captures original inputs.
    final result = Future<String>.sync(decryptPure).then(
      (text) {
        if (!_open || _violated) _refuse();
        _completed = true;
        _plaintext = text;
        return text;
      },
      onError: (Object error, StackTrace _) {
        // Never format or retain raw causes. Ordinary safe failures survive.
        throw error is SupportCipherException ? error : _failure;
      },
    );
    return _observed(result);
  }

  static Future<String> _observed(Future<String> future) {
    // A canceled/misused gate may abandon its thunk. Observe late errors without
    // changing the future's result for a caller that still awaits it.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  static const _failure = SupportCipherException(
    SupportCipherFailure.invalidContext,
  );
  static Never _refuse() => throw _failure;
}
