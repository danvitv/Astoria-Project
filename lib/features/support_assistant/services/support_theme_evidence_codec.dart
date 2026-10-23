import 'dart:convert';

import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../models/support_theme_values.dart';

/// Fixed allowlisted keys are schema, not diagnostic input. Only VARIABLE
/// values are redacted. In particular, never redact a whole sessionId JSON key.
final class SupportThemeEvidenceCodec {
  const SupportThemeEvidenceCodec();
  static const domain = 'theme.selection';
  static const target = 'installed-active-selection';
  static const maxInstalled = 128;
  static final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
  static final _accent = RegExp(r'^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$');

  bool identifier(String id, SecretRedactor policy) =>
      id.length <= 128 &&
      _id.matchAsPrefix(id)?.end == id.length &&
      policy.redactText('') != SecretRedactor.limited &&
      policy.redactText(id) == id;

  SupportThemeValue? project({
    required String id,
    required String name,
    required String mode,
    required String accent,
    required bool active,
    required SecretRedactor policy,
  }) {
    if (!identifier(id, policy) ||
        name.isEmpty ||
        name.length > 128 ||
        utf8.encode(name).length > 512 ||
        RegExp(
          r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069\\/]|://',
        ).hasMatch(name) ||
        name.trimLeft().startsWith('{') ||
        !const ['dark', 'light', 'system'].contains(mode) ||
        _accent.matchAsPrefix(accent)?.end != accent.length) {
      return null;
    }
    final safeName = policy.redactText(name);
    if (safeName.isEmpty ||
        safeName.length > 128 ||
        utf8.encode(safeName).length > 512 ||
        safeName.contains(SecretRedactor.limited) ||
        policy.redactText(mode) != mode ||
        policy.redactText(accent) != accent) {
      return null;
    }
    return SupportThemeValue(
      id: id,
      name: safeName,
      mode: mode,
      accent: accent,
      active: active,
    );
  }

  String? encode({
    required String sessionId,
    required SupportThemeValue value,
    required SecretRedactor policy,
  }) {
    if (!value.active || !identifier(sessionId, policy)) return null;
    final safe = project(
      id: value.id,
      name: value.name,
      mode: value.mode,
      accent: value.accent,
      active: value.active,
      policy: policy,
    );
    if (safe == null) return null;
    final native = _native(sessionId, safe);
    if (utf8.encode(native).length > SupportMutationEvidence.maxNativeBytes) {
      return null;
    }
    return SupportMutationEvidence.encode(native);
  }

  SupportThemeValue? decode({
    required String encoded,
    required String sessionId,
    required SecretRedactor policy,
  }) {
    final native = SupportMutationEvidence.decode(encoded);
    if (native == null || !identifier(sessionId, policy)) return null;
    try {
      final m = jsonDecode(native);
      if (m is! Map<String, dynamic> ||
          m.length != 9 ||
          m['v'] is! int ||
          m['v'] != 1 ||
          m['domain'] != domain ||
          m['target'] != target ||
          m['sessionId'] != sessionId ||
          m['id'] is! String ||
          m['name'] is! String ||
          m['mode'] is! String ||
          m['accent'] is! String ||
          m['active'] != true) {
        return null;
      }
      final stored = SupportThemeValue(
        id: m['id'] as String,
        name: m['name'] as String,
        mode: m['mode'] as String,
        accent: m['accent'] as String,
        active: true,
      );
      // Canonical structure check rejects duplicate keys, aliases and extras.
      // This is NOT diagnostic-redaction/whole-JSON equality.
      if (_native(sessionId, stored) != native) return null;
      return project(
        id: stored.id,
        name: stored.name,
        mode: stored.mode,
        accent: stored.accent,
        active: true,
        policy: policy,
      );
    } on FormatException {
      return null;
    }
  }

  String _native(String sessionId, SupportThemeValue value) => jsonEncode({
    'v': 1,
    'domain': domain,
    'target': target,
    'sessionId': sessionId,
    'id': value.id,
    'name': value.name,
    'mode': value.mode,
    'accent': value.accent,
    'active': value.active,
  });
}
