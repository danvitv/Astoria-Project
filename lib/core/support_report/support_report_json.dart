import 'dart:collection';
import 'dart:convert';

import 'support_report_error.dart';

/// Bounded JSON grammar scanner before decoding: duplicate keys (including
/// escaped equivalents), excess nesting, node count and invalid UTF-8 refuse.
final class SupportReportJson {
  static const maxBytes = 256 * 1024;
  static const maxDepth = 16;
  static const maxNodes = 8192;

  static Object? decode(String text, {int limit = maxBytes}) {
    if (text.length > limit || utf8.encode(text).length > limit) {
      throw const SupportReportException(SupportReportFailure.tooLarge);
    }
    if (utf8.decode(utf8.encode(text)) != text) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    try {
      final scanner = _Scanner(text);
      scanner.value(0);
      scanner.white();
      if (scanner.at != text.length) scanner.invalid();
      return jsonDecode(text);
    } on SupportReportException {
      rethrow;
    } catch (_) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
  }

  static String canonical(Object? value) {
    final visiting = HashSet<Object>.identity();
    var nodes = 0, characters = 0;
    void bound(String text) {
      characters += text.length;
      if (characters > maxBytes) {
        throw const SupportReportException(SupportReportFailure.tooLarge);
      }
      if (utf8.decode(utf8.encode(text)) != text) {
        throw const SupportReportException(SupportReportFailure.invalidPacket);
      }
    }

    Object? ordered(Object? current, int depth) {
      if (++nodes > maxNodes || depth > maxDepth) {
        throw const SupportReportException(SupportReportFailure.tooLarge);
      }
      if (current is Map<String, Object?>) {
        if (!visiting.add(current) || current.length > maxNodes) {
          throw const SupportReportException(
            SupportReportFailure.invalidPacket,
          );
        }
        final keys = current.keys.toList()..sort();
        try {
          final result = <String, Object?>{};
          for (final key in keys) {
            bound(key);
            result[key] = ordered(current[key], depth + 1);
          }
          return result;
        } finally {
          visiting.remove(current);
        }
      }
      if (current is List) {
        if (!visiting.add(current) || current.length > maxNodes) {
          throw const SupportReportException(
            SupportReportFailure.invalidPacket,
          );
        }
        try {
          return current.map((v) => ordered(v, depth + 1)).toList();
        } finally {
          visiting.remove(current);
        }
      }
      if (current is String) bound(current);
      if (current == null ||
          current is String ||
          current is bool ||
          current is int ||
          (current is double && current.isFinite)) {
        return current;
      }
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }

    final text = jsonEncode(ordered(value, 0));
    decode(text);
    return text;
  }
}

final class _Scanner {
  _Scanner(this.text);
  final String text;
  int at = 0, nodes = 0;
  Never invalid() =>
      throw const SupportReportException(SupportReportFailure.invalidPacket);
  void white() {
    while (at < text.length &&
        const [9, 10, 13, 32].contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  bool take(String char) {
    white();
    if (at < text.length && text[at] == char) {
      at++;
      return true;
    }
    return false;
  }

  void need(String char) {
    if (!take(char)) invalid();
  }

  String string() {
    white();
    final start = at;
    if (at == text.length || text[at++] != '"') invalid();
    while (at < text.length) {
      final c = text.codeUnitAt(at++);
      if (c == 34) {
        final decoded = jsonDecode(text.substring(start, at)) as String;
        if (utf8.decode(utf8.encode(decoded)) != decoded) invalid();
        return decoded;
      }
      if (c < 32) invalid();
      if (c == 92) {
        if (at == text.length) invalid();
        final escape = text[at++];
        if (escape == 'u') {
          if (at + 4 > text.length ||
              !RegExp(
                r'^[0-9a-fA-F]{4}$',
              ).hasMatch(text.substring(at, at + 4))) {
            invalid();
          }
          at += 4;
        } else if (!const [
          '"',
          r'\',
          '/',
          'b',
          'f',
          'n',
          'r',
          't',
        ].contains(escape)) {
          invalid();
        }
      }
    }
    invalid();
  }

  void value(int depth) {
    if (++nodes > SupportReportJson.maxNodes ||
        depth > SupportReportJson.maxDepth) {
      throw const SupportReportException(SupportReportFailure.tooLarge);
    }
    white();
    if (at == text.length) invalid();
    if (take('{')) {
      final keys = <String>{};
      if (take('}')) return;
      do {
        if (!keys.add(string())) invalid();
        need(':');
        value(depth + 1);
      } while (take(','));
      need('}');
    } else if (take('[')) {
      if (take(']')) return;
      do {
        value(depth + 1);
      } while (take(','));
      need(']');
    } else if (text[at] == '"') {
      string();
    } else {
      final match = RegExp(
        r'(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)',
      ).matchAsPrefix(text, at);
      if (match == null) invalid();
      at = match.end;
    }
  }
}
