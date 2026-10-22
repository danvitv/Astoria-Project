part of '../support_consent_selection_repo.dart';

bool _validPage(int offset, int limit, int cap) =>
    offset >= 0 &&
    offset <= SupportConsentSelectionRepo.maxOffset &&
    limit > 0 &&
    limit <= cap;

bool _validIdentity(String? value, SecretRedactor redactor) =>
    value != null &&
    value.length <= 256 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$').hasMatch(value) &&
    redactor.redactJson(value) == value;

String _safeLabel(String? value, String fallback, SecretRedactor redactor) {
  if (value == null ||
      value.isEmpty ||
      value.length > 256 ||
      value.trimLeft().startsWith('{') ||
      value.trimLeft().startsWith('[') ||
      RegExp(r'[\\/\x00-\x1f\x7f]|://').hasMatch(value)) {
    return fallback;
  }
  // Primitive text only: never parse a label as JSON or serialize objects.
  final safe = redactor.redactJson(value);
  if (safe is! String ||
      safe.isEmpty ||
      safe.length > 120 ||
      safe == SecretRedactor.limited ||
      safe == SecretRedactor.removed) {
    return fallback;
  }
  return safe;
}

SupportConsentMessagePage _unavailableMessages(
  SupportConsentSelectionSource source, {
  SupportConsentSelectionStatus status =
      SupportConsentSelectionStatus.unavailable,
  String? sessionId,
  int? sourceCount,
  SupportConsentSessionOption? roleplaySession,
}) => SupportConsentMessagePage(
  source: source,
  sessionId: sessionId,
  items: const [],
  status: status,
  sourceCount: sourceCount,
  limitedCount: status == SupportConsentSelectionStatus.limited
      ? sourceCount ?? 0
      : 0,
  roleplaySession: roleplaySession,
);

SupportConsentMessagePage _messagePage({
  required SupportConsentSelectionSource source,
  required String sessionId,
  required List<SupportConsentMessageOption> eligible,
  required int sourceCount,
  required int offset,
  required int limit,
  SupportConsentSessionOption? roleplaySession,
}) {
  final items = eligible.skip(offset).take(limit).toList();
  final next = offset + items.length < eligible.length
      ? offset + items.length
      : null;
  return SupportConsentMessagePage(
    source: source,
    sessionId: sessionId,
    items: items,
    status: eligible.length > items.length
        ? SupportConsentSelectionStatus.limited
        : SupportConsentSelectionStatus.available,
    roleplaySession: roleplaySession,
    sourceCount: sourceCount,
    eligibleCount: eligible.length,
    omittedCount: sourceCount - eligible.length,
    limitedCount: eligible.length - items.length,
    nextOffset: next,
  );
}

SupportConsentSelectionRole? _selectionRole(String? value) => switch (value) {
  'user' => SupportConsentSelectionRole.user,
  'assistant' => SupportConsentSelectionRole.assistant,
  'system' => SupportConsentSelectionRole.system,
  _ => null,
};
