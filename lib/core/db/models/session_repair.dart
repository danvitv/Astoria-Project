/// Fixed metadata vocabulary. No stored key, value, claim, JSON or SQL belongs
/// in a report. These findings establish structure, never narrative truth.
enum SessionRepairTargetKind {
  collectorAttempt,
  observation,
  liveLedger,
  reconciliation,
}

enum SessionRepairIssue {
  malformedPayload,
  invalidShape,
  unknownStatus,
  missingReference,
  incompleteEvidence,
  truncatedEvidence,
  invalidChain,
  invalidEffect,
  protectedTarget,
  lockedTarget,
  aggregateOriginalUnavailable,
  dependentEffectUnsupported,
  oversized,
  incompleteInspection,
  authorityDenied,
  staleSource,
  invalidValue,
  unsupportedTarget,
}

enum SessionRepairAvailability {
  deleteUnusedAttempt,
  correctExistingValue,
  unavailable,
}

enum SessionRepairOutcome { applied, undone, undoConflict }

/// Sanitized failure; an unknown commit delivery failure is NOT proof of no
/// effect. Observe the original encrypted journal; never automatically replay.
final class SessionRepairStorageException implements Exception {
  const SessionRepairStorageException();
  @override
  String toString() => 'SessionRepairStorageException(storageFailed)';
}
