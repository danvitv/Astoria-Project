import 'dart:convert';

import '../../credentials/secret_redactor.dart';
import '../provider_token_usage.dart';

export '../provider_token_usage.dart';

part 'native_tool_json.dart';

enum NativeToolReason {
  none,
  denied,
  notCurrent,
  cancelled,
  deadline,
  invalidRequest,
  malformed,
  unsupported,
  unknownTool,
  limit,
  httpStatus,
  transport,
  providerError,
}

/// Never retains provider text, URI, request, credential or underlying cause.
final class NativeToolException implements Exception {
  const NativeToolException(this.reason);
  final NativeToolReason reason;
  @override
  String toString() => 'Native tool request failed (${reason.name})';
}

abstract final class NativeToolLimits {
  static const jsonBytes = 65536;
  static const jsonNodes = 4096;
  static const jsonDepth = 16;
  static const requestBytes = 524288;
  static const responseBytes = 1048576;
  static const responseNodes = 16384;
  static const responseDepth = 32;
  static const textCharacters = 65536;
  static const contextCharacters = 262144;
  static const maxOutputTokens = 16384;
  // A provider request parameter is not the budget for decoding its response.
  // Match the saved profile's positive integer range without relaxing reply caps.
  static const maxRequestedOutputTokens = 0x7fffffff;
  static const messages = 514;
  static const definitions = 64;
  static const callsPerTurn = 8;
  static const callsPerSession = 32;
  static const rounds = 8;
  static const deadline = Duration(seconds: 180);
}

final class NativeToolDefinition {
  NativeToolDefinition({
    required String name,
    required String description,
    required Map<String, Object?> parameters,
  }) : name = _toolIdentifier(name, nameOnly: true),
       description = _toolText(description, max: 2048),
       parameters = _toolJsonObject(parameters) {
    _toolRequire(this.parameters['type'] == 'object');
  }
  final String name;
  final String description;
  final Map<String, Object?> parameters;
  @override
  String toString() => 'NativeToolDefinition';
}

final class NativeToolCall {
  NativeToolCall({
    required String id,
    required String name,
    required Map<String, Object?> arguments,
  }) : id = _toolIdentifier(id),
       name = _toolIdentifier(name, nameOnly: true),
       arguments = _toolJsonObject(arguments);
  final String id;
  final String name;
  final Map<String, Object?> arguments;
  @override
  String toString() => 'NativeToolCall';
}

final class NativeToolResult {
  NativeToolResult({
    required String callId,
    required String name,
    required Map<String, Object?> content,
  }) : callId = _toolIdentifier(callId),
       name = _toolIdentifier(name, nameOnly: true),
       content = _toolJsonObject(content);
  final String callId;
  final String name;
  final Map<String, Object?> content;
  @override
  String toString() => 'NativeToolResult';
}

enum NativeToolRole { system, user, assistant }

/// Initial prose only. Tool messages can originate only from validated replay.
final class NativeToolMessage {
  NativeToolMessage({required this.role, required String text})
    : text = _toolText(text, max: NativeToolLimits.textCharacters);
  final NativeToolRole role;
  final String text;
  @override
  String toString() => 'NativeToolMessage';
}

enum NativeToolStatus { complete, calls, error, stopped }

enum NativeToolDispatch { notAdmitted, admitted, admittedFailed }

final class NativeToolTurn {
  NativeToolTurn({
    required this.status,
    required this.dispatch,
    this.reason = NativeToolReason.none,
    this.text = '',
    List<NativeToolCall> calls = const [],
    this.actualUsage,
  }) : calls = _toolCallList(calls) {
    _toolText(text, max: NativeToolLimits.textCharacters);
  }
  final NativeToolStatus status;
  final NativeToolDispatch dispatch;
  final NativeToolReason reason;
  final String text;
  final List<NativeToolCall> calls;

  /// Returned provider JSON counters for THIS POST; never estimates/sums.
  final ProviderTokenUsage? actualUsage;
  @override
  String toString() => 'NativeToolTurn(${status.name}, ${reason.name})';
}
