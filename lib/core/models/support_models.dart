import 'package:flutter/foundation.dart';

@immutable
final class SupportSession {
  const SupportSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.mode = 'hybrid',
    this.activeApiConfigId,
    this.activeModelId,
    this.isLocked = false,
  });

  final String id;
  final String title;
  final int createdAt;
  final int updatedAt;
  final bool pinned;
  final String mode;
  final String? activeApiConfigId;
  final String? activeModelId;
  final bool isLocked;

  SupportSession copyWith({
    String? id,
    String? title,
    int? createdAt,
    int? updatedAt,
    bool? pinned,
    String? mode,
    String? activeApiConfigId,
    bool clearActiveApiConfigId = false,
    String? activeModelId,
    bool clearActiveModelId = false,
    bool? isLocked,
  }) {
    return SupportSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pinned: pinned ?? this.pinned,
      mode: mode ?? this.mode,
      activeApiConfigId: clearActiveApiConfigId
          ? null
          : (activeApiConfigId ?? this.activeApiConfigId),
      activeModelId: clearActiveModelId
          ? null
          : (activeModelId ?? this.activeModelId),
      isLocked: isLocked ?? this.isLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'pinned': pinned,
    'mode': mode,
    'activeApiConfigId': activeApiConfigId,
    'activeModelId': activeModelId,
    'isLocked': isLocked,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupportSession &&
          id == other.id &&
          title == other.title &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          pinned == other.pinned &&
          mode == other.mode &&
          activeApiConfigId == other.activeApiConfigId &&
          activeModelId == other.activeModelId &&
          isLocked == other.isLocked;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    createdAt,
    updatedAt,
    pinned,
    mode,
    activeApiConfigId,
    activeModelId,
    isLocked,
  );
}

@immutable
final class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.body,
    String? cards,
    String cardsJson = '',
    this.runId,
    this.status = 'complete',
    required this.createdAt,
    this.isLocked = false,
  }) : cardsJson = cards ?? cardsJson;

  final String id;
  final String sessionId;
  final String role;
  final String body;
  final String cardsJson;
  final String? runId;
  final String status;
  final int createdAt;
  final bool isLocked;

  String get cards => cardsJson;

  SupportMessage copyWith({
    String? id,
    String? sessionId,
    String? role,
    String? body,
    String? cards,
    String? cardsJson,
    String? runId,
    bool clearRunId = false,
    String? status,
    int? createdAt,
    bool? isLocked,
  }) {
    return SupportMessage(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      body: body ?? this.body,
      cardsJson: cards ?? cardsJson ?? this.cardsJson,
      runId: clearRunId ? null : (runId ?? this.runId),
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'role': role,
    'body': body,
    'cardsJson': cardsJson,
    'runId': runId,
    'status': status,
    'createdAt': createdAt,
    'isLocked': isLocked,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupportMessage &&
          id == other.id &&
          sessionId == other.sessionId &&
          role == other.role &&
          body == other.body &&
          cardsJson == other.cardsJson &&
          runId == other.runId &&
          status == other.status &&
          createdAt == other.createdAt &&
          isLocked == other.isLocked;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    role,
    body,
    cardsJson,
    runId,
    status,
    createdAt,
    isLocked,
  );
}

@immutable
final class SupportContextBlock {
  const SupportContextBlock({
    required this.id,
    required this.sessionId,
    required this.startMessageId,
    required this.endMessageId,
    required this.summary,
    String? protectedFacts,
    String protectedFactsJson = '',
    this.isActive = true,
    required this.createdAt,
    this.isLocked = false,
  }) : protectedFactsJson = protectedFacts ?? protectedFactsJson;

  final String id;
  final String sessionId;
  final String startMessageId;
  final String endMessageId;
  final String summary;
  final String protectedFactsJson;
  final bool isActive;
  final int createdAt;
  final bool isLocked;

  String get protectedFacts => protectedFactsJson;

