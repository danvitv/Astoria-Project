import 'package:flutter/foundation.dart';

/// Only safe projections; never arbitrary preferences, headers or credentials.
enum SupportSafeCategory {
  theme,
  connections,
  regularPresets,
  studioPresets,
  diagnostics,
}

enum SupportDataCategory {
  character,
  memory,
  lore,
  canon,
  variables,
  promptSnippet,
  providerSnippet,
  attachment,
}

enum SupportRecipientProtocol {
  openai,
  openaiResponses,
  anthropic,
  gemini,
  openrouter,
}

void requireSupportPermissionId(String value) {
  if (value.isEmpty ||
      value.length > 256 ||
      RegExp(r'[A-Za-z0-9_.:/-]+').matchAsPrefix(value)?.end != value.length) {
    throw StateError('Invalid permission scope.');
  }
}

/// The IDs are the complete, explicitly selected ordered range, not endpoints
/// to expand later. Hidden messages, swipes and attachments are not inferred.
@immutable
final class SupportMessageSelection {
  SupportMessageSelection(Iterable<String> ids)
    : messageIds = List.unmodifiable(ids) {
    if (messageIds.isEmpty ||
        messageIds.length > 512 ||
        messageIds.toSet().length != messageIds.length) {
      throw StateError('Invalid permission scope.');
    }
    messageIds.forEach(requireSupportPermissionId);
  }
  final List<String> messageIds;
  String get startMessageId => messageIds.first;
  String get endMessageId => messageIds.last;
  bool sameAs(SupportMessageSelection? other) =>
      other != null && listEquals(messageIds, other.messageIds);
}

/// Native, credential-free route projection ONLY. Do not pass raw API config
/// JSON or raw credential-bearing URLs. The native config revision must advance
/// on every endpoint/protocol/model change, including change-away-and-back.
@immutable
final class SupportPermissionRecipient {
  SupportPermissionRecipient({
    required this.connectionId,
    required this.modelId,
    required this.protocol,
    required this.nativeRoute,
    required this.configurationRevision,
  }) {
    requireSupportPermissionId(connectionId);
    requireSupportPermissionId(modelId);
    final uri = Uri.tryParse(nativeRoute);
    // Validate the raw spelling as well as Uri: parsing may normalize aliases,
    // and a `$` anchor can match before a final newline. Operation colons are
    // only the two static Gemini suffixes, not arbitrary path/URL syntax.
    final route = RegExp(
      r'https?://[A-Za-z0-9.\[\]:-]+(/[A-Za-z0-9_./-]*(?::(?:generateContent|streamGenerateContent))?)?',
    ).matchAsPrefix(nativeRoute);
    final rawPath = route?.group(1) ?? '';
    if (nativeRoute.length > 512 ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        nativeRoute.contains('?') ||
        nativeRoute.contains('#') ||
        route?.end != nativeRoute.length ||
        uri.toString() != nativeRoute ||
        rawPath.contains('//') ||
        (rawPath.length > 1 && rawPath.endsWith('/')) ||
        rawPath
            .split('/')
            .any(
              (part) =>
                  part.split(':').first == '.' || part.split(':').first == '..',
            ) ||
        rawPath.contains('/:') ||
        configurationRevision < 1 ||
        configurationRevision > maxSupportPermissionRevision) {
      throw StateError('Invalid permission recipient.');
    }
  }
  final String connectionId, modelId, nativeRoute;
  final SupportRecipientProtocol protocol;
  final int configurationRevision;
  bool sameAs(SupportPermissionRecipient? other) =>
      other != null &&
      connectionId == other.connectionId &&
      modelId == other.modelId &&
      protocol == other.protocol &&
      nativeRoute == other.nativeRoute &&
      configurationRevision == other.configurationRevision;
}

const maxSupportPermissionRevision = 9007199254740991;

/// No null selection means all. Data/file IDs are native picker handles, not
/// filesystem paths or content. Revision advances for every native selection
/// change, including ABA. Support history belongs to the policy's own session.
@immutable
final class SupportPermissionScope {
  SupportPermissionScope({
    required this.selectionRevision,
    this.gameSessionId,
    this.gameHistory,
    this.supportHistory,
    Iterable<SupportSafeCategory> safeCategories = const [],
    Map<SupportDataCategory, Iterable<String>> selectedData = const {},
  }) : safeCategories = Set.unmodifiable(safeCategories),
       selectedData = Map.unmodifiable(
         selectedData.map(
           (key, ids) => MapEntry(key, List<String>.unmodifiable(ids)),
         ),
       ) {
    if (selectionRevision < 1 ||
        selectionRevision > maxSupportPermissionRevision ||
        (gameSessionId == null &&
            (gameHistory != null ||
                this.selectedData.keys.any(_gameCategories.contains)))) {
      throw StateError('Invalid permission scope.');
    }
    if (gameSessionId != null) requireSupportPermissionId(gameSessionId!);
    for (final ids in this.selectedData.values) {
      if (ids.isEmpty || ids.length > 128 || ids.toSet().length != ids.length) {
        throw StateError('Invalid permission scope.');
      }
      ids.forEach(requireSupportPermissionId);
    }
  }
  final int selectionRevision;
  final String? gameSessionId;
  final SupportMessageSelection? gameHistory, supportHistory;
  final Set<SupportSafeCategory> safeCategories;
  final Map<SupportDataCategory, List<String>> selectedData;
  static const _gameCategories = {
    SupportDataCategory.character,
    SupportDataCategory.memory,
    SupportDataCategory.lore,
    SupportDataCategory.canon,
    SupportDataCategory.variables,
  };
  bool sameAs(SupportPermissionScope? other) =>
      other != null &&
      selectionRevision == other.selectionRevision &&
      gameSessionId == other.gameSessionId &&
      _sameMessages(gameHistory, other.gameHistory) &&
      _sameMessages(supportHistory, other.supportHistory) &&
      setEquals(safeCategories, other.safeCategories) &&
      selectedData.length == other.selectedData.length &&
      selectedData.entries.every(
        (e) => listEquals(e.value, other.selectedData[e.key]),
      );
  static bool _sameMessages(
    SupportMessageSelection? a,
    SupportMessageSelection? b,
  ) => a == null ? b == null : a.sameAs(b);
}
