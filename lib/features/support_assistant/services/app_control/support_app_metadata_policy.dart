import '../../../../core/credentials/secret_redactor.dart';
import '../../models/support_app_action.dart';

/// Exact projection: executable IDs/settings are never silently masked/changed.
final class SupportAppRedactedMetadataPolicy
    implements SupportAppMetadataPolicy {
  const SupportAppRedactedMetadataPolicy({required this.currentRedactor});
  final SecretRedactor Function() currentRedactor;

  @override
  String? exactText(String value, {required int maxLength}) {
    if (value.length > maxLength ||
        RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]').hasMatch(value)) {
      return null;
    }
    final policy = currentRedactor();
    final projected = policy.redactText(value);
    return identical(policy, currentRedactor()) && projected == value
        ? value
        : null;
  }
}
