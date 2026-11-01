import 'dart:convert';

import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/support_report/support_report_error.dart';
import '../../../../core/support_report/support_report_json.dart';

/// Native known-secret owner + structural stripping, including JSON-in-string.
/// This is not a universal personal-data detector; authored text is personal.
final class SupportReportSanitizer {
  SupportReportSanitizer(SecretRedactor owner)
    : _redactor = owner.withKnownSecrets(
        const [],
        maxInputLength: SupportReportJson.maxBytes,
        maxOutputLength: SupportReportJson.maxBytes,
        maxDepth: 16,
        maxNodes: 8192,
      );
  final SecretRedactor _redactor;

  static String _fieldKey(String name) =>
      name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Report content is not a vault/authority export, even in personal mode.
  /// Reject whole recognizable custody subtrees, not just known token values.
  static bool _privateField(String name) {
    final key = _fieldKey(name);
    return SecretRedactor.isSecretField(name) ||
        const {
          'auth',
          'vault',
          'authority',
          'owner',
          'receipt',
          'key',
          'cas',
          'id',
          'rowid',
          'sessionid',
          'configid',
          'sourceid',
          'privateid',
          'nativeidentity',
          'handle',
          'snapshotdigest',
          'snapshotstamp',
        }.contains(key) ||
        key.endsWith('hash') ||
        key.endsWith('digest') ||
        key.endsWith('stamp') ||
        key.endsWith('receipt') ||
        key.endsWith('ciphertext');
  }

  Object? sanitize(Object? value) {
    var nodes = 0;
    Object? clean(Object? current, int depth) {
      if (++nodes > 8192 || depth > 16) {
        throw const SupportReportException(SupportReportFailure.tooLarge);
      }
      if (current is String) {
        if (current.length > SupportReportJson.maxBytes) {
          throw const SupportReportException(SupportReportFailure.tooLarge);
        }
        final trimmed = current.trimLeft();
        if (trimmed.startsWith('{') ||
            trimmed.startsWith('[') ||
            trimmed.startsWith('"')) {
          // Parsing or shared recursion-budget failure is terminal. Falling
          // back to the general text redactor would bypass this report-specific
          // structural policy, especially in deeply nested JSON strings.
          final parsed = SupportReportJson.decode(current);
          return SupportReportJson.canonical(clean(parsed, depth + 1));
        }
        final text = _redactor.redactText(current);
        if (text.contains(SecretRedactor.limited) ||
            utf8.decode(utf8.encode(text)) != text) {
          throw const SupportReportException(SupportReportFailure.tooLarge);
        }
        return text;
      }
      if (current is Map<String, Object?>) {
        final aliases = <String, List<String>>{};
        for (final name in current.keys) {
          final key = _fieldKey(name);
          if (const {'key', 'name', 'value'}.contains(key)) {
            (aliases[key] ??= []).add(name);
          }
        }
        if (aliases.values.any((names) => names.length != 1))
          return <String, Object?>{};
        if (aliases.containsKey('value')) {
          final name = aliases['name']?.single;
          final discriminator = name == null ? null : current[name];
          if (aliases.containsKey('key') ||
              (name != null &&
                  (discriminator is! String || _privateField(discriminator))) ||
              current.keys.any(_privateField)) {
            return <String, Object?>{};
          }
        }
        return {
          for (final e in current.entries)
            if (!_privateField(e.key))
              clean(e.key, depth + 1) as String: clean(e.value, depth + 1),
        };
      }
      if (current is List) {
        return current.map((v) => clean(v, depth + 1)).toList();
      }
      if (current == null ||
          current is int ||
          current is bool ||
          (current is double && current.isFinite)) {
        return current;
      }
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }

    final result = clean(value, 0);
    SupportReportJson.canonical(result);
    return result;
  }
}
