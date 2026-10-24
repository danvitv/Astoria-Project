import '../provider_token_usage.dart';

export '../provider_token_usage.dart' show ProviderTokenUsage;

/// No provider objects, credentials, raw events, or reasoning text cross this API.
enum PrivateTextStatus { complete, partial, stopped, limited, error }

/// Actual adapter invocation, not socket-byte/remote-receipt proof.
enum PrivateTextDispatch { notAdmitted, admitted, admittedFailed }

enum PrivateTextReason {
  none,
  cancelled,
  notCurrent,
  denied,
  invalidRequest,
  unsupported,
  httpStatus,
  transport,
  malformed,
  unexpectedEof,
  providerError,
  providerLimit,
  outputLimit,
  wireLimit,
  deadline,
  sanitationLimit,
  admittedFailed,
}

final class PrivateTextOutcome {
  const PrivateTextOutcome({
    required this.status,
    required this.text,
    this.reason = PrivateTextReason.none,
    this.httpStatus,
    this.dispatch = PrivateTextDispatch.notAdmitted,
    this.usage,
  });

  final PrivateTextStatus status;

  /// Whole-buffer sanitized text only. Never an incremental provider delta.
  final String text;
  final PrivateTextReason reason;
  final int? httpStatus;
  final PrivateTextDispatch dispatch;

  /// Numeric evidence from accepted strict events of this request only. It
  /// does not prove completion and may be incomplete on partial/stopped runs.
  final ProviderTokenUsage? usage;

  @override
  String toString() => 'PrivateTextOutcome(${status.name}, ${reason.name})';
}

/// Native authorization receives only the credential-free reviewed recipient.
/// Bind source/run/configuration custody in the injected callback's closure.
final class PrivateTextHandoff {
  const PrivateTextHandoff({
    required this.protocol,
    required this.recipient,
    required this.model,
    required this.attempt,
  });

  final String protocol;
  final Uri recipient;
  final String model;
  final int attempt;
  String get method => 'POST';

  @override
  String toString() => 'PrivateTextHandoff';
}

/// Fixed budgets, measured before allocation of a provider JSON event.
abstract final class PrivateTextLimits {
  static const currentCharacters = 8192;
  static const contextCharacters = 65536;
  static const contextBytes = 262144;
  static const responseCharacters = 65536;
  static const frameBytes = 262144;
  static const wireBytes = 2097152;
  static const requestBytes = 524288;
  static const messages = 514;
  static const deadline = Duration(seconds: 180);
}
