import '../../../../core/credentials/secret_redactor.dart';
import '../../models/support_app_action.dart';

/// Exact projection: executable IDs/settings are never silently masked/changed.
final class SupportAppRedactedMetadataPolicy
    implements SupportAppMetadataPolicy, SupportAppBodyMetadataPolicy {
  const SupportAppRedactedMetadataPolicy({required this.currentRedactor});
  final SecretRedactor Function() currentRedactor;

  // Synchronous check tokens preserve the const public constructor. Reentry
  // invalidates the outer check too, rather than accepting its projected value.
  static final _checks = Expando<Object>();

  @override
  String? exactText(String value, {required int maxLength}) {
    if (value.length > maxLength ||
        RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]').hasMatch(value)) {
      return null;
    }
    return _exact(value, (policy) => policy.redactText(value));
  }

  @override
  String? exactBodyText(String value, {required int maxLength}) {
    if (maxLength < 1 ||
        maxLength > 32768 ||
        !SupportAppActionField.bodyText(maxLength).accepts(value)) {
      return null;
    }
    // A scalar redactJson call scans the WHOLE original string without parsing
    // JSON-looking prose, trimming, splitting lines or changing redactor limits.
    return _exact(value, (policy) => policy.redactJson(value));
  }

  String? _exact(String value, Object? Function(SecretRedactor) project) {
    if (_checks[this] != null) {
      _checks[this] = Object();
      return null;
    }
    final check = Object();
    _checks[this] = check;
    try {
      final policy = currentRedactor();
      if (!identical(_checks[this], check)) return null;
      final projected = project(policy);
      final after = currentRedactor();
      return identical(_checks[this], check) &&
              identical(policy, after) &&
              projected == value
          ? value
          : null;
    } catch (_) {
      return null;
    } finally {
      _checks[this] = null;
    }
  }
}