  SupportContextBlock copyWith({
    String? id,
    String? sessionId,
    String? startMessageId,
    String? endMessageId,
    String? summary,
    String? protectedFacts,
    String? protectedFactsJson,
    bool? isActive,
    int? createdAt,
    bool? isLocked,
  }) {
    return SupportContextBlock(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      startMessageId: startMessageId ?? this.startMessageId,
      endMessageId: endMessageId ?? this.endMessageId,
      summary: summary ?? this.summary,
      protectedFactsJson:
          protectedFacts ?? protectedFactsJson ?? this.protectedFactsJson,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'startMessageId': startMessageId,
    'endMessageId': endMessageId,
    'summary': summary,
    'protectedFactsJson': protectedFactsJson,
    'isActive': isActive,
    'createdAt': createdAt,
    'isLocked': isLocked,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupportContextBlock &&
          id == other.id &&
          sessionId == other.sessionId &&
          startMessageId == other.startMessageId &&
          endMessageId == other.endMessageId &&
          summary == other.summary &&
          protectedFactsJson == other.protectedFactsJson &&
          isActive == other.isActive &&
          createdAt == other.createdAt &&
          isLocked == other.isLocked;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    startMessageId,
    endMessageId,
    summary,
    protectedFactsJson,
    isActive,
    createdAt,
    isLocked,
  );
}

@immutable
final class SupportMutationRecord {
  const SupportMutationRecord({
    required this.id,
    required this.sessionId,
    required this.domain,
    required this.targetId,
    String? before,
    String? beforeJson,
    String? after,
    String? afterJson,
    this.status = 'applied',
    required this.createdAt,
    this.isLocked = false,
  }) : assert(before != null || beforeJson != null),
       assert(after != null || afterJson != null),
       beforeJson = before ?? beforeJson ?? '',
       afterJson = after ?? afterJson ?? '';

  final String id;
  final String sessionId;
  final String domain;
  final String targetId;
  final String beforeJson;
  final String afterJson;
  final String status;
  final int createdAt;
  final bool isLocked;

  String get before => beforeJson;
  String get after => afterJson;

  SupportMutationRecord copyWith({
    String? id,
    String? sessionId,
    String? domain,
    String? targetId,
    String? before,
    String? beforeJson,
    String? after,
    String? afterJson,
    String? status,
    int? createdAt,
    bool? isLocked,
  }) {
    return SupportMutationRecord(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      domain: domain ?? this.domain,
      targetId: targetId ?? this.targetId,
      beforeJson: before ?? beforeJson ?? this.beforeJson,
      afterJson: after ?? afterJson ?? this.afterJson,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'domain': domain,
    'targetId': targetId,
    'beforeJson': beforeJson,
    'afterJson': afterJson,
    'status': status,
    'createdAt': createdAt,
    'isLocked': isLocked,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupportMutationRecord &&
          id == other.id &&
          sessionId == other.sessionId &&
          domain == other.domain &&
          targetId == other.targetId &&
          beforeJson == other.beforeJson &&
          afterJson == other.afterJson &&
          status == other.status &&
          createdAt == other.createdAt &&
          isLocked == other.isLocked;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    domain,
    targetId,
    beforeJson,
    afterJson,
    status,
    createdAt,
    isLocked,
  );
}

@immutable
final class SupportReportRecord {
  const SupportReportRecord({
    required this.id,
    required this.sessionId,
    required this.fileHash,
    this.status = 'exported',
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final String fileHash;
  final String status;
  final int createdAt;

  SupportReportRecord copyWith({
    String? id,
    String? sessionId,
    String? fileHash,
    String? status,
    int? createdAt,
  }) {
    return SupportReportRecord(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      fileHash: fileHash ?? this.fileHash,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'fileHash': fileHash,
    'status': status,
    'createdAt': createdAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupportReportRecord &&
          id == other.id &&
          sessionId == other.sessionId &&
          fileHash == other.fileHash &&
          status == other.status &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(id, sessionId, fileHash, status, createdAt);
}
