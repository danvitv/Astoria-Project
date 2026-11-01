import 'support_report_error.dart';
import 'support_report_json.dart';

/// Version-one payload grammar shared by export and the standalone decoder.
/// No tolerant top-level fields, duplicate blocks, unknown derivative IDs or
/// dependency references to excluded content are accepted.
abstract final class SupportReportPayload {
  static const _personal = {
    'repairMetadata',
    'gameTitle',
    'supportTitle',
    'gameCommentary',
    'supportCommentary',
  };
  static const _safe = {
    'environment',
    'configuration',
    'captures',
    'events',
    'diagnoses',
    'commentaryNotice',
  };
  static Object? validate(
    String text, {
    required String reportId,
    required int createdDay,
  }) {
    Never bad() =>
        throw const SupportReportException(SupportReportFailure.invalidPacket);
    final value = SupportReportJson.decode(text);
    if (value is! Map<String, dynamic> ||
        value.length != 5 ||
        !value.keys.toSet().containsAll([
          'version',
          'reportId',
          'createdDay',
          'blocks',
          'omissions',
        ]) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['reportId'] != reportId ||
        value['createdDay'] is! int ||
        value['createdDay'] != createdDay ||
        value['blocks'] is! List ||
        value['omissions'] is! List ||
        SupportReportJson.canonical(value) != text) {
      bad();
    }
    final blocks = value['blocks'] as List;
    final omissions = value['omissions'] as List;
    if (blocks.length > 16 ||
        omissions.length > 256 ||
        omissions.any((o) => o is! String || o.length > 1024)) {
      bad();
    }
    final ids = <String>{};
    final deps = <String, List<String>>{};
    for (final block in blocks) {
      if (block is! Map<String, dynamic> ||
          block.length != 5 ||
          !block.keys.toSet().containsAll([
            'id',
            'title',
            'personal',
            'dependencies',
            'content',
          ]) ||
          block['id'] is! String ||
          block['title'] is! String ||
          (block['title'] as String).length > 128 ||
          block['personal'] is! bool ||
          block['dependencies'] is! List) {
        bad();
      }
      final id = block['id'] as String;
      if (!ids.add(id) ||
          (!_personal.contains(id) && !_safe.contains(id)) ||
          block['personal'] != _personal.contains(id)) {
        bad();
      }
      final dependencies = block['dependencies'] as List;
      if (dependencies.length > 16 ||
          dependencies.any((d) => d is! String || d == id) ||
          dependencies.toSet().length != dependencies.length) {
        bad();
      }
      deps[id] = dependencies.cast<String>();
    }
    for (final entry in deps.entries) {
      if (entry.value.any((d) => !ids.contains(d))) bad();
      if (entry.key == 'diagnoses' && !entry.value.toSet().contains('events')) {
        bad();
      }
      if (entry.key == 'commentaryNotice' &&
          !entry.value.toSet().contains('supportCommentary')) {
        bad();
      }
    }
    final visiting = <String>{}, done = <String>{};
    void walk(String id) {
      if (done.contains(id)) return;
      if (!visiting.add(id)) bad();
      for (final dep in deps[id]!) {
        walk(dep);
      }
      visiting.remove(id);
      done.add(id);
    }

    for (final id in ids) {
      walk(id);
    }
    return value;
  }
}
