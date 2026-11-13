import 'dart:convert';

import '../../models/character_knowledge_fact.dart';
import '../studio_ledger_export_parser.dart';

/// Output syntax and validation constraints only; semantic rules live in Studio.
/// Does not alter parsing or the deterministic format-repair security boundary.
abstract final class LedgerWireContract {
  static const turnExportTemplate = '{"ops":[],"knowledgeFacts":[]}';

  static String turn({required String focalUserName}) =>
      _build(focalUserName: focalUserName, reconciliation: false);

  static String reconciliation({required String focalUserName}) =>
      _build(focalUserName: focalUserName, reconciliation: true);

  static String _build({
    required String focalUserName,
    required bool reconciliation,
  }) {
    final schema = {
      'mode': reconciliation ? 'reconciliation' : 'turn',
      'op': {
        'op': kAllowedOpCodes.toList(),
        'key': 'allowed tracker key',
        'value': 'string; required nonblank for set; max 1200 UTF-16 units',
        'evidence': 'optional string',
        'eventState': kAllowedEventStates.toList(),
      },
      'keys': _keys,
      'knowledgeFact': {
        'knowerKey': 'nonblank string',
        'knowerName': 'optional string',
        'subjectKey': 'nonblank string',
        'subjectName': 'optional string',
        'factClass': CharacterKnowledgeFactClass.values
            .map((value) => value.wireName)
            .toList(),
        'scopeKey': 'optional string, max 160 UTF-16 units',
        'predicate': 'nonblank string, max 120 UTF-16 units',
        'object': 'nonblank string',
        'epistemicState': CharacterKnowledgeEpistemicState.values
            .map((value) => value.wireName)
            .toList(),
        'confidence': 'optional number 0..1, default 0.5',
        'importance': 'optional number 0..1, default 0.5',
        'entities': 'optional string[]',
        'topics': 'optional string[]',
        'supersedesId': 'optional string or null',
      },
      'focalUserName': focalUserName,
      'cleanup': {
        'required': reconciliation,
        'retract': reconciliation
            ? {'op': 'retract', 'factId': 'offered fact ID only'}
            : 'not allowed: no fact IDs offered on turn',
        'rename_entity': {
          'op': 'rename_entity',
          'fromKey': reconciliation
              ? 'descriptive alias among offered fact entity keys'
              : 'descriptive alias among supplied entity alias keys',
          'toKey': r'entity:[a-z0-9_:-]+; different from fromKey',
          'canonicalName': reconciliation
              ? 'nonblank string, max 100 UTF-16 units; substring of review text'
              : 'nonblank string, max 100 UTF-16 units; substring of recent chat or final response',
        },
        'max_ops': 50,
      },
    };
    final clock = reconciliation
        ? 'Reconciliation: knowledgeFacts must be []; all world:time, world:date '
              'and world:day writes (including delete) are rejected.'
        : 'Turn clock writes are optional and set-only, with no duplicate keys. '
              'They require a complete current clock; omitted components inherit '
              'current values. Formats: world:time=24h HH:MM, world:date=valid '
              'DD.MM.YYYY, world:day=nonnegative integer. Date and day must '
              'advance equally; total time cannot move backward. Invalid clock '
              'updates are rejected atomically.';
    final cleanupTemplate = reconciliation
        ? '\n<glaze_knowledge_cleanup>\n{"ops":[]}\n</glaze_knowledge_cleanup>'
        : '';
    return '''<ledger_wire_contract>
Schema below describes fields, not data to copy. set replaces the entire value;
delete may omit value. eventState is optional (default empty); factClass defaults
to knowledge and epistemicState to observed. No evidence/reason field is required.
Focal identity matches focalUserName or {{user}}, ignoring case, surrounding
whitespace and an entity: prefix. npc/arc writes owned by that identity are
forbidden. Facts with that knowerKey must have factClass=knowledge and epistemicState
observed, heard_claim or confirmed.
${jsonEncode(schema)}
$clock
Response template: empty arrays mean no changes; populate arrays with schema
objects when needed. Cleanup is optional on turn, required on reconciliation.
Optional <studio_ledger>text</studio_ledger> is display-only.
<glaze_memory_export>
$turnExportTemplate
</glaze_memory_export>$cleanupTemplate
</ledger_wire_contract>''';
  }

  static const _keys = {
    'npc:<name>.<field>': [
      'relationship_to_user',
      'attitude_to_user',
      'trust_to_user',
      'boundaries',
      'card_overrides',
      'location',
      'current_emotional_residue',
      'current_goal',
      'persistent_condition',
    ],
    'relationship:<name>:<name>.<field>': [
      'trust',
      'status',
      'relationship',
      'attitude',
      'boundaries',
      'card_override',
    ],
    'arc:<id>.<field>': [
      'status',
      'title',
      'summary',
      'do_not_reopen',
      'card_override',
    ],
    'world:<field>': [
      'location',
      'time',
      'date',
      'day',
      'active_threats',
      'current_conditions',
    ],
    'scene.<field>': [
      'present_entities',
      'absent_backstory_entities',
      'immediate_thread',
      'active_tensions',
    ],
  };
}
