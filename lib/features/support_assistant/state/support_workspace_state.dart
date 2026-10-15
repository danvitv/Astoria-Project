import 'package:flutter/foundation.dart';
import '../models/support_workspace_models.dart';

@immutable
class SupportWorkspaceState {
  const SupportWorkspaceState({this.sessions = const [], this.activeSessionId = '', this.messagesBySession = const {}, this.settings = const SupportAssistantSettings(), this.sessionSearchQuery = '', this.lastHandledTopic, this.isLoading = true, this.isBusy = false, this.error});
  final List<SupportSessionSummary> sessions;
  final String activeSessionId;
  final Map<String, List<SupportMessageItem>> messagesBySession;
  final SupportAssistantSettings settings;
  final String sessionSearchQuery;
  final String? lastHandledTopic, error;
  final bool isLoading, isBusy;
  SupportSessionSummary? get activeSession => sessions.where((s) => s.id == activeSessionId).firstOrNull;
  List<SupportMessageItem> get activeMessages => messagesBySession[activeSessionId] ?? const [];
  List<SupportSessionSummary> get filteredSessions {
    final q = sessionSearchQuery.trim().toLowerCase();
    final result = sessions.where((s) => s.title.toLowerCase().contains(q)).toList();
    result.sort((a, b) => a.pinned != b.pinned ? (a.pinned ? -1 : 1) : b.updatedAt.compareTo(a.updatedAt));
    return result;
  }
  SupportWorkspaceState copyWith({List<SupportSessionSummary>? sessions, String? activeSessionId, Map<String, List<SupportMessageItem>>? messagesBySession, SupportAssistantSettings? settings, String? sessionSearchQuery, String? lastHandledTopic, bool? isLoading, bool? isBusy, String? error, bool clearError = false}) => SupportWorkspaceState(sessions: sessions ?? this.sessions, activeSessionId: activeSessionId ?? this.activeSessionId, messagesBySession: messagesBySession ?? this.messagesBySession, settings: settings ?? this.settings, sessionSearchQuery: sessionSearchQuery ?? this.sessionSearchQuery, lastHandledTopic: lastHandledTopic ?? this.lastHandledTopic, isLoading: isLoading ?? this.isLoading, isBusy: isBusy ?? this.isBusy, error: clearError ? null : error ?? this.error);
}
