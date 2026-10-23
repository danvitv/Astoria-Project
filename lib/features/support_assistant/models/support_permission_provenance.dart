import 'package:flutter/foundation.dart';
import 'support_permission_preferences.dart';
import 'support_permission_scope.dart';

enum SupportPermissionUse { localRead, modelContext, reportPreparation }

enum SupportSourceKind {
  gameHistory,
  supportHistory,
  safeProjection,
  selectedData,
}

enum SupportProvenanceWrapper { source, summary, toolResult, agentResult }

/// Native source declarations, never parsed from arbitrary model/card text.
/// Exact IDs or the explicit finite session extent remain attached when content
/// becomes a summary/tool/agent result. This never approves a model snapshot.
@immutable
final class SupportPermissionSource {
  /// The exact game target; the authorization lease separately owns the current
  /// support policy/session. This constructor carries no selected-message IDs.
  SupportPermissionSource.gameSessionHistory(String id)
    : this._(
        null,
        SupportSourceKind.gameHistory,
        id,
        const [],
        null,
        null,
        historyExtent: SupportHistoryExtent.wholeSession,
      );
  SupportPermissionSource.supportSessionHistory(String id)
    : this._(
        id,
        SupportSourceKind.supportHistory,
        null,
        const [],
        null,
        null,
        historyExtent: SupportHistoryExtent.wholeSession,
      );
  SupportPermissionSource.gameHistory(
    String supportId,
    String gameId,
    SupportMessageSelection selection,
  ) : this._(
        supportId,
        SupportSourceKind.gameHistory,
        gameId,
        selection.messageIds,
        null,
        null,
      );
  SupportPermissionSource.supportHistory(
    String supportId,
    SupportMessageSelection selection,
  ) : this._(
        supportId,
        SupportSourceKind.supportHistory,
        null,
        selection.messageIds,
        null,
        null,
      );
  SupportPermissionSource.safeProjection(
    String supportId,
    SupportSafeCategory category,
  ) : this._(
        supportId,
        SupportSourceKind.safeProjection,
        null,
        const [],
        category,
        null,
      );
  SupportPermissionSource.selectedData(
    String supportId,
    String? gameId,
    SupportDataCategory category,
    Iterable<String> ids,
  ) : this._(
        supportId,
        SupportSourceKind.selectedData,
        gameId,
        ids,
        null,
        category,
      );
  SupportPermissionSource._(
    this.supportSessionId,
    this.kind,
    this.gameSessionId,
    Iterable<String> ids,
    this.safeCategory,
    this.dataCategory, {
    this.historyExtent = SupportHistoryExtent.selectedMessages,
  }) : selectedIds = List.unmodifiable(ids) {
    if (supportSessionId != null) {
      requireSupportPermissionId(supportSessionId!);
    }
    if (gameSessionId != null) requireSupportPermissionId(gameSessionId!);
    if (selectedIds.length > 512 ||
        selectedIds.toSet().length != selectedIds.length ||
        (kind != SupportSourceKind.safeProjection &&
            historyExtent != SupportHistoryExtent.wholeSession &&
            selectedIds.isEmpty) ||
        (historyExtent == SupportHistoryExtent.wholeSession &&
            (selectedIds.isNotEmpty ||
                (kind != SupportSourceKind.gameHistory &&
                    kind != SupportSourceKind.supportHistory)))) {
      throw StateError('Invalid permission provenance.');
    }
    selectedIds.forEach(requireSupportPermissionId);
  }
  final String? supportSessionId;
  final String? gameSessionId;
  final SupportSourceKind kind;
  final List<String> selectedIds;
  final SupportSafeCategory? safeCategory;
  final SupportDataCategory? dataCategory;
  final SupportHistoryExtent historyExtent;

  bool sameAs(SupportPermissionSource other) =>
      supportSessionId == other.supportSessionId &&
      kind == other.kind &&
      gameSessionId == other.gameSessionId &&
      historyExtent == other.historyExtent &&
      safeCategory == other.safeCategory &&
      dataCategory == other.dataCategory &&
      listEquals(selectedIds, other.selectedIds);

