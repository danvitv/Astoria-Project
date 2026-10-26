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
  }) : grants = Set.unmodifiable(grants),
       globalSource = null {
    requireSupportPermissionId(supportSessionId);
    requireSupportPermissionId(policyIdentity);
    if (revision < 0 ||
        revision > maxSupportPermissionRevision ||
        this.grants.any((right) => !hasScopeFor(right))) {
      throw StateError('Invalid permission preferences.');
    }
  }

  /// Trusted global projection only. The original strict profile retains exact
  /// source ownership; configured grants without a current scope never authorize.
  SupportPermissionPreferences.fromGlobalProfile(
    SupportPermissionPreferences source,
    String currentSessionId,
  ) : supportSessionId = currentSessionId,
      policyIdentity = source.policyIdentity,
      revision = source.revision,
      grants = source.grants,
      recipient = source.recipient,
      globalSource = source,
      scope = _projectScope(source, currentSessionId) {
    requireSupportPermissionId(currentSessionId);
    if (source.globalSource != null) {
      throw StateError('Nested global permission projection.');
    }
  }
  static const version = 1;
  final String supportSessionId, policyIdentity;
  final int revision;
  final Set<SupportPermission> grants;
  final SupportPermissionScope? scope;
  final SupportPermissionRecipient? recipient;
  final SupportPermissionPreferences? globalSource;
  bool get isGlobal => globalSource != null;

  /// Configuration display ONLY, not authorization. Use allows for every effect.
  bool isConfigured(SupportPermission right) => grants.contains(right);
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
        s?.gameSessionId != null && (s!.hasGameHistory || gameData),
      SupportPermission.modelGameHistory =>
        recipient != null && (s?.hasGameHistory ?? false),
      SupportPermission.reportGameHistory => s?.hasGameHistory ?? false,
      SupportPermission.modelSupportHistory =>
        recipient != null && (s?.hasSupportHistory ?? false),
      SupportPermission.reportSupportHistory => s?.hasSupportHistory ?? false,
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
  ) => globalSource != null
      ? SupportPermissionPreferences.fromGlobalProfile(
          globalSource!.withNativeGrant(right, enabled),
          supportSessionId,
        )
      : SupportPermissionPreferences(
          supportSessionId: supportSessionId,
          policyIdentity: policyIdentity,
          revision: nextRevision,
          scope: scope,
          recipient: recipient,
          grants: enabled
              ? {...grants, right}
              : (Set.of(grants)..remove(right)),
        );

  /// A new scope revokes every scope-dependent grant. Conservative revocation
  /// avoids guessing which message/category change can reuse previous consent.
  SupportPermissionPreferences withNativeScope(
    SupportPermissionScope? next, {
    bool supportHistorySelected = false,
  }) {
    final source = globalSource;
    if (source != null) {
      final old = source.scope;
      // An unrelated picker must not rebind a hidden old-chat selection. Only a
      // fresh support picker may replace its owner; private handles are not moved.
      final merged = next == null
          ? null
          : SupportPermissionScope(
              selectionRevision: next.selectionRevision,
              gameSessionId: next.gameSessionId,
              gameHistory: next.gameHistory,
              gameHistoryExtent: next.gameHistoryExtent,
              supportHistory: supportHistorySelected
                  ? next.supportHistory
                  : old?.supportHistory,
              supportHistoryExtent: supportHistorySelected
                  ? next.supportHistoryExtent
                  : old?.supportHistoryExtent ??
                        SupportHistoryExtent.selectedMessages,
              safeCategories: next.safeCategories,
              selectedData:
                  supportHistorySelected &&
                      source.supportSessionId != supportSessionId
                  ? const {}
                  : next.selectedData,
            );
      final changed = source.withNativeScope(merged);
      final owned = supportHistorySelected
          ? SupportPermissionPreferences(
              supportSessionId: supportSessionId,
              policyIdentity: changed.policyIdentity,
              revision: changed.revision,
              grants: changed.grants,
              scope: changed.scope,
              recipient: changed.recipient,
            )
          : changed;
      return SupportPermissionPreferences.fromGlobalProfile(
        owned,
        supportSessionId,
      );
    }
    return SupportPermissionPreferences(
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
  }

  SupportPermissionPreferences withNativeRecipient(
    SupportPermissionRecipient? next,
  ) => globalSource != null
      ? SupportPermissionPreferences.fromGlobalProfile(
          globalSource!.withNativeRecipient(next),
          supportSessionId,
        )
      : SupportPermissionPreferences(
          supportSessionId: supportSessionId,
          policyIdentity: policyIdentity,
          revision: nextRevision,
          scope: scope,
          recipient: next,
          grants:
              recipient?.sameAs(next) == true ||
                  (recipient == null && next == null)
              ? grants
              : grants.where((r) => !_recipientDependent.contains(r)),
        );
  static SupportPermissionScope? _projectScope(
    SupportPermissionPreferences source,
    String currentSessionId,
  ) {
    final s = source.scope;
    if (s == null || source.supportSessionId == currentSessionId) return s;
    return SupportPermissionScope(
      selectionRevision: s.selectionRevision,
      gameSessionId: s.gameSessionId,
      gameHistory: s.gameHistory,
      gameHistoryExtent: s.gameHistoryExtent,
      // Whole CURRENT support chat is an explicit rule. Selected IDs and private
      // data handles remain attached to their recorded originating owner.
      supportHistoryExtent: s.supportHistoryExtent,
      safeCategories: s.safeCategories,
    );
  }

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
