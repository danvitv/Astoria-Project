import 'dart:convert';

/// Internal trusted matcher shared by text and URL projection. Values are
/// compiled longest-first and each replacement scans original input only.
final class SecretRedactionPatterns {
  SecretRedactionPatterns(Iterable<String> secrets, int maxInputLength) {
    final values = <String>{};
    var count = 0;
    try {
      for (final secret in secrets) {
        if (++count > 256 || secret.length > maxInputLength) {
          closed = true;
          break;
        }
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
    } catch (_) {
      closed = true;
    }
    final known = values.toList()..sort((a, b) => b.length.compareTo(a.length));
    final pattern = known.map(RegExp.escape).join('|');
    _known = known.isEmpty ? null : RegExp(pattern);
    _plain = RegExp(
      [
        '(?<url>${_url.pattern})',
        '(?<authorization>${_authorization.pattern})',
        '(?<namedValue>${_namedValue.pattern})',
        '(?<authValue>${_authValue.pattern})',
        '(?<token>${_token.pattern})',
        if (known.isNotEmpty) '(?<known>$pattern)',
      ].join('|'),
    );
    _value = RegExp(
      [
        '(?<url>${_url.pattern})',
        _authValue.pattern,
        _token.pattern,
        if (known.isNotEmpty) pattern,
      ].join('|'),
    );
  }

  static const removed = '[REDACTED]';
  bool closed = false;
  late final RegExp? _known;
  late final RegExp _plain;
  late final RegExp _value;
  // Only header names/schemes ignore case; known secret values remain literal.
  static String _word(String word) =>
      word.split('').map((letter) => '[$letter${letter.toUpperCase()}]').join();
  static final _authorization = RegExp(
    '\\b(?:${_word('proxy')}[-_ ]?)?${_word('authorization')}["\']?\\s*[:=]\\s*[^\\r\\n]+',
  );
  static final _authValue = RegExp(
    '\\b(?:${_word('bearer')}|${_word('basic')})\\s+[a-zA-Z0-9._~+/-]+=*',
  );
  static final _namedValue = RegExp(
    r'''(["']?([a-zA-Z][a-zA-Z0-9_.-]*)["']?\s*[:=]\s*)("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\s,;}]+)''',
  );
  // Include quotes so malformed/quoted queries cannot leave their values behind.
  static final _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>]+');
  static final _token = RegExp(
    r'\b(?:sk-[a-zA-Z0-9_-]{8,}|gh[pousr]_[a-zA-Z0-9_]{8,}|github_pat_[a-zA-Z0-9_]{22,}|AIza[a-zA-Z0-9_-]{30,}|hf_[a-zA-Z0-9]{20,}|eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)\b',
  );

  static String _fieldName(String key) =>
      key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static bool isSecretField(String key) {
    final name = _fieldName(key);
    return const [
      'apikey',
      'token',
      'authorization',
      'password',
      'passwd',
      'secret',
      'credential',
      'cookie',
      'sessionid',
      'privatekey',
      'accesskey',
      'signingkey',
    ].any(name.contains);
  }

  static bool isUrlField(String key) {
    final name = _fieldName(key);
    return const [
      'url',
      'urls',
      'uri',
      'uris',
      'endpoint',
      'endpoints',
      'href',
      'origin',
      'host',
      'urlprefix',
      'endpointconfig',
    ].any(name.endsWith);
  }

  String replaceKnown(String value) =>
      _known == null ? value : value.replaceAll(_known, removed);

  String replaceValue(String value, String Function(String) redactUrl) =>
      value.replaceAllMapped(_value, (rawMatch) {
        final match = rawMatch as RegExpMatch;
        return match.namedGroup('url') != null ? redactUrl(match[0]!) : removed;
      });

  String replaceText(String text, String Function(String) redactUrl) =>
      text.replaceAllMapped(_plain, (rawMatch) {
        final match = rawMatch as RegExpMatch;
        if (match.namedGroup('url') != null) return redactUrl(match[0]!);
        if (match.namedGroup('authorization') != null) {
          return 'Authorization: $removed';
        }
        if (match.namedGroup('namedValue') != null) {
          final field = _namedValue.firstMatch(match[0]!)!;
          if (isSecretField(field[2]!)) {
            return '${replaceKnown(field[1]!)}"$removed"';
          }
          return replaceValue(match[0]!, redactUrl);
        }
        return removed;
      });

  @override
  String toString() => 'SecretRedactionPatterns';
}
