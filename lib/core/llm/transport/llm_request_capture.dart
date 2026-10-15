import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../credentials/secret_redaction_patterns.dart';
import '../../credentials/secret_redactor.dart';
import 'chat_transport_request.dart';
import 'llm_capture_context.dart';

abstract interface class LlmRequestCaptureSink {
  FutureOr<void> record(LlmRequestCaptureEvent event);
}

final class SanitizedLlmRequest {
  const SanitizedLlmRequest({required this.request, required this.truncated});

  final Map<String, dynamic> request;
  final bool truncated;
}

/// Sanitized, immutable view of the request observed by the transport layer.
final class LlmRequestCaptureEvent {
  const LlmRequestCaptureEvent({
    required this.sequence,
    required this.createdAt,
    required this.protocol,
    required this.context,
    required this.request,
    required this.truncated,
  });

  final int sequence;
  final DateTime createdAt;
  final String? protocol;
  final LlmCaptureContext? context;
  final Map<String, dynamic> request;
  final bool truncated;

  Map<String, dynamic> toJson() => {
    'seq': sequence,
    'ts': createdAt.toIso8601String(),
    if (protocol != null) 'protocol': protocol,
    if (context != null) 'context': context!.toJson(),
    'truncated': truncated,
    ...request,
  };
}

/// Dispatches transport captures without making diagnostics part of request
/// success. A durable sink can be installed by application composition.
class LlmRequestCapture {
  LlmRequestCapture._();

  static LlmRequestCaptureSink? sink;
  static SecretRedactor? redactor;
  static final SecretRedactor _defaultRedactor = SecretRedactor(
    maxInputLength: _CaptureSanitizer._maxInspectionChars,
    maxOutputLength: _CaptureSanitizer._maxInspectionChars * 2,
    maxDepth: 32,
    maxNodes: 4096,
  );
  static SecretRedactor get _activeRedactor => redactor ?? _defaultRedactor;
  static int _sequence = 0;

  static bool get hasSink => sink != null;

  static LlmRequestCaptureEvent build(
    ChatTransportRequest request, {
    String? protocol,
  }) {
    final sanitizer = _CaptureSanitizer();
    final sanitized = _sanitizeRequest(request, sanitizer);
    final safeProtocol = protocol == null
        ? null
        : sanitizer.redactText(protocol);
    final safeContext = _sanitizeContext(request.captureContext, sanitizer);
    return LlmRequestCaptureEvent(
      sequence: _sequence++,
      createdAt: DateTime.now().toUtc(),
      protocol: safeProtocol,
      context: safeContext,
      request: sanitized.request,
      truncated: sanitizer.truncated,
    );
  }

  /// Returns the same credential-free payload used by captures without
  /// allocating a capture sequence or dispatching diagnostics.
  static SanitizedLlmRequest sanitizeRequest(ChatTransportRequest request) =>
      _sanitizeRequest(request, _CaptureSanitizer());

  static SanitizedLlmRequest _sanitizeRequest(
    ChatTransportRequest request,
    _CaptureSanitizer sanitizer,
  ) {
    return SanitizedLlmRequest(
      request: Map<String, dynamic>.unmodifiable({
        'protocolEndpoint': sanitizer.redactEndpoint(request.endpoint),
        'model': sanitizer.sanitize(request.model),
        'stream': request.stream,
        'maxTokens': request.maxTokens,
        'temperature': request.omitTemperature ? null : request.temperature,
        'topP': request.omitTopP ? null : request.topP,
        'topK': request.omitTopK ? null : request.topK,
        'frequencyPenalty': request.omitFrequencyPenalty
            ? null
            : request.frequencyPenalty,
        'presencePenalty': request.omitPresencePenalty
            ? null
            : request.presencePenalty,
        'requestReasoning': request.requestReasoning,
        'useResponsesApi': request.useResponsesApi,
        'omitReasoning': request.omitReasoning,
        'reasoningEffort': request.omitReasoningEffort
            ? null
            : request.reasoningEffort,
        'showNativeReasoning': request.showNativeReasoning,
        'sessionId': request.sessionId == null
            ? null
            : sanitizer.sanitize(request.sessionId),
        'cacheControlTtl': request.cacheControlTtl,
        'cacheBreakpointMode': request.cacheBreakpointMode,
        'sessionIdMode': request.sessionIdMode,
        'messageCount': request.messages.length,
        'messages': sanitizer.sanitize(request.messages),
        if (request.tools != null) 'toolCount': request.tools!.length,
        if (request.toolChoice != null)
          'toolChoice': sanitizer.sanitize(request.toolChoice),
      }),
      truncated: sanitizer.truncated,
    );
  }

