import 'dart:convert';

import '../transport/chat_transport_request.dart';
import '../transport/chat_transport_completion_metadata.dart';
import 'generation_context_planning_facts.dart';
import 'studio_request_budget_facts.dart';

/// Only fields read from the constructed request / original stream callbacks.
/// This is not a provider body, token accounting or proof of sampler effects.
abstract final class StudioRuntimeCallFacts {
  static const versionKey = 'studioCallFactsVersion';
  static const maxPayloadBytes = 8192;
  static const _countLimit = 16777216;
  static const _timeLimit = 86400000;
  static const _requestNumbers = <String, (num, num)>{
    'messageCount': (0, 4096),
    'textContentCodeUnits': (0, _countLimit),
    'textPartCount': (0, 65536),
    'imagePartCount': (0, 65536),
    'maxTokens': (1, 1048576),
    'temperature': (0, 2),
    'topP': (0, 1),
    'topK': (0, 1048576),
    'frequencyPenalty': (-2, 2),
    'presencePenalty': (-2, 2),
    'extraParameterCount': (0, 256),
    'toolCount': (0, 256),
  };
  static const _requestBooleans = {
    'contentShapeKnown',
    'stream',
    'requestReasoning',
    'useResponsesApi',
    'omitTemperature',
    'omitTopP',
    'omitTopK',
    'omitFrequencyPenalty',
    'omitPresencePenalty',
    'omitReasoning',
    'omitReasoningEffort',
    'responseSchemaPresent',
  };
  static const _streamNumbers = <String, (num, num)>{
    'elapsedMs': (0, _timeLimit),
    'chunkCount': (0, _countLimit),
    'firstChunkMs': (0, _timeLimit),
    'maxChunkGapMs': (0, _timeLimit),
    'contentDeltaCodeUnits': (0, _countLimit),
    'reasoningDeltaCodeUnits': (0, _countLimit),
  };
  static const _efforts = {'auto', 'min', 'low', 'medium', 'high', 'max'};
  static const _completions = {
    'complete',
    'idle_timeout',
    'cancel_with_streamed_text',
    'timeout',
    'cancelled',
    'error',
  };
  static const _terminations = {'terminal', 'eof'};
  static const _finishReasons = {
    'stop',
    'length',
    'content_filter',
    'tool_calls',
    'function_call',
  };
  static const _wireProtocols = {
    'openai_chat',
    'openai_responses',
    'anthropic_messages',
    'gemini_generate_content',
  };
  static const _wireFinishReasons = {
    'stop',
    'length',
    'content_filter',
    'tool_calls',
    'function_call',
    'stop_sequence',
    'refusal',
    'pause_turn',
    'other',
  };
  static const _wireReasonSources = {
    'openai_finish_reason',
    'openai_finish_reason_absent',
    'anthropic_stop_reason',
    'anthropic_stop_reason_absent',
    'gemini_finish_reason',
    'gemini_finish_reason_absent',
    'responses_status',
    'responses_incomplete_reason',
    'responses_status_absent',
  };
  static const _wireTerminations = {
    'done_marker',
    'finish_reason_eof',
    'message_stop',
    'response_completed',
    'stream_eof_after_output',
    'one_shot_response',
    'one_shot_sse_body',
  };

