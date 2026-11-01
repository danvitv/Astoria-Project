enum SupportReportFailure {
  unavailable,
  changed,
  consentMissing,
  recipientMissing,
  invalidRecipient,
  invalidPacket,
  tooLarge,
  authenticationFailed,
  unsupportedPlatform,
  protectedKeyUnavailable,
  invalidArguments,
}

final class SupportReportException implements Exception {
  const SupportReportException(this.failure);
  final SupportReportFailure failure;
  @override
  String toString() => 'Support report unavailable (${failure.name}).';
}
