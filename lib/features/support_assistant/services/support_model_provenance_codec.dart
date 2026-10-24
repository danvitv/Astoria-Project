import 'dart:convert';

import '../models/support_model_provenance.dart';

part 'support_model_provenance_json_scanner.dart';
part 'support_model_provenance_graph_verifier.dart';

/// Pure codec for dedicated encrypted provenance, not a general serializer.
///
/// Trusted native integration supplies only already selected metadata. It must
/// independently obtain strict local/model leases for EVERY full selected range
/// before owning reads, and validate current intent/source/run at admission.
/// Neither decoding nor coverage grants rights, loads data, or approves egress.
abstract final class SupportModelProvenanceCodec {
  static const marker = 'support.model_provenance';
  static const version = 1;

  /// Returns plaintext solely for the owning encrypted-storage write boundary.
  /// Does not encrypt. Never pass this record to model prompts or reports.
  static String encodeForEncryptedStorage(SupportModelProvenance recipe) {
    final encoded = _ProvenanceStorageWriter().encode(recipe);
    // Same pre-decode budget on both directions. No arbitrary object serializer.
    _ProvenanceJsonScanner(encoded).check();
    return encoded;
  }

  /// Accepts plaintext already decrypted by the dedicated selected-row owner.
  /// Missing/unknown records stay unavailable; there is no legacy clean default.
  static SupportModelProvenanceDecodeResult decodeFromEncryptedStorage(
    String encoded,
  ) {
    try {
      _ProvenanceJsonScanner(encoded).check();
      final value = jsonDecode(encoded);
      final direct = value is Map<String, dynamic> && value['version'] == 2;
      final root = _object(value, {
        'marker',
        'version',
        'supportSessionId',
        'replyMessageId',
        'runId',
        'currentUserMessageId',
        'originalRanges',
        'directReplies',
        if (direct) 'currentConversationMessageIds',
      });
      if (root['marker'] != marker ||
          root['version'] is! int ||
          (root['version'] != version && root['version'] != 2)) {
        _reject(SupportModelProvenanceFailure.unsupportedFormat);
      }
      final ranges = _array(root['originalRanges']);
      final references = _array(root['directReplies']);
      if (ranges.length + references.length >
          SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
        _reject(SupportModelProvenanceFailure.limitExceeded);
      }
      final recipe = SupportModelProvenance(
        supportSessionId: _string(root['supportSessionId']),
        replyMessageId: _string(root['replyMessageId']),
        runId: _string(root['runId']),
        currentUserMessageId: _string(root['currentUserMessageId']),
        originalRanges: [for (final range in ranges) _range(range)],
        directReplies: [
          for (final reference in references) _reference(reference),
        ],
        currentConversationMessageIds: direct
            ? _conversationIds(root['currentConversationMessageIds'])
            : null,
      );
      return SupportModelProvenanceDecodeResult.valid(recipe);
    } on SupportModelProvenanceException catch (error) {
      return SupportModelProvenanceDecodeResult.unavailable(error.failure);
    } on FormatException {
      return const SupportModelProvenanceDecodeResult.unavailable(
        SupportModelProvenanceFailure.invalidEncoding,
      );
    }
  }

  /// Verifies one proposed reply plus the explicitly selected bounded DAG.
  ///
  /// The proposed recipe must declare the exact full selected ranges and every
  /// selected support assistant in native order. Stored ranges are covered only
  /// as same-domain/session ordered subsequences, never replaced or relabelled.
  /// The proposed current input/reply must NOT occur in historical selection.
  /// Success is metadata consistency ONLY, conjunctive with real native leases.
  static SupportModelProvenanceCoverageResult verifySelectedContext({
    required SupportModelProvenance proposedReply,
    required List<SupportModelSourceRange> selectedRanges,
    required List<SupportModelSelectedSupportMessage> selectedSupportMessages,
  }) {
    try {
      if (proposedReply.currentConversationMessageIds != null ||
          selectedSupportMessages.any(
            (m) => m.provenance?.currentConversationMessageIds != null,
          )) {
        // v1 range authority cannot interpret v2 direct-current-chat consent.
        _reject(SupportModelProvenanceFailure.unavailableRecipe);
      }
      return _ProvenanceGraphVerifier(
        proposedReply,
        selectedRanges,
        selectedSupportMessages,
      ).verify();
    } on SupportModelProvenanceException catch (error) {
      return SupportModelProvenanceCoverageResult.unavailable(error.failure);
    }
  }
}

