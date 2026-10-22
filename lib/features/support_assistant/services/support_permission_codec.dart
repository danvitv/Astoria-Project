import 'dart:convert';
import '../../../core/models/support_models.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';

/// Bounded, exact versioned schema. No arbitrary-object serialization, unknown
/// fields, categories or malformed grants can become consent.
final class SupportPermissionCodec {
  const SupportPermissionCodec();
  static const marker = 'workspace-permissions-v1';
  static const maxChars = 65536;
  String idFor(String sessionId) => '$marker:$sessionId';

  SupportPermissionPreferences decode(
    String sessionId,
    SupportContextBlock? block,
  ) {
    if (block == null) {
      return SupportPermissionPreferences(
        supportSessionId: sessionId,
        policyIdentity: 'missing',
        revision: 0,
      );
    }
    if (block.isLocked) {
      throw SupportPermissionsUnavailable(SupportPermissionAvailability.locked);
    }
    try {
      if (block.id != idFor(sessionId) ||
          block.sessionId != sessionId ||
          block.summary != marker ||
          !block.isActive ||
          block.startMessageId.isNotEmpty ||
          block.endMessageId.isNotEmpty) {
        throw const FormatException();
      }
      _bound(block.protectedFactsJson);
      final m = _map(jsonDecode(block.protectedFactsJson), {
        'version',
        'session',
        'identity',
        'revision',
        'grants',
        'scope',
        'recipient',
      });
      if (m['version'] is! int ||
          m['version'] != SupportPermissionPreferences.version ||
          m['session'] != sessionId) {
        throw const FormatException();
      }
      final rights = _map(
        m['grants'],
        SupportPermission.values.map((r) => r.name).toSet(),
      );
      final grants = <SupportPermission>[];
      for (final right in SupportPermission.values) {
        if (rights[right.name] is! bool) throw const FormatException();
        if (rights[right.name] == true) grants.add(right);
      }
      return SupportPermissionPreferences(
        supportSessionId: sessionId,
        policyIdentity: m['identity'] as String,
        revision: m['revision'] as int,
        grants: grants,
        scope: _scope(m['scope']),
        recipient: _recipient(m['recipient']),
      );
    } catch (_) {
      throw SupportPermissionsUnavailable(
        SupportPermissionAvailability.corrupt,
      );
    }
  }

  SupportContextBlock encode(SupportPermissionPreferences p, int now) {
    final s = p.scope, r = p.recipient;
    final json = jsonEncode(<String, Object?>{
      'version': SupportPermissionPreferences.version,
      'session': p.supportSessionId,
      'identity': p.policyIdentity,
      'revision': p.revision,
      'grants': {
        for (final right in SupportPermission.values)
          right.name: p.grants.contains(right),
      },
      'scope': s == null
          ? null
          : {
              'revision': s.selectionRevision,
              'gameSession': s.gameSessionId,
              'gameHistory': s.gameHistory?.messageIds,
              'supportHistory': s.supportHistory?.messageIds,
              'safeCategories': s.safeCategories.map((c) => c.name).toList(),
              'data': {
                for (final e in s.selectedData.entries) e.key.name: e.value,
              },
            },
      'recipient': r == null
          ? null
          : {
              'connection': r.connectionId,
              'model': r.modelId,
              'protocol': r.protocol.name,
              'route': r.nativeRoute,
              'revision': r.configurationRevision,
            },
    });
    _bound(json);
    return SupportContextBlock(
      id: idFor(p.supportSessionId),
      sessionId: p.supportSessionId,
      startMessageId: '',
      endMessageId: '',
      summary: marker,
      protectedFactsJson: json,
      createdAt: now,
    );
  }

  SupportPermissionScope? _scope(Object? value) {
    if (value == null) return null;
    final m = _map(value, {
      'revision',
      'gameSession',
      'gameHistory',
      'supportHistory',
      'safeCategories',
      'data',
    });
    final data = m['data'];
    if (data is! Map<String, dynamic> ||
        data.length > SupportDataCategory.values.length) {
      throw const FormatException();
    }
    final safe = m['safeCategories'];
    if (safe is! List<Object?> ||
        safe.length > SupportSafeCategory.values.length ||
        safe.toSet().length != safe.length) {
      throw const FormatException();
    }
    return SupportPermissionScope(
      selectionRevision: m['revision'] as int,
      gameSessionId: m['gameSession'] as String?,
      gameHistory: _messages(m['gameHistory']),
      supportHistory: _messages(m['supportHistory']),
      safeCategories: safe.map(
        (v) => SupportSafeCategory.values.byName(v as String),
      ),
      selectedData: data.map(
        (key, ids) =>
            MapEntry(SupportDataCategory.values.byName(key), _ids(ids, 128)),
      ),
    );
  }

  SupportMessageSelection? _messages(Object? value) =>
      value == null ? null : SupportMessageSelection(_ids(value, 512));
  List<String> _ids(Object? value, int limit) {
    if (value is! List<Object?> || value.isEmpty || value.length > limit) {
      throw const FormatException();
    }
    return value.map((v) => v as String).toList();
  }

  SupportPermissionRecipient? _recipient(Object? value) {
    if (value == null) return null;
    final m = _map(value, {
      'connection',
      'model',
      'protocol',
      'route',
      'revision',
    });
    return SupportPermissionRecipient(
      connectionId: m['connection'] as String,
      modelId: m['model'] as String,
      protocol: SupportRecipientProtocol.values.byName(m['protocol'] as String),
      nativeRoute: m['route'] as String,
      configurationRevision: m['revision'] as int,
    );
  }

  Map<String, dynamic> _map(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const FormatException();
    }
    return value;
  }

  void _bound(String value) {
    if (value.length > maxChars) {
      throw StateError('Permission payload too large.');
    }
    // jsonDecode overwrites duplicate map keys. Reject them before decoding so
    // a corrupt second grant/version/scope cannot replace a denial silently.
    final containers = <Set<String>?>[];
    var quoted = false, escaped = false, start = 0;
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          quoted = false;
          var j = i + 1;
          while (j < value.length &&
              const [9, 10, 13, 32].contains(value.codeUnitAt(j))) {
            j++;
          }
          if (j < value.length && value.codeUnitAt(j) == 58) {
            final key = jsonDecode(value.substring(start, i + 1)) as String;
            if (containers.isEmpty ||
                containers.last == null ||
                !containers.last!.add(key)) {
              throw StateError('Invalid permission payload.');
            }
          }
        }
      } else if (unit == 34) {
        quoted = true;
        start = i;
      } else if (unit == 91 || unit == 123) {
        containers.add(unit == 123 ? <String>{} : null);
        if (containers.length > 12) {
          throw StateError('Invalid permission payload.');
        }
      } else if (unit == 93 || unit == 125) {
        if (containers.isEmpty || (containers.last == null) != (unit == 93)) {
          throw StateError('Invalid permission payload.');
        }
        containers.removeLast();
      }
    }
    if (quoted || containers.isNotEmpty) {
      throw StateError('Invalid permission payload.');
    }
  }
}
