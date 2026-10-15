import 'dart:collection';
import 'dart:convert';

import 'secret_redaction_patterns.dart';

/// Defense in depth for already allowlisted diagnostic data, NOT a universal
/// PII detector. Unknown/obfuscated secrets and arbitrary personal prose may
/// survive. Supply known values only from trusted code; never expose this owner
/// to assistant tools, or collect secrets by logging them first.
final class SecretRedactor {
  SecretRedactor({
    Iterable<String> knownSecrets = const [],
    int maxInputLength = 65536,
    int maxOutputLength = 8192,
    int maxDepth = 12,
    int maxNodes = 512,
  }) : this._(
         knownSecrets: knownSecrets,
         maxInputLength: maxInputLength,
         maxOutputLength: maxOutputLength,
         maxDepth: maxDepth,
         maxNodes: maxNodes,
       );

  SecretRedactor._({
    required Iterable<String> knownSecrets,
    required this.maxInputLength,
    required this.maxOutputLength,
    required this.maxDepth,
    required this.maxNodes,
    bool closed = false,
  }) {
    if (maxInputLength < 1 ||
        maxOutputLength < 32 ||
        maxDepth < 1 ||
        maxNodes < 1) {
      throw const FormatException('Invalid redaction limits');
    }
    // Enumerate untrusted/lazy inputs once and at most 257 times. Keep the
    // original bounded inputs privately so extension never loses base coverage.
    final retained = <String>[];
    if (!closed) {
      try {
        for (final secret in knownSecrets) {
          if (retained.length == 256 || secret.length > maxInputLength) {
            closed = true;
            break;
          }
          retained.add(secret);
        }
      } catch (_) {
        closed = true;
      }
    }
    _policyClosed = closed;
    _knownSecrets = List<String>.unmodifiable(retained);
    _patterns = SecretRedactionPatterns(_knownSecrets, maxInputLength);
  }

  static const removed = '[REDACTED]';
  static const limited = '[REDACTION_LIMIT]';
  final int maxInputLength;
  final int maxOutputLength;
  final int maxDepth;
  final int maxNodes;
  late final List<String> _knownSecrets;
  late final bool _policyClosed;
  late final SecretRedactionPatterns _patterns;
  bool get _closed => _policyClosed || _patterns.closed;
  static bool isSecretField(String key) =>
      SecretRedactionPatterns.isSecretField(key);

  /// Immutable trusted extension. Limits are retained unless explicitly
  /// overridden; an exhausted/invalid policy can never be reopened by raising
  /// limits. No raw-secret getter or second enumeration of the original input.
  SecretRedactor withKnownSecrets(
    Iterable<String> additional, {
    int? maxInputLength,
    int? maxOutputLength,
    int? maxDepth,
    int? maxNodes,
  }) => SecretRedactor._(
    knownSecrets: _extendKnownSecrets(additional),
    maxInputLength: maxInputLength ?? this.maxInputLength,
    maxOutputLength: maxOutputLength ?? this.maxOutputLength,
    maxDepth: maxDepth ?? this.maxDepth,
    maxNodes: maxNodes ?? this.maxNodes,
    closed: _closed,
  );

  Iterable<String> _extendKnownSecrets(Iterable<String> additional) sync* {
    yield* _knownSecrets;
    yield* additional;
  }

  String redactText(String text) {
    if (_closed || text.length > maxInputLength) return limited;
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _bound(jsonEncode(redactJson(jsonDecode(text))));
      } catch (_) {
        // Malformed JSON still goes through textual/URL/known-value redaction.
      }
    }
    return _redactPlain(text);
  }

  String _redactPlain(String text) {
    if (_closed || text.length > maxInputLength) return limited;
    // One scan of original text. No pass ever scans an inserted marker.
    return _bound(_patterns.replaceText(text, redactUrl));
  }

  /// Rebuilds valid HTTP(S) URLs without userinfo, query, or fragment. Invalid,
  /// relative, ambiguous, or unsupported URLs fail closed. Known secrets in
  /// paths (including common percent-encoded forms) are also removed.
  String redactUrl(String value) {
    if (_closed || value.length > maxInputLength) return limited;
    try {
      if (RegExp(r'[\s\\]').hasMatch(value) ||
          RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(value)) {
        return removed;
      }
      final uri = Uri.parse(value);
      if (!const ['http', 'https'].contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.port < 1 ||
          uri.port > 65535) {
        return removed;
      }
      final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      final origin =
          '${uri.scheme}://$host${uri.hasPort ? ':${uri.port}' : ''}';
      if (_patterns.replaceKnown(origin) != origin) return removed;
      // Decoding path segments prevents percent-case/encoding from bypassing
      // known-value matching; re-encoding keeps the result a safe URL string.
      final path = uri.pathSegments
          .map((part) {
            final safe = _patterns.replaceValue(part, (_) => removed);
            return Uri.encodeComponent(safe);
          })
          .join('/');
      return _bound('$origin${uri.path.startsWith('/') ? '/' : ''}$path');
    } catch (_) {
      return removed;
    }
  }

  /// Does not invoke arbitrary object.toJson/toString. Only JSON primitives and
  /// containers are accepted; unknown objects become a fixed redaction marker.
  /// Cycles, oversized trees/strings and excessive depth/output fail closed.
  Object? redactJson(Object? value) {
    if (_closed) return limited;
    final visited = HashSet<Object>.identity();
    var nodes = 0;
    Object? visit(Object? current, int depth) {
      if (++nodes > maxNodes || depth > maxDepth) return limited;
      if (current == null || current is bool || current is int) return current;
      if (current is double) return current.isFinite ? current : removed;
      // Do not recursively parse JSON-in-JSON strings with a fresh budget.
      if (current is String) return _redactPlain(current);
      if (current is! Map && current is! List) return removed;
      if (!visited.add(current)) return limited;
      try {
        if (current is Map) {
          if (current.length > maxNodes) return limited;
          final safe = <String, Object?>{};
          for (final key in current.keys) {
            if (key is! String) return removed;
            final safeKey = _redactPlain(key);
            final field = current[key];
            if (isSecretField(key)) {
              safe[safeKey] = removed;
            } else if (SecretRedactionPatterns.isUrlField(key)) {
              safe[safeKey] = field is String ? redactUrl(field) : removed;
            } else {
              safe[safeKey] = visit(field, depth + 1);
            }
            if (nodes > maxNodes) return limited;
          }
          return safe;
        }
        final list = current as List;
        if (list.length > maxNodes) return limited;
        final safe = <Object?>[];
        for (final item in list) {
          safe.add(visit(item, depth + 1));
          if (nodes > maxNodes) return limited;
        }
        return safe;
      } finally {
        visited.remove(current);
      }
    }

    try {
      final result = visit(value, 0);
      final encoded = jsonEncode(result);
      return encoded.length > maxOutputLength ? limited : result;
    } catch (_) {
      return removed;
    }
  }

  /// Errors are untrusted objects. Explicitly supplied, native-extracted error
  /// text can use redactText; arbitrary error.toString is never invoked here.
  String redactError(Object? error) => error is String
      ? redactText(error)
      : _bound('Diagnostic error ($removed)');

  String _bound(String value) {
    return value.length > maxOutputLength ? limited : value;
  }

  @override
  String toString() => 'SecretRedactor';
}