  /// Records a call that does not go through a [ChatTransport] — image
  /// generation and embeddings talk to their own endpoints over Dio, so the
  /// transport decorator never sees them and the Requests timeline would show a
  /// turn with a hole where its picture or its vector search was.
  ///
  /// The event is shaped like a transport capture (`model`,
  /// `protocolEndpoint`, `messages`) so every reader keeps working, and the
  /// same sanitizer runs over it: no key, no oversized blob.
  static void recordAuxiliary({
    required String stage,
    required String endpoint,
    required String model,
    LlmCaptureContext? context,
    String? sessionId,
    String? messageId,
    String? pipelineRunId,
    String? agentId,
    List<Map<String, dynamic>> messages = const [],
    Map<String, dynamic> params = const {},
  }) {
    if (!hasSink) return;
    final sanitizer = _CaptureSanitizer();
    final sanitizedMessages = sanitizer.sanitize(messages);
    final sanitizedParams = _sanitizeAuxiliaryParams(params, sanitizer);
    final safeStage = sanitizer.redactText(stage);
    final safeContext = _sanitizeContext(
      context ??
          LlmCaptureContext(
            stage: stage,
            sessionId: sessionId,
            messageId: messageId,
            pipelineRunId: pipelineRunId,
            agentId: agentId,
          ),
      sanitizer,
    );
    final event = LlmRequestCaptureEvent(
      sequence: _sequence++,
      createdAt: DateTime.now().toUtc(),
      protocol: safeStage,
      context: safeContext,
      request: Map<String, dynamic>.unmodifiable({
        ...sanitizedParams,
        'protocolEndpoint': sanitizer.redactEndpoint(endpoint),
        'model': sanitizer.sanitize(model),
        'messageCount': messages.length,
        'messages': sanitizedMessages,
      }),
      truncated: sanitizer.truncated,
    );
    dispatch(event);
  }

  static Map<String, dynamic> _sanitizeAuxiliaryParams(
    Map<String, dynamic> params,
    _CaptureSanitizer sanitizer,
  ) {
    if (params.isEmpty) return const {};
    // The capture walk applies field/value/URL redaction before any fallback.
    // A second whole-tree redactJson pass has smaller aggregate budgets than
    // captures and can discard already-safe previews and normal diagnostics.
    final preSanitized = sanitizer.sanitize(params);
    if (preSanitized is Map<String, dynamic>) return preSanitized;
    return const {};
  }

  static void dispatch(LlmRequestCaptureEvent event) {
    final target = sink;
    if (target == null) return;
    try {
      // Public construction cannot bypass the selected diagnostic metadata
      // projection. The request retains its documented already-sanitized shape.
      final sanitizer = _CaptureSanitizer();
      final safeProtocol = event.protocol == null
          ? null
          : sanitizer.redactText(event.protocol!);
      final safeContext = _sanitizeContext(event.context, sanitizer);
      final result = target.record(
        LlmRequestCaptureEvent(
          sequence: event.sequence,
          createdAt: event.createdAt,
          protocol: safeProtocol,
          context: safeContext,
          request: event.request,
          truncated: event.truncated || sanitizer.truncated,
        ),
      );
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object _) {
            debugPrint('[LlmRequestCapture] sink failed (details omitted)');
          }),
        );
      }
    } catch (_) {
      debugPrint('[LlmRequestCapture] sink failed (details omitted)');
    }
  }

  static LlmCaptureContext? _sanitizeContext(
    LlmCaptureContext? context,
    _CaptureSanitizer sanitizer,
  ) {
    if (context == null) return null;
    String? text(String? value) =>
        value == null ? null : sanitizer.redactText(value);
    // Stable IDs are text values, not secret-named JSON fields. Preserve their
    // join semantics unless their actual contents require redaction.
    return LlmCaptureContext(
      stage: sanitizer.redactText(context.stage),
      sessionId: text(context.sessionId),
      messageId: text(context.messageId),
      pipelineRunId: text(context.pipelineRunId),
      callId: text(context.callId),
      parentCallId: text(context.parentCallId),
      logicalCallId: text(context.logicalCallId),
      relatedArtifactId: text(context.relatedArtifactId),
      agentId: text(context.agentId),
      stageOrdinal: context.stageOrdinal,
      attempt: context.attempt,
    );
  }
}

final class _CaptureSanitizer {
  _CaptureSanitizer([SecretRedactor? redactor])
    : _redactor = _captureRedactor(
        redactor ?? LlmRequestCapture._activeRedactor,
      );

  static SecretRedactor _captureRedactor(SecretRedactor source) {
    if (identical(source, LlmRequestCapture._defaultRedactor)) return source;
    // Extend only budgets, not secret visibility. Closed policies stay closed.
    return source.withKnownSecrets(
      const [],
      maxInputLength: _maxInspectionChars,
      maxOutputLength: _maxInspectionChars * 2,
      maxDepth: _maxDepth,
      maxNodes: _maxNodes,
    );
  }

