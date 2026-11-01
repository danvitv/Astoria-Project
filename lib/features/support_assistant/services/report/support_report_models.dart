import '../../../../core/support_report/support_report_json.dart';

final class SupportReportPrepareRequest {
  const SupportReportPrepareRequest({
    this.gameSessionId,
    this.supportSessionId,
    this.includeTitles = false,
    this.includeProse = false,
  });
  final String? gameSessionId, supportSessionId;
  final bool includeTitles, includeProse;
  bool get requiresApplicationData =>
      gameSessionId != null ||
      supportSessionId != null ||
      includeTitles ||
      includeProse;
}

final class SupportReportBlock {
  SupportReportBlock({
    required this.id,
    required this.title,
    required this.personal,
    Iterable<String> dependencies = const [],
    required Object? content,
  }) : dependencies = Set<String>.unmodifiable(dependencies),
       contentJson = SupportReportJson.canonical(content);
  final String id, title, contentJson;
  final bool personal;
  final Set<String> dependencies;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'personal': personal,
    'dependencies': dependencies.toList()..sort(),
    'content': SupportReportJson.decode(contentJson),
  };
}

/// Pure dependency closure shared by native preview exclusion and bounded tests.
abstract final class SupportReportExclusions {
  static Set<String> closure(
    Iterable<SupportReportBlock> blocks,
    Set<String> selected,
  ) {
    final all = blocks.toList(growable: false);
    final removed = Set<String>.of(selected);
    var changed = true;
    while (changed) {
      changed = false;
      for (final block in all) {
        if (!removed.contains(block.id) &&
            block.dependencies.any(removed.contains)) {
          removed.add(block.id);
          changed = true;
        }
      }
    }
    return Set<String>.unmodifiable(removed);
  }
}

/// Only the coordinator can issue usable previews. Payload is canonical,
/// detached, bounded and immutable. UI displays the WHOLE exact payload.
final class SupportReportPreview {
  SupportReportPreview.internal({
    required this.payloadJson,
    required this.blocks,
    required this.omissions,
    required this.recipientConfigured,
    // Public named argument while retaining private native retirement callback.
    required bool Function() retired,
    // ignore: prefer_initializing_formals
  }) : _retired = retired;
  final String payloadJson;
  final List<SupportReportBlock> blocks;
  final List<String> omissions;
  final bool recipientConfigured;
  final bool Function() _retired;
  bool get isRetired => _retired();
  @override
  String toString() => 'SupportReportPreview';
}