Never _reject(SupportModelProvenanceFailure failure) =>
    throw SupportModelProvenanceException(failure);

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic>) {
    _reject(SupportModelProvenanceFailure.invalidEncoding);
  }
  for (final key in value.keys) {
    if (!keys.contains(key)) {
      _reject(SupportModelProvenanceFailure.unknownField);
    }
  }
  if (value.length != keys.length) {
    _reject(SupportModelProvenanceFailure.invalidEncoding);
  }
  return value;
}

List<dynamic> _array(Object? value) {
  if (value is! List<dynamic>) {
    _reject(SupportModelProvenanceFailure.invalidEncoding);
  }
  if (value.length >
      SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
    _reject(SupportModelProvenanceFailure.limitExceeded);
  }
  return value;
}

String _string(Object? value) {
  if (value is! String) _reject(SupportModelProvenanceFailure.invalidEncoding);
  return value;
}

List<String> _conversationIds(Object? value) {
  if (value is! List<dynamic> ||
      value.length > SupportModelProvenanceLimits.maxIdsPerSource) {
    _reject(SupportModelProvenanceFailure.limitExceeded);
  }
  return [for (final id in value) _string(id)];
}

SupportModelSourceRange _range(Object? value) {
  final source = _object(value, const {
    'domain',
    'sessionId',
    'orderedMessageIds',
  });
  final domain = switch (source['domain']) {
    'support' => SupportModelSourceDomain.support,
    'game' => SupportModelSourceDomain.game,
    _ => _reject(SupportModelProvenanceFailure.invalidSource),
  };
  final ids = source['orderedMessageIds'];
  if (ids is! List<dynamic>) {
    _reject(SupportModelProvenanceFailure.invalidEncoding);
  }
  if (ids.length > SupportModelProvenanceLimits.maxIdsPerSource) {
    _reject(SupportModelProvenanceFailure.limitExceeded);
  }
  return SupportModelSourceRange(
    domain: domain,
    sessionId: _string(source['sessionId']),
    orderedMessageIds: [for (final id in ids) _string(id)],
  );
}

SupportModelReplyReference _reference(Object? value) {
  final reference = _object(value, const {'sessionId', 'messageId', 'runId'});
  return SupportModelReplyReference(
    sessionId: _string(reference['sessionId']),
    messageId: _string(reference['messageId']),
    runId: _string(reference['runId']),
  );
}

/// Appends only fixed syntax and bounded primitive strings. Refuses before the
/// output buffer exceeds the raw cap, even for highly escaped identifier text.
/// jsonEncode is called only on actual Strings, never on caller-owned objects.
final class _ProvenanceStorageWriter {
  final buffer = StringBuffer();
  var length = 0;

  String encode(SupportModelProvenance recipe) {
    _append('{"marker":');
    _text(SupportModelProvenanceCodec.marker);
    _append(
      recipe.currentConversationMessageIds == null
          ? ',"version":1,"supportSessionId":'
          : ',"version":2,"supportSessionId":',
    );
    _text(recipe.supportSessionId);
    _append(',"replyMessageId":');
    _text(recipe.replyMessageId);
    _append(',"runId":');
    _text(recipe.runId);
    _append(',"currentUserMessageId":');
    _text(recipe.currentUserMessageId);
    _append(',"originalRanges":[');
    for (var i = 0; i < recipe.originalRanges.length; i++) {
      if (i != 0) _append(',');
      final range = recipe.originalRanges[i];
      _append('{"domain":');
      _text(range.domain.name);
      _append(',"sessionId":');
      _text(range.sessionId);
      _append(',"orderedMessageIds":[');
      for (var j = 0; j < range.orderedMessageIds.length; j++) {
        if (j != 0) _append(',');
        _text(range.orderedMessageIds[j]);
      }
      _append(']}');
    }
    _append('],"directReplies":[');
    for (var i = 0; i < recipe.directReplies.length; i++) {
      if (i != 0) _append(',');
      final reference = recipe.directReplies[i];
      _append('{"sessionId":');
      _text(reference.sessionId);
      _append(',"messageId":');
      _text(reference.messageId);
      _append(',"runId":');
      _text(reference.runId);
      _append('}');
    }
    _append(']');
    final conversation = recipe.currentConversationMessageIds;
    if (conversation != null) {
      _append(',"currentConversationMessageIds":[');
      for (var i = 0; i < conversation.length; i++) {
        if (i != 0) _append(',');
        _text(conversation[i]);
      }
      _append(']');
    }
    _append('}');
    return buffer.toString();
  }

  void _text(String text) => _append(jsonEncode(text));

  void _append(String text) {
    if (text.length > SupportModelProvenanceLimits.maxRawCharacters - length) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    length += text.length;
    buffer.write(text);
  }
}