  bool isSelectedBy(SupportPermissionPreferences p) {
    if ((supportSessionId != null && supportSessionId != p.supportSessionId) ||
        p.scope == null) {
      return false;
    }
    final s = p.scope!;
    return switch (kind) {
      SupportSourceKind.gameHistory =>
        gameSessionId == s.gameSessionId &&
            historyExtent == s.gameHistoryExtent &&
            (historyExtent == SupportHistoryExtent.wholeSession ||
                (s.gameHistory != null &&
                    listEquals(selectedIds, s.gameHistory!.messageIds))),
      SupportSourceKind.supportHistory =>
        supportSessionId == p.supportSessionId &&
            historyExtent == s.supportHistoryExtent &&
            (historyExtent == SupportHistoryExtent.wholeSession ||
                (s.supportHistory != null &&
                    listEquals(selectedIds, s.supportHistory!.messageIds))),
      SupportSourceKind.safeProjection => s.safeCategories.contains(
        safeCategory,
      ),
      SupportSourceKind.selectedData =>
        gameSessionId == s.gameSessionId &&
            listEquals(selectedIds, s.selectedData[dataCategory]),
    };
  }

  bool allowedFor(SupportPermissionPreferences p, SupportPermissionUse use) {
    if (!isSelectedBy(p)) return false;
    return switch (use) {
      SupportPermissionUse.localRead => switch (kind) {
        SupportSourceKind.gameHistory => p.allows(
          SupportPermission.readGameData,
        ),
        SupportSourceKind.supportHistory =>
          true, // Already local assistant history, never external consent.
        SupportSourceKind.safeProjection => p.allows(
          safeCategory == SupportSafeCategory.diagnostics
              ? SupportPermission.readDiagnostics
              : SupportPermission.readSafeSettings,
        ),
        SupportSourceKind.selectedData =>
          _localGameCategories.contains(dataCategory) &&
              p.allows(SupportPermission.readGameData),
      },
      SupportPermissionUse.modelContext =>
        p.recipient != null &&
            switch (kind) {
              SupportSourceKind.gameHistory => p.allows(
                SupportPermission.modelGameHistory,
              ),
              SupportSourceKind.supportHistory => p.allows(
                SupportPermission.modelSupportHistory,
              ),
              SupportSourceKind.safeProjection => p.allows(
                SupportPermission.modelSafeSettingsDiagnostics,
              ),
              SupportSourceKind.selectedData =>
                _modelGameCategories.contains(dataCategory)
                    ? p.allows(SupportPermission.modelGameData)
                    : dataCategory == SupportDataCategory.attachment
                    ? p.allows(SupportPermission.modelAttachments)
                    : (dataCategory == SupportDataCategory.promptSnippet ||
                              dataCategory ==
                                  SupportDataCategory.providerSnippet) &&
                          p.allows(
                            SupportPermission.modelPromptProviderSnippets,
                          ),
            },
      SupportPermissionUse.reportPreparation => switch (kind) {
        SupportSourceKind.gameHistory => p.allows(
          SupportPermission.reportGameHistory,
        ),
        SupportSourceKind.supportHistory => p.allows(
          SupportPermission.reportSupportHistory,
        ),
        SupportSourceKind.safeProjection =>
          true, // Exact sanitized report approval is still required later.
        SupportSourceKind.selectedData => p.allows(
          SupportPermission.reportPersonalDataAttachments,
        ),
      },
    };
  }

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

/// Trusted synchronous invalidation fence. Native composition must increment
/// epoch BEFORE admitting any consent/recipient/selection/session change, not
/// merely after its async DB write. This catches pending revocation and ABA.
@immutable
final class SupportNativePermissionContext {
  const SupportNativePermissionContext({
    required this.supportSessionId,
    required this.epoch,
    this.scope,
    this.recipient,
  });
  final String supportSessionId;
  final int epoch;
  final SupportPermissionScope? scope;
  final SupportPermissionRecipient? recipient;
  bool sameAs(SupportNativePermissionContext other) =>
      supportSessionId == other.supportSessionId &&
      epoch == other.epoch &&
      (scope == null ? other.scope == null : scope!.sameAs(other.scope)) &&
      (recipient == null
          ? other.recipient == null
          : recipient!.sameAs(other.recipient));
}