  static Map<String, Object?> constructedRequest(ChatTransportRequest request) {
    var textUnits = 0, textParts = 0, imageParts = 0, parts = 0;
    var known = request.messages.length <= 4096;
    if (known) {
      for (final message in request.messages) {
        final content = message['content'];
        if (content is String) {
          textUnits += content.length;
        } else if (content is List && content.length <= 65536 - parts) {
          parts += content.length;
          for (final part in content) {
            if (part is Map &&
                part['type'] == 'text' &&
                part['text'] is String) {
              textParts++;
              textUnits += (part['text'] as String).length;
            } else if (part is Map && part['type'] == 'image_url') {
              imageParts++;
            } else {
              known = false;
              break;
            }
          }
        } else {
          known = false;
        }
        if (!known || textUnits > _countLimit) {
          known = false;
          break;
        }
      }
    }
    return Map.unmodifiable({
      'messageCount': request.messages.length,
      'contentShapeKnown': known,
      if (known) ...{
        'textContentCodeUnits': textUnits,
        'textPartCount': textParts,
        'imagePartCount': imageParts,
      },
      'maxTokens': request.maxTokens,
      'temperature': request.temperature,
      'topP': request.topP,
      'topK': request.topK,
      'frequencyPenalty': request.frequencyPenalty,
      'presencePenalty': request.presencePenalty,
      'stream': request.stream,
      'requestReasoning': request.requestReasoning,
      'useResponsesApi': request.useResponsesApi,
      'reasoningEffort': request.reasoningEffort,
      'omitTemperature': request.omitTemperature,
      'omitTopP': request.omitTopP,
      'omitTopK': request.omitTopK,
      'omitFrequencyPenalty': request.omitFrequencyPenalty,
      'omitPresencePenalty': request.omitPresencePenalty,
      'omitReasoning': request.omitReasoning,
      'omitReasoningEffort': request.omitReasoningEffort,
      'showNativeReasoning': request.showNativeReasoning,
      'responseSchemaPresent': request.responseJsonSchema != null,
      'extraParameterCount': request.extraRequestParameters.length,
      'toolCount': request.tools?.length ?? 0,
    });
  }

  static String? termination(Object? value) =>
      _terminations.contains(value) ? value as String : null;
  static String? finishReason(Object? value) =>
      _finishReasons.contains(value) ? value as String : null;

  static Map<String, dynamic> payload({
    required Map<String, Object?> request,
    required int elapsedMs,
    required int chunkCount,
    required int? firstChunkMs,
    required int maxChunkGapMs,
    required int contentOffset,
    required int reasoningOffset,
    required String completionReason,
    String? streamTermination,
    String? callbackFinishReason,
    Map<String, Object?>? contextPlanning,
    Map<String, Object?>? studioRequestBudget,
    ChatTransportCompletionMetadata? transportCompletion,
  }) {
    if (contextPlanning != null && studioRequestBudget != null) return const {};
    final candidate = <String, Object?>{
      versionKey: contextPlanning != null
          ? 2
          : studioRequestBudget?['historySelectionPolicy'] != null
          ? 4
          : studioRequestBudget != null
          ? 3
          : 1,
      'constructedRequest': request,
      'streamObservation': {
        'elapsedMs': elapsedMs,
        'chunkCount': chunkCount,
        'firstChunkMs': firstChunkMs,
        'maxChunkGapMs': maxChunkGapMs,
        'contentDeltaCodeUnits': contentOffset,
        'reasoningDeltaCodeUnits': reasoningOffset,
        'completionBranch': _completions.contains(completionReason)
            ? completionReason
            : 'error',
        'streamTermination': termination(streamTermination),
        'callbackFinishReason': finishReason(callbackFinishReason),
        if (transportCompletion != null) ...{
          'wireProtocol': transportCompletion.wireProtocol,
          'wireFinishReason': transportCompletion.finishReason,
          'wireFinishReasonSource': transportCompletion.finishReasonSource,
          'wireTermination': transportCompletion.termination,
        },
      },
      'contextPlanning': ?contextPlanning,
      'studioRequestBudget': ?studioRequestBudget,
    };
    // Never let NaN, infinities, unknown strings or unbounded counts reach JSON.
    return validate(candidate) == null ? const {} : Map.unmodifiable(candidate);
  }

