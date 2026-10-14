import 'dart:convert';

/// Sanitizes structured connection URLs only; never searches arbitrary text.
abstract final class BackupSecretUrls {
  static bool isEndpointField(String name) => const {
    'endpoint',
    'embeddingendpoint',
    'generationendpoint',
    'customendpoint',
    'apiendpoint',
    'url',
    'baseurl',
    'apiurl',
  }.contains(name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''));

  static Uri? _parse(String raw) {
    try {
      final uri = Uri.parse(
        raw.contains('://') || raw.startsWith('//') ? raw : '//$raw',
      );
      if (uri.host.isEmpty ||
          (uri.scheme.isNotEmpty &&
              uri.scheme != 'http' &&
              uri.scheme != 'https')) {
        return null;
      }
      return uri;
    } on FormatException {
      return null;
    }
  }

  static bool _secret(String key, bool Function(String) credential) =>
      key.toLowerCase() == 'key' || credential(key);

  static String? _decode(String raw) {
    try {
      return Uri.decodeQueryComponent(raw);
    } on FormatException {
      return null;
    }
  }

  static String? _key(String part) => _decode(part.split('=').first);
  static String? _value(String part) =>
      part.contains('=') ? _decode(part.substring(part.indexOf('=') + 1)) : '';

  static String _render(Uri original, Uri changed, String raw) {
    final result = changed.toString();
    return original.scheme.isEmpty && !raw.startsWith('//')
        ? result.substring(2)
        : result;
  }

  static String strip(String raw, bool Function(String) credential) {
    final uri = _parse(raw);
    if (uri == null) return raw;
    final parts = uri.query.isEmpty ? <String>[] : uri.query.split('&');
    final query = parts
        .map(
          (part) => _key(part) == null || _secret(_key(part)!, credential)
              ? '${part.split('=').first}='
              : part,
        )
        .join('&');
    if (uri.userInfo.isEmpty && query == uri.query) return raw;
    return _render(uri, uri.replace(userInfo: '', query: query), raw);
  }

  static bool sameDestination(
    String backup,
    String local,
    bool Function(String) credential,
  ) {
    final b = _parse(backup);
    final l = _parse(local);
    if (b == null || l == null) return false;
    try {
      if ([b, l].any(
        (uri) => uri.query
            .split('&')
            .any((p) => _key(p) == null || _value(p) == null),
      )) {
        return false;
      }
      List<String> ordinary(Uri uri) =>
          uri.query
              .split('&')
              .where((p) => p.isNotEmpty && !_secret(_key(p)!, credential))
              .map((p) => jsonEncode([_key(p), _value(p)]))
              .toList()
            ..sort();
      return b.scheme == l.scheme &&
          b.host == l.host &&
          b.port == l.port &&
          b.path == l.path &&
          b.fragment == l.fragment &&
          ordinary(b).join('&') == ordinary(l).join('&');
    } on FormatException {
      return false;
    }
  }

  static String refill(
    String backup,
    String local,
    bool Function(String) credential,
  ) {
    if (!sameDestination(backup, local, credential)) return backup;
    final b = _parse(backup)!;
    final l = _parse(local)!;
    try {
      final localParts = l.query.isEmpty ? <String>[] : l.query.split('&');
      final parts = b.query.isEmpty ? <String>[] : b.query.split('&');
      final query = parts
          .map((part) {
            final key = _key(part);
            if (key == null ||
                !_secret(key, credential) ||
                _value(part) != '') {
              return part;
            }
            final matches = localParts.where((p) => _key(p) == key).toList();
            // Repeated authentication parameters are ambiguous, never refill by index.
            if (matches.length != 1 ||
                parts.where((p) => _key(p) == key).length != 1) {
              return part;
            }
            return '${part.split('=').first}=${Uri.encodeQueryComponent(_value(matches.single)!)}';
          })
          .join('&');
      final userInfo = b.userInfo.isEmpty ? l.userInfo : b.userInfo;
      if (query == b.query && userInfo == b.userInfo) return backup;
      return _render(b, b.replace(userInfo: userInfo, query: query), backup);
    } on FormatException {
      return backup;
    }
  }
}
