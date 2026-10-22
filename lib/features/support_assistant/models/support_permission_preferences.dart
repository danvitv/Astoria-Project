import 'package:flutter/foundation.dart';
import 'support_permission_scope.dart';

enum SupportPermissionAvailability { available, locked, corrupt, unavailable }

/// Separate product rights, not a generic capability framework. These are
/// prerequisites ONLY: actions/tests/reports still need exact native approval.
enum SupportPermission {
  readSafeSettings,
  readGameData,
  readDiagnostics,
  modelGameHistory,
  modelSupportHistory,
  modelSafeSettingsDiagnostics,
  modelGameData,
  modelPromptProviderSnippets,
  modelAttachments,
  confirmedSettingsChanges,
  confirmedConnectionTests,
  reportGameHistory,
  reportSupportHistory,
  reportPersonalDataAttachments,
}

@immutable
final class SupportPermissionPreferences {
  SupportPermissionPreferences({
    required this.supportSessionId,
    required this.policyIdentity,
    required this.revision,
    Iterable<SupportPermission> grants = const [],
    this.scope,
    this.recipient,
  }) : grants = Set.unmodifiable(grants) {
    requireSupportPermissionId(supportSessionId);
    requireSupportPermissionId(policyIdentity);
    if (revision < 0 ||
        revision > maxSupportPermissionRevision ||
        this.grants.any((right) => !hasScopeFor(right))) {
      throw StateError('Invalid permission preferences.');
    }
  }
  static const version = 1;
  final String supportSessionId, policyIdentity;
  final int revision;
  final Set<SupportPermission> grants;
  final SupportPermissionScope? scope;
  final SupportPermissionRecipient? recipient;
  bool allows(SupportPermission right) =>
      grants.contains(right) && hasScopeFor(right);

  bool hasScopeFor(SupportPermission right) {
    final s = scope;
    final gameData =
        s?.selectedData.keys.any(_localGameCategories.contains) ?? false;
    return switch (right) {
      SupportPermission.readSafeSettings =>
        s != null &&
            s.safeCategories.any((c) => c != SupportSafeCategory.diagnostics),
      SupportPermission.readDiagnostics =>
        s?.safeCategories.contains(SupportSafeCategory.diagnostics) ?? false,
      SupportPermission.readGameData =>
        s?.gameSessionId != null && (s!.gameHistory != null || gameData),
      SupportPermission.modelGameHistory =>
        recipient != null && s?.gameHistory != null,
      SupportPermission.reportGameHistory => s?.gameHistory != null,
      SupportPermission.modelSupportHistory =>
        recipient != null && s?.supportHistory != null,
      SupportPermission.reportSupportHistory => s?.supportHistory != null,
      SupportPermission.modelSafeSettingsDiagnostics =>
        recipient != null && s != null && s.safeCategories.isNotEmpty,
      SupportPermission.modelGameData =>
        recipient != null &&
            (s?.selectedData.keys.any(_modelGameCategories.contains) ?? false),
      SupportPermission.modelPromptProviderSnippets =>
        recipient != null &&
            s != null &&
            s.selectedData.keys.any(
              (c) =>
                  c == SupportDataCategory.promptSnippet ||
                  c == SupportDataCategory.providerSnippet,
            ),
      SupportPermission.modelAttachments =>
        recipient != null &&
            (s?.selectedData.containsKey(SupportDataCategory.attachment) ??
                false),
      SupportPermission.reportPersonalDataAttachments =>
        s != null && s.selectedData.isNotEmpty,
      SupportPermission.confirmedConnectionTests => recipient != null,
      SupportPermission.confirmedSettingsChanges => true,
    };
  }

  /// Used by trusted native store updates, never model/card/import input.
  SupportPermissionPreferences withNativeGrant(
    SupportPermission right,
    bool enabled,
  ) => SupportPermissionPreferences(
    supportSessionId: supportSessionId,
    policyIdentity: policyIdentity,
    revision: nextRevision,
    scope: scope,
    recipient: recipient,
    grants: enabled ? {...grants, right} : (Set.of(grants)..remove(right)),
  );

  /// A new scope revokes every scope-dependent grant. Conservative revocation
  /// avoids guessing which message/category change can reuse previous consent.
  SupportPermissionPreferences withNativeScope(SupportPermissionScope? next) =>
      SupportPermissionPreferences(
        supportSessionId: supportSessionId,
        policyIdentity: policyIdentity,
        revision: nextRevision,
        scope: next,
        recipient: recipient,
        grants: scope?.sameAs(next) == true || (scope == null && next == null)
            ? grants
            : grants.where(
                (r) =>
                    r == SupportPermission.confirmedSettingsChanges ||
                    r == SupportPermission.confirmedConnectionTests,
              ),
      );

  SupportPermissionPreferences withNativeRecipient(
    SupportPermissionRecipient? next,
  ) => SupportPermissionPreferences(
    supportSessionId: supportSessionId,
    policyIdentity: policyIdentity,
    revision: nextRevision,
    scope: scope,
    recipient: next,
    grants:
        recipient?.sameAs(next) == true || (recipient == null && next == null)
        ? grants
        : grants.where((r) => !_recipientDependent.contains(r)),
  );
  int get nextRevision {
    if (revision == maxSupportPermissionRevision) {
      throw StateError('Permission revision exhausted.');
    }
    return revision + 1;
  }

  static const _recipientDependent = {
    SupportPermission.modelGameHistory,
    SupportPermission.modelSupportHistory,
    SupportPermission.modelSafeSettingsDiagnostics,
    SupportPermission.modelGameData,
    SupportPermission.modelPromptProviderSnippets,
    SupportPermission.modelAttachments,
    SupportPermission.confirmedConnectionTests,
  };
  static const _localGameCategories = {
    SupportDataCategory.character,
    SupportDataCategory.memory,
    SupportDataCategory.lore,
    SupportDataCategory.canon,
    SupportDataCategory.variables,
  };
  static const _modelGameCategories = {
    SupportDataCategory.character,
    SupportDataCategory.memory,
    SupportDataCategory.lore,
  };
}

@immutable
final class SupportPermissionSnapshot {
  const SupportPermissionSnapshot(this.availability, [this.preferences]);
  final SupportPermissionAvailability availability;
  final SupportPermissionPreferences? preferences;
  bool get isAvailable =>
      availability == SupportPermissionAvailability.available &&
      preferences != null;
}

final class SupportPermissionsUnavailable extends StateError {
  SupportPermissionsUnavailable(this.availability)
    : super('Permissions unavailable.');
  final SupportPermissionAvailability availability;
}
