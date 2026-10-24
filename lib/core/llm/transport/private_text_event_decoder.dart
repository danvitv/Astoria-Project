import 'dart:convert';

import 'llm_protocol.dart';
import 'private_text_outcome.dart';
import 'private_text_request.dart';

part 'private_text_openai_events.dart';
part 'private_text_provider_events.dart';

/// Parses only the admitted protocol's text lane, never a tool/action lane.
abstract class PrivateTextEventDecoder {
  factory PrivateTextEventDecoder(String protocol) => switch (protocol) {
    LlmProtocol.openaiResponses => _ResponsesEvents(),
    LlmProtocol.anthropic => _AnthropicEvents(),
    LlmProtocol.gemini => _GeminiEvents(),
    _ => _ChatEvents(),
  };
  PrivateTextEventDecoder._();

  final _text = StringBuffer();
  int _characters = 0;
  bool terminal = false;
  bool limited = false;
  ProviderTokenUsage? _usage;
  String get text => _text.toString();

  /// Only bounded numeric metadata from events accepted by this strict lane.
  ProviderTokenUsage? get usage => _usage;
  List<Map<String, dynamic>> consume(Map<String, dynamic> event);
  bool get acceptsDone => false;
  bool get canFinishAtEof => terminal;
  void done() => fail(PrivateTextReason.malformed);

  void _recordUsage(ProviderTokenUsage snapshot) {
    if (!snapshot.hasReportedTokens) return;
    _usage = _usage?.mergeSnapshot(snapshot) ?? snapshot;
  }

  void append(String delta) {
    if (_characters + delta.length > PrivateTextLimits.responseCharacters) {
      fail(PrivateTextReason.outputLimit);
    }
    require(utf8.decode(utf8.encode(delta)) == delta);
    _characters += delta.length;
    _text.write(delta);
  }

  Never fail(PrivateTextReason reason) => throw PrivateTextFailure(reason);
  void require(bool condition) {
    if (!condition) fail(PrivateTextReason.malformed);
  }

  /// Check nesting/token budgets before jsonDecode can materialize a tree.
  Map<String, dynamic> decode(String payload) {
    var depth = 0;
    var tokens = 0;
    var quoted = false;
    var escaped = false;
    for (final code in payload.codeUnits) {
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
        if (++tokens > 8192) fail(PrivateTextReason.wireLimit);
      } else if (code == 123 || code == 91) {
        if (++depth > 32 || ++tokens > 8192) fail(PrivateTextReason.wireLimit);
      } else if (code == 125 || code == 93) {
        depth--;
      } else if (code == 44) {
        if (++tokens > 8192) fail(PrivateTextReason.wireLimit);
      }
    }
    try {
      final decoded = jsonDecode(payload);
      require(decoded is Map<String, dynamic>);
      return decoded as Map<String, dynamic>;
    } on PrivateTextFailure {
      rethrow;
    } catch (_) {
      fail(PrivateTextReason.malformed);
    }
  }
}

// Optional metadata is not prose authority. Wrong shapes remain unknown, with
// no conversion, raw-object retention, provider error, or logging fallback.
Map<dynamic, dynamic> _usageMap(Object? value) =>
    value is Map<dynamic, dynamic> ? value : const <String, Object?>{};
int? _tokenCount(Map<dynamic, dynamic> map, String field) =>
    map[field] is int ? map[field] as int : null;
