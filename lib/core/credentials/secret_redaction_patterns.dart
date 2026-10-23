import 'dart:convert';
import 'dart:typed_data';

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
    _known = known.map(_KnownLiteral.new).toList(growable: false);
  }

  static const removed = '[REDACTED]';
  bool closed = false;
  late final List<_KnownLiteral> _known;
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

  String replaceKnown(String value) => _replace(value, null, fields: false);

  String replaceValue(String value, String Function(String) redactUrl) =>
      _replace(value, redactUrl, fields: false);

  String replaceText(String text, String Function(String) redactUrl) =>
      _replace(text, redactUrl, fields: true);

  String _replace(
    String text,
    String Function(String)? redactUrl, {
    required bool fields,
  }) {
    if (text.isEmpty) return text;
    final knownLengths = _known.isEmpty ? null : Uint32List(text.length);
    if (knownLengths != null) {
      for (final literal in _known) {
        literal.recordMatches(text, knownLengths);
      }
    }
    final output = StringBuffer();
    var copied = 0;
    var position = 0;
    var namedAfter = 0;
    var urlAfter = 0;
    while (position < text.length) {
      Match? match;
      String? replacement;
      if (redactUrl != null) {
        // A failed greedy identifier has the same separator/value failure at
        // every alphabetic suffix. Skip ONLY those futile retries, not text or
        // other patterns. Retain historical starts after digits/dots/quotes.
        if (position >= urlAfter && _urlStart(text, position)) {
          match = _url.matchAsPrefix(text, position);
          if (match == null) {
            urlAfter = _identifierEnd(text, position, scheme: true);
          } else {
            replacement = redactUrl(match[0]!);
          }
        }
        if (match == null && fields) {
          match = _authorization.matchAsPrefix(text, position);
          if (match != null) replacement = 'Authorization: $removed';
          if (match == null && position >= namedAfter) {
            final first = _quote(text.codeUnitAt(position))
                ? position + 1
                : position;
            if (first < text.length && _letter(text.codeUnitAt(first))) {
              match = _namedValue.matchAsPrefix(text, position);
              if (match == null) {
                namedAfter = _identifierEnd(text, first, scheme: false);
              } else {
                replacement = isSecretField(match[2]!)
                    ? '${replaceKnown(match[1]!)}"$removed"'
                    : replaceValue(match[0]!, redactUrl);
              }
            }
          }
        }
        if (match == null) {
          match =
              _authValue.matchAsPrefix(text, position) ??
              _token.matchAsPrefix(text, position);
          if (match != null) replacement = removed;
        }
      }
      final length = match != null
          ? match.end - position
          : knownLengths?[position] ?? 0;
      if (length == 0) {
        position++;
        continue;
      }
      output.write(text.substring(copied, position));
      output.write(replacement ?? removed);
      position += length;
      copied = position;
    }
    if (copied == 0) return text;
    output.write(text.substring(copied));
    return output.toString();
  }

  static bool _letter(int unit) =>
      (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);
  static bool _digit(int unit) => unit >= 48 && unit <= 57;
  static bool _quote(int unit) => unit == 34 || unit == 39;
  static bool _urlStart(String text, int position) =>
      _letter(text.codeUnitAt(position)) &&
      (position == 0 ||
          !(_letter(text.codeUnitAt(position - 1)) ||
              _digit(text.codeUnitAt(position - 1)) ||
              text.codeUnitAt(position - 1) == 95));

  static int _identifierEnd(String text, int start, {required bool scheme}) {
    var end = start;
    while (end < text.length) {
      final unit = text.codeUnitAt(end);
      if (!_letter(unit) &&
          !_digit(unit) &&
          unit != 46 &&
          unit != 45 &&
          unit != (scheme ? 43 : 95)) {
        break;
      }
      end++;
    }
    return end;
  }

  @override
  String toString() => 'SecretRedactionPatterns';
}

/// KMP failure links bound each literal to one linear original-input scan,
/// including repeated near-matches. No regex alternation/suffix comparison.
final class _KnownLiteral {
  _KnownLiteral(this.value) : _failure = Uint32List(value.length) {
    var prefix = 0;
    for (var index = 1; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      while (prefix > 0 && unit != value.codeUnitAt(prefix)) {
        prefix = _failure[prefix - 1];
      }
      if (unit == value.codeUnitAt(prefix)) prefix++;
      _failure[index] = prefix;
    }
  }

  final String value;
  final Uint32List _failure;

  void recordMatches(String text, Uint32List lengths) {
    if (value.length > text.length) return;
    var prefix = 0;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      while (prefix > 0 && unit != value.codeUnitAt(prefix)) {
        prefix = _failure[prefix - 1];
      }
      if (unit == value.codeUnitAt(prefix)) prefix++;
      if (prefix == value.length) {
        final start = index + 1 - prefix;
        if (prefix > lengths[start]) lengths[start] = prefix;
        prefix = _failure[prefix - 1];
      }
    }
  }
}
