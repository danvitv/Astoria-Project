import 'dart:convert';

import 'package:glaze_flutter/core/credentials/secret_redactor.dart';

/// Frozen pre-fix matcher for small deterministic compatibility fixtures.
/// Adversarial long comparisons are allowed ONLY in the watchdog-owned test
/// isolate: unanchored regexes/literal alternation are the defect under test.
String legacyRedactPlain(String text, List<String> secrets) {
  const removed = SecretRedactor.removed;
  final values = <String>{};
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    values.add(secret);
    values.add(Uri.encodeComponent(secret));
    values.add(Uri.encodeFull(secret));
    final escaped = jsonEncode(secret);
    values.add(escaped.substring(1, escaped.length - 1));
    if (secret.runes.length >= 8) {
      values.add(base64Encode(utf8.encode(secret)));
      values.add(base64UrlEncode(utf8.encode(secret)));
    }
  }
  final known = values.toList()..sort((a, b) => b.length.compareTo(a.length));
  final pattern = known.map(RegExp.escape).join('|');
  final knownRegex = known.isEmpty ? null : RegExp(pattern);
  final plain = RegExp(
    [
      '(?<url>${_url.pattern})',
      '(?<authorization>${_authorization.pattern})',
      '(?<namedValue>${_namedValue.pattern})',
      '(?<authValue>${_authValue.pattern})',
      '(?<token>${_token.pattern})',
      if (known.isNotEmpty) '(?<known>$pattern)',
    ].join('|'),
  );
  final value = RegExp(
    [
      '(?<url>${_url.pattern})',
      _authValue.pattern,
      _token.pattern,
      if (known.isNotEmpty) pattern,
    ].join('|'),
  );
  final urlRedactor = SecretRedactor(knownSecrets: secrets);
  String replaceKnown(String input) =>
      knownRegex == null ? input : input.replaceAll(knownRegex, removed);
  String replaceValue(String input) => input.replaceAllMapped(value, (raw) {
    final match = raw as RegExpMatch;
    return match.namedGroup('url') != null
        ? urlRedactor.redactUrl(match[0]!)
        : removed;
  });
  return text.replaceAllMapped(plain, (raw) {
    final match = raw as RegExpMatch;
    if (match.namedGroup('url') != null) {
      return urlRedactor.redactUrl(match[0]!);
    }
    if (match.namedGroup('authorization') != null) {
      return 'Authorization: $removed';
    }
    if (match.namedGroup('namedValue') != null) {
      final field = _namedValue.firstMatch(match[0]!)!;
      return SecretRedactor.isSecretField(field[2]!)
          ? '${replaceKnown(field[1]!)}"$removed"'
          : replaceValue(match[0]!);
    }
    return removed;
  });
}

String _word(String word) =>
    word.split('').map((letter) => '[$letter${letter.toUpperCase()}]').join();
final _authorization = RegExp(
  '\\b(?:${_word('proxy')}[-_ ]?)?${_word('authorization')}["\']?\\s*[:=]\\s*[^\\r\\n]+',
);
final _authValue = RegExp(
  '\\b(?:${_word('bearer')}|${_word('basic')})\\s+[a-zA-Z0-9._~+/-]+=*',
);
final _namedValue = RegExp(
  r'''(["']?([a-zA-Z][a-zA-Z0-9_.-]*)["']?\s*[:=]\s*)("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\s,;}]+)''',
);
final _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>]+');
final _token = RegExp(
  r'\b(?:sk-[a-zA-Z0-9_-]{8,}|gh[pousr]_[a-zA-Z0-9_]{8,}|github_pat_[a-zA-Z0-9_]{22,}|AIza[a-zA-Z0-9_-]{30,}|hf_[a-zA-Z0-9]{20,}|eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)\b',
);
