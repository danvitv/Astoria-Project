import '../models/chat_message.dart';
import 'canon_evidence_text.dart';

/// One deterministic embedding query, not a second model or a canon summary.
abstract final class MessageRecallQuery {
  static const maxChars = 2400;
  static const maxRecentMessages = 4;
  static const _latestChars = 1200;
  static const _recentChars = 400;
  static final _scaffoldTag = RegExp(
    r'<(/?)(thought|think|thinking|reasoning|analysis|scratchpad|tool_call|tool_result|recalled_messages|studio_session_state)\b[^>]*>',
    caseSensitive: false,
  );
  static final _wireToken = RegExp(r'<\|[^\r\n]*?\|>');

  static String build({
    required String currentText,
    List<ChatMessage> history = const [],
  }) {
    final eligible = history.where(_eligible).toList(growable: false);
    final latest = history.isNotEmpty && history.last.content == currentText
        ? history.last
        : null;
    final current = latest != null && !_eligible(latest)
        ? ''
        : project(latest?.role ?? 'user', currentText);
    final parts = <String>[];
    if (current.isNotEmpty) {
      parts.add(
        '${latest?.role ?? 'user'}: ${_bounded(current, _latestChars)}',
      );
    }
    final recent = eligible.reversed
        .where((message) => !identical(message, latest))
        .take(maxRecentMessages)
        .toList();
    // User OOC is evidence/correction, not an assistant forecast. Give recent
    // user corrections space before narrative when the query cap is reached.
    recent.sort((a, b) {
      final correctionOrder = _isCorrection(b).compareTo(_isCorrection(a));
      if (correctionOrder != 0) return correctionOrder;
      return eligible.indexOf(b).compareTo(eligible.indexOf(a));
    });
    for (final message in recent) {
      final text = project(message.role, message.content);
      if (text.isEmpty) continue;
      final part = '${message.role}: ${_bounded(text, _recentChars)}';
      final remaining = maxChars - parts.join('\n\n').length - 2;
      if (remaining <= message.role.length + 2) break;
      parts.add(_bounded(part, remaining));
    }
    return parts.join('\n\n');
  }

  /// Lexical reranking text. Assistant wording is used only when the current
  /// user turn clearly disputes or corrects the immediately preceding reply.
  /// It supplies an antecedent for pronoun-only corrections; semantic search
  /// and exact indexed sources still decide whether any evidence is admitted.
  static String lexicalContinuity({
    required String currentText,
    List<ChatMessage> history = const [],
  }) {
    final current = project('user', currentText);
    if (current.isEmpty || !_looksLikeCorrection(current)) return current;

    final eligible = history.where(_eligible).toList();
    if (eligible.isNotEmpty &&
        eligible.last.role == 'user' &&
        eligible.last.content == currentText) {
      eligible.removeLast();
    }
    if (eligible.isEmpty || eligible.last.role != 'assistant') return current;
    final antecedent = project('assistant', eligible.last.content);
    if (antecedent.isEmpty) return current;
    return '$current\n\nassistant: ${_bounded(antecedent, _recentChars)}';
  }

  static bool _eligible(ChatMessage message) =>
      !message.isHidden &&
      !message.isTyping &&
      !message.isError &&
      (message.role == 'user' || message.role == 'assistant');

  static int _isCorrection(ChatMessage message) =>
      message.role == 'user' &&
          RegExp(
            r'\booc\b|\(\(',
            caseSensitive: false,
          ).hasMatch(message.content)
      ? 1
      : 0;

  static bool _looksLikeCorrection(String text) => RegExp(
    r'вообще-то|на самом деле|неверн|неправ|'
    r'(?:ты|вы)\s+забыл|я\s+же|разве\s+(?:мы|ты|вы)|'
    r'памят[ьи][^.!?\n]{0,24}(?:подвод|измен)|'
    r'\bactually\b|\bthat(?:\s+is|\x27s)\s+not\b|'
    r'\byou\s+(?:forgot|misremembered)\b',
    caseSensitive: false,
  ).hasMatch(text);

  /// Only the query is projected. Saved/indexed evidence is never rewritten.
  static String project(String role, String content) {
    final text = CanonEvidenceText.forMessage(role, content);
    final out = StringBuffer();
    final stack = <String>[];
    var offset = 0;
    for (final match in _scaffoldTag.allMatches(text)) {
      if (stack.isEmpty) out.write(text.substring(offset, match.start));
      final name = match.group(2)!.toLowerCase();
      if (match.group(1)!.isEmpty) {
        if (!match.group(0)!.endsWith('/>')) stack.add(name);
      } else if (stack.isNotEmpty && stack.last == name) {
        stack.removeLast();
      }
      if (stack.isEmpty) out.write('\n');
      offset = match.end;
    }
    if (stack.isEmpty) out.write(text.substring(offset));
    return out.toString().replaceAll(_wireToken, '').trim();
  }

  static String _bounded(String text, int limit) {
    if (text.length <= limit) return text;
    // Retain both ends (corrections often follow a long scene description).
    final head = (limit - 1) ~/ 2;
    return '${text.substring(0, head)}…${text.substring(text.length - (limit - head - 1))}';
  }
}
