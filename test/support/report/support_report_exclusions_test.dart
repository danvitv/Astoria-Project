import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_models.dart';

void main() {
  test(
    'personal exclusion removes every transitive quote, summary and hypothesis',
    () {
      SupportReportBlock block(
        String id,
        bool personal, [
        List<String> dependencies = const [],
      ]) => SupportReportBlock(
        id: id,
        title: id,
        personal: personal,
        dependencies: dependencies,
        content: {'text': 'synthetic-$id'},
      );
      final blocks = [
        block('source', true),
        block('quote', false, ['source']),
        block('summary', false, ['quote']),
        block('hypothesis', false, ['summary']),
        block('unknownProse', true),
        block('safeFact', false),
      ];
      final removed = SupportReportExclusions.closure(blocks, {
        'source',
        'unknownProse',
      });
      expect(removed, {
        'source',
        'quote',
        'summary',
        'hypothesis',
        'unknownProse',
      });
      expect(blocks.where((b) => !removed.contains(b.id)).map((b) => b.id), [
        'safeFact',
      ]);
      expect(() => removed.add('new'), throwsUnsupportedError);
    },
  );
}
