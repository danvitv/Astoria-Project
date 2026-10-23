part of 'api_config_repo.dart';

/// Finite native action kinds; arbitrary journal records cannot dispatch effects.
enum SupportProviderSetupAction { create, update }

/// Strict canonical inner schema bound to the existing encrypted journal envelope.
/// Only the owned immutable native fields appear; no ApiConfig serialization.
abstract final class SupportProviderSetupEvidence {
  static String encode({
    required SupportProviderSetupAction action,
    required String sessionId,
    required String connectionId,
    required KeylessApiConfigView? state,
  }) {
    final identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
    if (!identifier.hasMatch(sessionId) ||
        !identifier.hasMatch(connectionId) ||
        (state != null &&
            (!state.isValid || state.connectionId != connectionId))) {
      throw const FormatException('Invalid native provider evidence.');
    }
    return SupportMutationEvidence.encode(
      jsonEncode({
        'v': 1,
        'action': action.name,
        'sessionId': sessionId,
        'connectionId': connectionId,
        'exists': state != null,
        'fields': state == null
            ? null
            : {
                'displayName': state.displayName,
                'providerId': state.providerId,
                'protocol': state.protocol,
                'endpoint': state.endpoint,
                'model': state.model,
                'maxTokens': state.maxTokens,
                'contextSize': state.contextSize,
                'temperature': state.temperature,
              },
      }),
    );
  }

  static bool matches(
    SupportMutationRecord record,
    SupportProviderSetupAction action,
    String id,
    KeylessApiConfigView? before,
    KeylessApiConfigView after,
  ) {
    try {
      return !record.isLocked &&
          record.status == 'pending' &&
          record.domain == SupportProviderSetupRepo.domain &&
          record.targetId == id &&
          record.beforeJson ==
              encode(
                action: action,
                sessionId: record.sessionId,
                connectionId: id,
                state: before,
              ) &&
          record.afterJson ==
              encode(
                action: action,
                sessionId: record.sessionId,
                connectionId: id,
                state: after,
              );
    } on FormatException {
      return false;
    }
  }
}

/// Native same-owner result only. Journal history cannot reconstruct this handle.
final class SupportProviderSetupReceipt {
  SupportProviderSetupReceipt._(
    this.action,
    this._effect,
    this._journal,
    this._owner,
  );
  final SupportProviderSetupAction action;
  final KeylessApiConfigReceipt _effect;
  final SupportMutationReservation _journal;
  final SupportProviderSetupRepo _owner;
  bool _consumed = false;
  String get connectionId => _effect.connectionId;
  String get journalId => _journal.record.id;
  String get sessionId => _journal.record.sessionId;
  KeylessApiConfigView? get before => _effect.before;
  KeylessApiConfigView? get after => _effect.after;
  SupportMutationStatus get status => _journal.status;
}