  static const int _maxStringChars = 200000;
  static const int _maxInspectionChars = _maxStringChars * 2;
  static const int _dataPreviewChars = 96;
  static const int _maxDepth = 32;
  static const int _maxNodes = 4096;
  static final RegExp _defaultCandidatePattern = RegExp(
    r'[:=?&]|bearer|basic|sk-|gh[pousr]_|github_pat_|aiza|hf_|eyj',
    caseSensitive: false,
  );
  // Also cover fine-grained PATs when an older shared matcher is installed.
  static final RegExp _githubPatPattern = RegExp(
    r'\bgithub_pat_[A-Za-z0-9_]{22,}\b',
  );
  static final RegExp _querySecretPattern = RegExp(
    r'''([?&](?:api[_-]?key|key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|auth|password|passwd|sig|signature)=)([^&\s#"'\]]+)''',
    caseSensitive: false,
  );

  final SecretRedactor _redactor;
  final _visited = HashSet<Object>.identity();
  var _nodes = 0;
  bool truncated = false;

  String redactEndpoint(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '' : _redactor.redactUrl(trimmed);
  }

  dynamic sanitize(dynamic value, [int depth = 0]) {
    if (++_nodes > _maxNodes || depth > _maxDepth) {
      truncated = true;
      return SecretRedactor.limited;
    }
    if (value is String) return _sanitizeString(value);
    if (value is Map || value is List) {
      final container = value as Object;
      if (!_visited.add(container)) {
        truncated = true;
        return SecretRedactor.limited;
      }
      try {
        if (value is List) {
          if (value.length > _maxNodes - _nodes) {
            truncated = true;
            return SecretRedactor.limited;
          }
          return List<dynamic>.unmodifiable(
            value.map((item) => sanitize(item, depth + 1)),
          );
        }
        final map = value as Map;
        if (map.length > _maxNodes - _nodes) {
          truncated = true;
          return SecretRedactor.limited;
        }
        final safe = <String, dynamic>{};
        for (final entry in map.entries) {
          final key = entry.key;
          if (key is! String) return SecretRedactor.removed;
          final safeKey = redactText(key);
          final field = entry.value;
          if (SecretRedactor.isSecretField(key)) {
            safe[safeKey] = SecretRedactor.removed;
          } else if (SecretRedactionPatterns.isUrlField(key) &&
              field is String &&
              !field.startsWith('data:')) {
            safe[safeKey] = _redactor.redactUrl(field);
          } else {
            safe[safeKey] = sanitize(field, depth + 1);
          }
        }
        return Map<String, dynamic>.unmodifiable(safe);
      } finally {
        _visited.remove(container);
      }
    }
    if (value == null || value is int || value is bool) return value;
    if (value is double && value.isFinite) return value;
    return SecretRedactor.removed;
  }

  dynamic _sanitizeString(String value) {
    // Match against the complete bounded input BEFORE any visible cut. Neither
    // chunk offsets nor finite lookahead can guarantee arbitrary known widths.
    final redacted = redactText(value);
    if (value.startsWith('data:') && value.length > _dataPreviewChars) {
      truncated = true;
      final prefix = redacted.length <= _dataPreviewChars
          ? redacted
          : redacted.substring(0, _dataPreviewChars);
      return <String, dynamic>{
        'kind': 'redacted_data_uri',
        'prefix': prefix,
        'charCount': value.length,
        // Never fingerprint unseen source bytes, which may contain secrets.
        'sha256': sha256.convert(utf8.encode(prefix)).toString(),
      };
    }
    if (value.length <= _maxStringChars && redacted.length <= _maxStringChars) {
      return redacted;
    }
    truncated = true;
    final preview = redacted.length <= _maxStringChars
        ? redacted
        : redacted.substring(0, _maxStringChars);
    return <String, dynamic>{
      'kind': 'truncated_text',
      'text': preview,
      'charCount': value.length,
      'sha256': sha256.convert(utf8.encode(preview)).toString(),
    };
  }

  String redactText(String value) {
    if (value.length > _maxInspectionChars) {
      truncated = true;
      return SecretRedactor.limited;
    }
    if (value.isEmpty) return value;
    if (identical(_redactor, LlmRequestCapture._defaultRedactor) &&
        !_defaultCandidatePattern.hasMatch(value)) {
      return value;
    }
    final redacted = _redactor.redactText(value);
    if (redacted == SecretRedactor.limited) truncated = true;
    return redacted
        .replaceAll(_githubPatPattern, SecretRedactor.removed)
        .replaceAllMapped(
          _querySecretPattern,
          (match) => '${match.group(1)}${SecretRedactor.removed}',
        );
  }
}
