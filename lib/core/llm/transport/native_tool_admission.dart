part of 'native_tool_transport.dart';

typedef NativeToolAdmission =
    Future<bool> Function(NativeToolDispatchCapsule capsule);

/// Metadata for the original native owner. Tool/prose data is not an authority.
final class NativeToolHandoff {
  const NativeToolHandoff._(
    this.recipient,
    this.protocol,
    this.model,
    this.round,
    this.requestBytes,
  );
  final Uri recipient;
  final String protocol;
  final String model;
  final int round;
  final int requestBytes;
  @override
  String toString() => 'NativeToolHandoff';
}

/// Invoke dispatch INSIDE the original fresh-source/admission critical section.
/// The native POST begins synchronously after all callback/factory fences. This
/// is not serializable, reusable, a key carrier, or an approval issuer.
final class NativeToolDispatchCapsule {
  NativeToolDispatchCapsule._(_ToolWireJob job)
    : _job = job,
      handoff = NativeToolHandoff._(
        job.binding.route.endpoint,
        job.session._request.config.protocol,
        job.binding.connection.model,
        job.session._round + 1,
        utf8.encode(job.json).length,
      );
  _ToolWireJob? _job;
  bool _consumed = false;
  final NativeToolHandoff handoff;
  bool get isCurrent =>
      !_consumed &&
      (_job?.session._current() ?? false) &&
      (_job?.binding.isCurrent ?? false) &&
      !_consumed;
  void dispatch() {
    _ntRequire(isCurrent, NativeToolReason.notCurrent);
    final job = _job!;
    _consumed = true;
    job.dispatch();
  }

  void _retire() {
    _consumed = true;
    _job = null;
  }

  @override
  String toString() => 'NativeToolDispatchCapsule';
}