  /// Called only AFTER native event columns/identity/truncation are recognized.
  /// A bad optional payload cannot erase an independently known runtime outcome.
  static Map<String, Object?>? fromSavedPayload(Object? raw) {
    if (raw is! String ||
        raw.length > maxPayloadBytes ||
        utf8.encode(raw).length > maxPayloadBytes) {
      return null;
    }
    // The native contract is exactly two object levels and has no arrays.
    // Bound structure BEFORE decoding or re-encoding an adversarial saved unit.
    var depth = 0;
    var quoted = false, escaped = false;
    for (final code in raw.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (code == 92) {
          escaped = true;
        } else if (code == 34) {
          quoted = false;
        }
      } else if (code == 34) {
        quoted = true;
      } else if (code == 123) {
        if (++depth > 2) return null;
      } else if (code == 125) {
        if (--depth < 0) return null;
      } else if (code == 91 || code == 93) {
        return null;
      }
    }
    if (depth != 0 || quoted) return null;
    try {
      final decoded = jsonDecode(raw);
      // The native sink writes canonical jsonEncode output. Duplicate keys,
      // alternate escaped keys and partial/truncated units are not that output.
      if (jsonEncode(decoded) != raw) return null;
      return validate(decoded);
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? validate(Object? value) {
    if (value is! Map<String, Object?> ||
        value[versionKey] is! int ||
        !value.containsKey('constructedRequest') ||
        !value.containsKey('streamObservation')) {
      return null;
    }
    final version = value[versionKey] as int;
    final context = value['contextPlanning'];
    final studioBudget = value['studioRequestBudget'];
    if ((version == 1 && (value.length != 3 || context != null)) ||
        (version == 2 &&
            (value.length != 4 ||
                GenerationContextPlanningFacts.validate(context) == null)) ||
        (version == 3 &&
            (value.length != 4 ||
                StudioRequestBudgetFacts.validate(studioBudget) == null ||
                StudioRequestBudgetFacts.validate(
                      studioBudget,
                    )?['historySelectionPolicy'] !=
                    null)) ||
        (version == 4 &&
            (value.length != 4 ||
                StudioRequestBudgetFacts.validate(
                      studioBudget,
                    )?['historySelectionPolicy'] ==
                    null)) ||
        (version != 1 && version != 2 && version != 3 && version != 4)) {
      return null;
    }
    final request = value['constructedRequest'];
    final stream = value['streamObservation'];
    if (request is! Map<String, Object?> ||
        stream is! Map<String, Object?> ||
        !_fields(
          request,
          _requestNumbers,
          _requestBooleans,
          {'reasoningEffort': _efforts},
          const {'reasoningEffort', 'showNativeReasoning'},
        ) ||
        !_fields(
          stream,
          _streamNumbers,
          const {},
          {
            'completionBranch': _completions,
            'streamTermination': _terminations,
            'callbackFinishReason': _finishReasons,
            'wireProtocol': _wireProtocols,
            'wireFinishReason': _wireFinishReasons,
            'wireFinishReasonSource': _wireReasonSources,
            'wireTermination': _wireTerminations,
          },
          const {
            'firstChunkMs',
            'streamTermination',
            'callbackFinishReason',
            'wireFinishReason',
          },
        )) {
      return null;
    }
    final known = request['contentShapeKnown'] == true;
    final requiredRequest = {
      ..._requestNumbers.keys,
      ..._requestBooleans,
      'reasoningEffort',
      'showNativeReasoning',
    };
    if (!known) {
      requiredRequest.removeAll({
        'textContentCodeUnits',
        'textPartCount',
        'imagePartCount',
      });
    }
    if (request.length != requiredRequest.length ||
        !request.keys.toSet().containsAll(requiredRequest) ||
        (stream.length != 9 && stream.length != 13) ||
        !stream.keys.toSet().containsAll({
          ..._streamNumbers.keys,
          'completionBranch',
          'streamTermination',
          'callbackFinishReason',
          if (stream.length == 13) ...{
            'wireProtocol',
            'wireFinishReason',
            'wireFinishReasonSource',
            'wireTermination',
          },
        })) {
      return null;
    }
    final chunks = stream['chunkCount'] as int;
    final first = stream['firstChunkMs'];
    final elapsed = stream['elapsedMs'] as int;
    if ((chunks == 0) != (first == null) ||
        (first is int && first > elapsed) ||
        (stream['maxChunkGapMs'] as int) > elapsed ||
        (chunks < 2 && stream['maxChunkGapMs'] != 0) ||
        (chunks == 0 &&
            (stream['contentDeltaCodeUnits'] != 0 ||
                stream['reasoningDeltaCodeUnits'] != 0)) ||
        (stream['contentDeltaCodeUnits'] as int) +
                (stream['reasoningDeltaCodeUnits'] as int) <
            chunks ||
        (known &&
            (request['textPartCount'] as int) +
                    (request['imagePartCount'] as int) >
                65536) ||
        (stream['completionBranch'] != 'complete' &&
            (stream['streamTermination'] != null ||
                stream['callbackFinishReason'] != null ||
                stream.length == 13)) ||
        (stream.length == 13 && !_wireMetadataConsistent(stream))) {
      return null;
    }
    return {
      // Public native metadata uses a non-secret label for request.maxTokens.
      // Keep the saved contract unchanged and keep WHOLE-unit redaction: no
      // generic token-field exception or known-secret bypass is introduced.
      'constructedRequest': Map<String, Object?>.unmodifiable({
        for (final entry in request.entries)
          (entry.key == 'maxTokens' ? 'configuredOutputLimit' : entry.key):
              entry.value,
      }),
      'streamObservation': Map<String, Object?>.unmodifiable(stream),
      if (version == 2)
        'contextPlanning': GenerationContextPlanningFacts.validate(context)!,
      if (version == 3 || version == 4)
        'studioRequestBudget': StudioRequestBudgetFacts.validate(studioBudget)!,
      'requestEvidence': 'constructed_provider_neutral_request_only',
      'contextEvidence': switch (version) {
        2 => 'recorded_prompt_builder_plan_not_provider_accounting',
        3 => 'constructed_studio_request_budget_not_provider_accounting',
        4 => 'recorded_studio_history_selection_not_provider_accounting',
        _ => 'constructed_message_counts_not_context_budget',
      },
      'streamEvidence': 'original_callback_counts_and_elapsed_time',
      'lengthUnit': 'utf16_code_units_not_tokens',
      'completionMetadataSource': stream.length == 13
          ? 'provider_wire_parser_finite_projection'
          : 'transport_callback_may_be_synthetic',
      'providerFinishReason': stream.length == 13
          ? stream['wireFinishReason'] ?? 'not_reported_by_provider'
          : 'unknown_not_attested',
      'providerWireNormalization': stream.length == 13
          ? 'observed_by_${stream['wireProtocol']}'
          : 'unknown_not_observed',
      'providerSamplerBehavior': 'unknown_not_observed',
    };
  }

  static bool _fields(
    Map<String, Object?> fields,
    Map<String, (num, num)> numbers,
    Set<String> booleans,
    Map<String, Set<String>> enums,
    Set<String> nullable,
  ) {
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value == null && nullable.contains(key)) continue;
      final range = numbers[key];
      if (range != null) {
        final real = const {
          'temperature',
          'topP',
          'frequencyPenalty',
          'presencePenalty',
        }.contains(key);
        if (value is! num ||
            !value.isFinite ||
            (!real && value is! int) ||
            value < range.$1 ||
            value > range.$2) {
          return false;
        }
      } else if (booleans.contains(key) || key == 'showNativeReasoning') {
        if (value is! bool) return false;
      } else if (enums.containsKey(key)) {
        if (!enums[key]!.contains(value)) return false;
      } else {
        return false;
      }
    }
    return true;
  }

  static bool _wireMetadataConsistent(Map<String, Object?> stream) {
    final protocol = stream['wireProtocol'];
    final source = stream['wireFinishReasonSource'];
    final finish = stream['wireFinishReason'];
    if (source is! String || (finish == null) != source.endsWith('_absent')) {
      return false;
    }
    return switch (protocol) {
      'openai_chat' => source.startsWith('openai_'),
      'openai_responses' => source.startsWith('responses_'),
      'anthropic_messages' => source.startsWith('anthropic_'),
      'gemini_generate_content' => source.startsWith('gemini_'),
      _ => false,
    };
  }
}
