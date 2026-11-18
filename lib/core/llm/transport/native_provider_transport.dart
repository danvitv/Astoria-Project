import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../credentials/native_provider_credentials.dart';
import '../../credentials/secret_redactor.dart';
import '../converters/cache_breakpoint_marker.dart';
import '../converters/openrouter_messages.dart';
import '../converters/prompt_post_processing.dart';
import '../converters/structured_response.dart';
import 'anthropic_chat_transport.dart';
import 'chat_transport.dart';
import 'chat_transport_completion_metadata.dart';
import 'chat_transport_request.dart';
import 'gemini_chat_transport.dart';
import 'llm_protocol.dart';
import 'openai_chat_transport.dart';
import 'openai_responses_transport.dart';
import 'openrouter_chat_transport.dart';
import 'private_text_event_decoder.dart';
import 'private_text_request.dart';
import 'private_text_transport.dart';
import 'transport_factory.dart';

part 'native_provider_transport_factory.dart';
part 'native_provider_request_plan.dart';
part 'native_provider_final_adapter.dart';
part 'native_provider_stream_frames.dart';
part 'native_provider_output_gate.dart';
part 'native_provider_event_projection.dart';
part 'native_provider_completion_projection.dart';
part 'native_provider_wire_job.dart';
part 'native_provider_private_text_dispatcher.dart';
part 'native_provider_private_gemini_auth_adapter.dart';
part 'native_provider_source_current.dart';

/// Fixed public diagnostics only; never retain a Dio/provider/URI/key cause.
enum NativeProviderTransportReason {
  denied,
  notCurrent,
  cancelled,
  deadline,
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
  sanitationLimit,
}

final class NativeProviderTransportException implements Exception {
  const NativeProviderTransportException(this.reason);
  final NativeProviderTransportReason reason;
  @override
  String toString() => 'Native provider request failed (${reason.name})';
}

abstract final class NativeProviderTransportLimits {
  static const requestBytes = 524288;
  static const contextCharacters = 262144;
  static const outputCharacters = 65536;
  static const frameBytes = 262144;
  static const wireBytes = 2097152;
  static const frames = 8192;
  static const deadline = Duration(seconds: 180);
  static const drainDeadline = Duration(seconds: 1);
}

Never _nativeFail(NativeProviderTransportReason reason) =>
    throw NativeProviderTransportException(reason);

bool _nativeCurrent(bool Function() check) {
  try {
    return check();
  } catch (_) {
    return false;
  }
}

void _nativeRequire(
  bool condition, [
  NativeProviderTransportReason reason =
      NativeProviderTransportReason.malformed,
]) {
  if (!condition) _nativeFail(reason);
}

NativeProviderTransportReason _credentialReason(
  NativeProviderFailure failure,
) => failure == NativeProviderFailure.stale
    ? NativeProviderTransportReason.notCurrent
    : failure == NativeProviderFailure.unavailable
    ? NativeProviderTransportReason.transport
    : NativeProviderTransportReason.denied;
