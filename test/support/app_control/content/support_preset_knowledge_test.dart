import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_controller_ontology.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/studio/studio_injection_points.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/content/support_preset_knowledge.dart';

void main() {
  test('catalog is finite, unique and safe for metadata projection', () {
    expect(SupportPresetKnowledge.topics, hasLength(4));
    for (final topic in SupportPresetKnowledge.topics) {
      final records = SupportPresetKnowledge.records(topic);
      expect(records, isNotEmpty, reason: topic);
      expect(
        records.map((record) => record.id).toSet(),
        hasLength(records.length),
      );
      for (final record in records) {
        for (final value in record.toJson().values.whereType<String>()) {
          expect(value, isNotEmpty, reason: '${record.id} in $topic');
          expect(value.length, lessThanOrEqualTo(256), reason: record.id);
        }
      }
      expect(() => records.clear(), throwsUnsupportedError);
    }
  });

  test(
    'ordinary hard blocks and Studio runtime enums stay fully represented',
    () {
      final ordinary = SupportPresetKnowledge.records('ordinaryPlacement');
      expect(
        ordinary
            .where((record) => record.id.startsWith('block:'))
            .map((record) => record.id.substring('block:'.length))
            .toSet(),
        staticPresetBlockIds,
      );

      final routing = SupportPresetKnowledge.records('studioRouting');
      expect(
        routing
            .where((record) => record.id.startsWith('point:'))
            .map((record) => record.id.substring('point:'.length))
            .toList(),
        studioInjectionPoints,
      );
      expect(
        routing
            .where((record) => record.id.startsWith('lane:'))
            .map((record) => record.id.substring('lane:'.length))
            .toList(),
        StudioControllerOntology.specs.map((spec) => spec.id),
      );

      final context = SupportPresetKnowledge.records('studioContext');
      expect(
        context.map((record) => record.id).toList(),
        StudioContextSlot.values.map((slot) => slot.name),
      );
    },
  );

  test(
    'macro catalog distinguishes Raw Recall and generated Studio briefs',
    () {
      final macros = SupportPresetKnowledge.records('macros');
      final syntax = macros.map((record) => record.syntax).join('\n');
      for (final expected in [
        '{{lorebooks}}',
        '{{memory}}',
        '{{studio_state}}',
        '{{gametime}}',
        '{{history}}',
        '{{beautyBrief}}',
      ]) {
        expect(syntax, contains(expected));
      }
      for (final spec in StudioControllerOntology.specs) {
        expect(syntax, contains('{{studio_${spec.id}_brief}}'));
      }
      expect(syntax, isNot(contains('{{recalled_messages}}')));

      final rawRecall = SupportPresetKnowledge.records(
        'ordinaryPlacement',
      ).singleWhere((record) => record.id == 'rawRecall');
      expect(rawRecall.syntax, contains('no preset macro'));
      final slot = SupportPresetKnowledge.records(
        'studioContext',
      ).singleWhere((record) => record.id == 'recalledMessages');
      expect(slot.behavior, contains('not a macro'));
    },
  );
}
