part of 'native_provider_credentials.dart';

bool _validNativeSecret(String secret) =>
    secret.isNotEmpty &&
    secret.length <= 4096 &&
    !RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(secret) &&
    utf8.decode(utf8.encode(secret)) == secret;

/// Entire protected value, including its revision and binding, is private.
/// No envelope DTO, debug rendering, hashing or generic metadata projection.
final class _NativeProviderCredentialRecord {
  const _NativeProviderCredentialRecord({
    required this.secret,
    required this.connection,
    required this.routes,
    required this.purposes,
    required this.revision,
    required this.active,
  });
  final String secret;
  final NativeProviderConnectionIdentity connection;
  final List<CredentialRoute> routes;
  final Set<NativeProviderPurpose> purposes;
  final String revision;
  final bool active;

  _NativeProviderCredentialRecord disabled() => _NativeProviderCredentialRecord(
    secret: secret,
    connection: connection,
    routes: routes,
    purposes: purposes,
    revision: _nativeRevision(),
    active: false,
  );

  String encode() {
    final names = purposes.map((purpose) => purpose.name).toList()..sort();
    return jsonEncode({
      'v': 1,
      'secret': secret,
      'connection': connection._fields,
      'routes': routes
          .map(
            (route) => [
              route.endpoint.toString(),
              route.protocol.name,
              route.purpose.name,
            ],
          )
          .toList(),
      'purposes': names,
      'revision': revision,
      'active': active,
    });
  }

  static _NativeProviderCredentialRecord decode(
    String encoded,
    SecretRedactionCoordinator redaction,
    NativeProviderRoutePolicy policy,
  ) {
    try {
      _boundedJson(encoded);
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value.length != 7 ||
          value['v'] != 1 ||
          value['v'] is! int ||
          value['secret'] is! String ||
          !_validNativeSecret(value['secret'] as String) ||
          value['revision'] is! String ||
          !RegExp(r'^[0-9a-f]{48}$').hasMatch(value['revision'] as String) ||
          value['active'] is! bool) {
        throw const FormatException();
      }
      final fields = value['connection'];
      if (fields is! List ||
          fields.length != 7 ||
          fields.take(5).any((value) => value is! String) ||
          fields[5] is! bool ||
          fields[6] is! bool) {
        throw const FormatException();
      }
      // Register the ACTUAL secret, never its enclosing JSON or fingerprint.
      redaction.registerSecret(value['secret'] as String);
      final identity = NativeProviderConnectionIdentity._fromSaved(
        ApiConfig(
          id: fields[0] as String,
          providerId: fields[1] as String,
          protocol: fields[2] as String,
          endpoint: fields[3] as String,
          model: fields[4] as String,
          stream: fields[5] as bool,
          useResponsesApi: fields[6] as bool,
        ),
        redaction,
      );
      if (identity == null) throw const FormatException();
      final names = value['purposes'];
      if (names is! List ||
          names.isEmpty ||
          names.length > 4 ||
          names.any((name) => name is! String)) {
        throw const FormatException();
      }
      final purposes = names
          .map(
            (name) => NativeProviderPurpose.values.firstWhere(
              (purpose) => purpose.name == name,
            ),
          )
          .toSet();
      if (purposes.length != names.length) throw const FormatException();
      final routesValue = value['routes'];
      if (routesValue is! List ||
          routesValue.isEmpty ||
          routesValue.length > 8) {
        throw const FormatException();
      }
      final routes = routesValue.map((entry) {
        if (entry is! List ||
            entry.length != 3 ||
            entry.any((item) => item is! String)) {
          throw const FormatException();
        }
        return CredentialRoute(
          endpoint: entry[0] as String,
          protocol: CredentialProtocol.values.firstWhere(
            (p) => p.name == entry[1],
          ),
          purpose: CredentialPurpose.values.firstWhere(
            (p) => p.name == entry[2],
          ),
        );
      }).toList();
      if (!_sameRoutes(routes, policy._routeSet(identity, purposes))) {
        throw const FormatException();
      }
      final record = _NativeProviderCredentialRecord(
        secret: value['secret'] as String,
        connection: identity,
        routes: List.unmodifiable(routes),
        purposes: Set.unmodifiable(purposes),
        revision: value['revision'] as String,
        active: value['active'] as bool,
      );
      // Detect duplicate keys, unknown members, alternate escapes/order/numbers,
      // whitespace and any noncanonical nested values without a second parser.
      if (record.encode() != encoded) throw const FormatException();
      return record;
    } catch (_) {
      throw const NativeProviderException(NativeProviderFailure.corrupt);
    }
  }

  static void _boundedJson(String text) {
    if (text.isEmpty ||
        text.length > 32768 ||
        utf8.encode(text).length > 49152) {
      throw const FormatException();
    }
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final rune in text.runes) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (rune == 92) {
          escaped = true;
        } else if (rune == 34) {
          quoted = false;
        }
      } else if (rune == 34) {
        quoted = true;
      } else if (rune == 91 || rune == 123) {
        if (++depth > 4) throw const FormatException();
      } else if (rune == 93 || rune == 125) {
        if (--depth < 0) throw const FormatException();
      }
    }
    if (depth != 0 || quoted) throw const FormatException();
  }

  @override
  String toString() => 'NativeProviderProtectedRecord';
}
