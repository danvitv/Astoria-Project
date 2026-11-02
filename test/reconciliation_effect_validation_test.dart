import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo repo;

  setUp(() {
    // validateEffectRow only uses these synthetic rows, never opens the DB.
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LedgerReconciliationRunRepo(db);
  });
  tearDown(() => db.close());

  test('preserves exact nested states and added, changed, removed effects', () {
    final removedLedger = {'name': 'removed', 'value': null};
    final oldLedger = {
      'name': 'changed',
      'value': {
        'z': '猫😀 / \\ "quoted"\n\t',
        'a': [
          1,
          1.0,
          -0.0,
          null,
          true,
          false,
          {'я': 'é', 'a': '𐐀'},
        ],
      },
    };
    final newLedger = {
      ...oldLedger,
      'value': {'a': 1.0, 'z': false},
    };
    final addedLedger = {
      'name': 'added',
      'value': [null, true],
    };
    final removedFact = {'id': 'removed', 'text': 'old'};
    final oldFact = {'id': 'changed', 'text': '猫\n"fact"', 'rank': 1};
    final newFact = {...oldFact, 'rank': 1.0};
    final addedFact = {'id': 'added', 'text': 'новый 😀'};
    final before = _snapshot(
      [removedLedger, oldLedger],
      [removedFact, oldFact],
    );
    final after = _snapshot([newLedger, addedLedger], [newFact, addedFact]);
    final effect = _effect(before, after);

    expect(
      effect.actualEffectsJson,
      _legacyCanonicalJson({
        'ledger': {
          'added': [addedLedger],
          'removed': [removedLedger],
          'changed': [
            {'before': oldLedger, 'after': newLedger},
          ],
        },
        'knowledge': {
          'added': [addedFact],
          'removed': [removedFact],
          'changed': [
            {'before': oldFact, 'after': newFact},
          ],
        },
      }),
    );
    _expectEquivalent(repo, effect);
  });

  test('accepts empty and populated no-op effects', () {
    for (final state in [
      _snapshot([], []),
      _snapshot(
        [
          {
            'name': 'z',
            'value': {'null': null, 'bool': true},
          },
          {
            'name': 'a',
            'value': [1, 1.0, '猫😀'],
          },
        ],
        [
          {'id': 'fact', 'text': '"quoted"\\\n'},
        ],
      ),
    ]) {
      final effect = _effect(state, state);
      expect(effect.actualEffectsJson, _legacyCanonicalJson(_emptyEffects));
      _expectEquivalent(repo, effect);
    }
  });

  test('preserves large unchanged nested snapshots and cached hashes', () {
    final evidence = List.filled(1024, '猫 evidence \\"\n').join();
    final state = _snapshot(
      [
        for (var i = 0; i < 64; i++)
          {
            'name': 'ledger-$i',
            'value': {'evidence': evidence, 'ordinal': i},
          },
      ],
      [
        for (var i = 0; i < 64; i++)
          {
            'id': 'fact-$i',
            'details': {'evidence': evidence, 'active': true},
          },
      ],
    );
    final effect = _effect(state, state);
    _expectEquivalent(repo, effect);
    final valid =
        repo.validateEffectRow(_run, effect) as ReconciliationEffectValid;
    for (var i = 0; i < 3; i++) {
      expect(valid.before.hash, state.hash);
      expect(valid.after.hash, state.hash);
    }
  });

  test('keeps last duplicate and ignores non-string or missing identities', () {
    final before = _snapshot(
      [
        {'name': 'same', 'value': 'ignored duplicate'},
        {'value': 'missing identity'},
        {'name': null, 'value': 'null identity'},
        {'name': 7, 'value': 'numeric identity'},
        {'name': false, 'value': 'boolean identity'},
        {'name': 'same', 'value': 'last wins'},
        {'name': '', 'value': 1},
      ],
      [
        {'id': 'same', 'text': 'ignored duplicate'},
        {'text': 'missing identity'},
        {'id': <Object?>[], 'text': 'list identity'},
        {'id': <String, Object?>{}, 'text': 'object identity'},
        {'id': 'same', 'text': 'last wins'},
        {'id': '', 'text': 'empty identity is valid'},
      ],
    );
    final after = _snapshot(
      [
        {'name': 'same', 'value': 'last wins'},
        {'name': 'same', 'value': 'changed last'},
        {'name': '', 'value': 1},
        {'value': 'changed but still ignored'},
      ],
      [
        {'id': 'same', 'text': 'last wins'},
        {'id': '', 'text': 'empty identity is valid'},
        {'id': true, 'text': 'ignored'},
      ],
    );
    final effect = _effect(before, after);
    expect(
      effect.actualEffectsJson,
      _legacyCanonicalJson({
        ..._emptyEffects,
        'ledger': {
          'added': <Map<String, dynamic>>[],
          'removed': <Map<String, dynamic>>[],
          'changed': [
            {
              'before': {'name': 'same', 'value': 'last wins'},
              'after': {'name': 'same', 'value': 'changed last'},
            },
          ],
        },
      }),
    );
    _expectEquivalent(repo, effect);
  });

  test('retains malformed-state rejection for all four state lists', () {
    final state = _snapshot([], []);
    final effect = _effect(state, state);
    const malformed = [
      'invalid JSON',
      '{}',
      'null',
      '[null]',
      '[1]',
      '[[{}]]',
      '[ {} ]',
      '[{"value":1,"name":"x"}]',
      '[{"name":"x","value":{"z":1,"a":2}}]',
      r'[{"name":"\u732b"}]',
      '[{"name":"x","value":1e0}]',
    ];
    for (final field in [
      'beforeLedgerJson',
      'beforeKnowledgeJson',
      'afterLedgerJson',
      'afterKnowledgeJson',
    ]) {
      for (final text in malformed) {
        _expectEquivalent(
          repo,
          _change(effect, {field: text}),
          reason: 'effect contains malformed state',
        );
      }
    }
  });

  test('preserves missing, foreign and integrity failure reasons', () {
    final state = _snapshot([
      {'name': 'trust', 'value': 1},
      {'value': 'ignored by diff, included in state hash'},
    ], []);
    final effect = _effect(state, state);
    _expectEquivalent(repo, null, reason: 'exact effect is unavailable');
    for (final field in ['sessionId', 'runId']) {
      _expectEquivalent(
        repo,
        _change(effect, {field: 'foreign', 'beforeLedgerJson': 'bad JSON'}),
        reason: 'effect does not belong to the reconciliation run',
      );
    }
    final prettyEffects = const JsonEncoder.withIndent(
      ' ',
    ).convert(_emptyEffects);
    final alteredState = _snapshot([
      {'name': 'trust', 'value': 1},
      {'value': 'still ignored by diff, but tampered'},
    ], []);
    final wrongEffects = _legacyCanonicalJson({
      ..._emptyEffects,
      'ledger': {
        'added': [
          {'name': 'spurious'},
        ],
        'changed': <Map<String, dynamic>>[],
        'removed': <Map<String, dynamic>>[],
      },
    });
    for (final changes in <Map<String, dynamic>>[
      {'beforeStateHash': 'tampered'},
      {'afterStateHash': 'tampered'},
      {'effectsHash': 'tampered'},
      {'actualEffectsJson': 'invalid JSON'},
      {'actualEffectsJson': '{}', 'effectsHash': computeHash('{}')},
      {
        'actualEffectsJson': prettyEffects,
        'effectsHash': computeHash(prettyEffects),
      },
      {
        'actualEffectsJson': wrongEffects,
        'effectsHash': computeHash(wrongEffects),
      },
      {'beforeLedgerJson': alteredState.ledgerJson},
      {'afterLedgerJson': alteredState.ledgerJson},
      {'beforeKnowledgeJson': '[{"text":"ignored identity"}]'},
      {'afterKnowledgeJson': '[{"text":"ignored identity"}]'},
    ]) {
      _expectEquivalent(
        repo,
        _change(effect, changes),
        reason: 'effect integrity hashes do not match its state',
      );
    }
  });

  test('public snapshot hash still canonicalizes noncanonical JSON inputs', () {
    const snapshots = [
      ReconciliationStateSnapshot(
        ledgerJson: '[ {"value":{"z":1e0,"a":null},"name":"x"} ]',
        knowledgeJson: r'[ {"text":"\u732b\ud83d\ude00","id":"fact"} ]',
      ),
      // The public constructor is not restricted to validated row lists.
      ReconciliationStateSnapshot(
        ledgerJson: ' {"z":false,"a":[1,1.0]} ',
        knowledgeJson: ' null ',
      ),
    ];
    for (final snapshot in snapshots) {
      expect(snapshot.hash, _legacyStateHash(snapshot));
      expect(
        snapshot.hash,
        ReconciliationStateSnapshot(
          ledgerJson: _legacyCanonicalJson(jsonDecode(snapshot.ledgerJson)),
          knowledgeJson: _legacyCanonicalJson(
            jsonDecode(snapshot.knowledgeJson),
          ),
        ).hash,
      );
    }
    expect(
      () => const ReconciliationStateSnapshot(
        ledgerJson: 'invalid JSON',
        knowledgeJson: '[]',
      ).hash,
      throwsFormatException,
    );
  });
}

const _run = LedgerReconciliationSuccessfulRunRow(
  id: 'run',
  sessionId: 'session',
  ordinal: 1,
  startMessageId: 'message',
  startSwipeId: 0,
  startAgentSwipeId: 0,
  endMessageId: 'message',
  endSwipeId: 0,
  endAgentSwipeId: 0,
  anchorsJson: '[]',
  rangeHash: '',
  acceptedManifestRefsJson: '[]',
  effectiveCanonStamp: '',
  effectiveCanonRevision: 0,
  effectiveCanonHash: '',
  canonicalResultJson: '{}',
  contentHash: '',
  predecessorChainHash: '',
  chainHash: '',
  contractVersion: 1,
  opsAppliedJson: '[]',
  createdAt: 1,
);

const _emptyEffects = {
  'ledger': {
    'added': <Map<String, dynamic>>[],
    'changed': <Map<String, dynamic>>[],
    'removed': <Map<String, dynamic>>[],
  },
  'knowledge': {
    'added': <Map<String, dynamic>>[],
    'changed': <Map<String, dynamic>>[],
    'removed': <Map<String, dynamic>>[],
  },
};

ReconciliationStateSnapshot _snapshot(
  List<dynamic> ledger,
  List<dynamic> facts,
) => ReconciliationStateSnapshot(
  ledgerJson: _legacyCanonicalJson(ledger),
  knowledgeJson: _legacyCanonicalJson(facts),
);

LedgerReconciliationEffectRow _effect(
  ReconciliationStateSnapshot before,
  ReconciliationStateSnapshot after,
) {
  final effects = _legacyExpectedEffects(before, after);
  return LedgerReconciliationEffectRow(
    runId: _run.id,
    sessionId: _run.sessionId,
    beforeLedgerJson: before.ledgerJson,
    afterLedgerJson: after.ledgerJson,
    beforeKnowledgeJson: before.knowledgeJson,
    afterKnowledgeJson: after.knowledgeJson,
    actualEffectsJson: effects,
    beforeStateHash: _legacyStateHash(before),
    afterStateHash: _legacyStateHash(after),
    effectsHash: computeHash(effects),
    createdAt: 1,
  );
}

LedgerReconciliationEffectRow _change(
  LedgerReconciliationEffectRow effect,
  Map<String, dynamic> changes,
) => LedgerReconciliationEffectRow.fromJson({...effect.toJson(), ...changes});

void _expectEquivalent(
  LedgerReconciliationRunRepo repo,
  LedgerReconciliationEffectRow? effect, {
  String? reason,
}) {
  final legacy = _legacyValidate(_run, effect);
  final actual = repo.validateEffectRow(_run, effect);
  expect(actual.runtimeType, legacy.runtimeType, reason: '$effect');
  if (reason != null) {
    expect(legacy, isA<ReconciliationEffectInvalid>());
    expect((legacy as ReconciliationEffectInvalid).reason, reason);
    expect((actual as ReconciliationEffectInvalid).reason, reason);
    return;
  }
  expect(legacy, isA<ReconciliationEffectValid>());
  final expected = legacy as ReconciliationEffectValid;
  final valid = actual as ReconciliationEffectValid;
  for (final (snapshot, original) in [
    (valid.before, expected.before),
    (valid.after, expected.after),
  ]) {
    expect(snapshot.ledgerJson, original.ledgerJson);
    expect(snapshot.knowledgeJson, original.knowledgeJson);
    expect(snapshot.hash, _legacyStateHash(original));
    expect(
      snapshot.hash,
      ReconciliationStateSnapshot(
        ledgerJson: original.ledgerJson,
        knowledgeJson: original.knowledgeJson,
      ).hash,
    );
  }
  expect(valid.before.ledgerJson, effect!.beforeLedgerJson);
  expect(valid.before.knowledgeJson, effect.beforeKnowledgeJson);
  expect(valid.after.ledgerJson, effect.afterLedgerJson);
  expect(valid.after.knowledgeJson, effect.afterKnowledgeJson);
  expect(valid.before.hash, effect.beforeStateHash);
  expect(valid.after.hash, effect.afterStateHash);
}

// Frozen pre-optimization oracle. Keep canonicalization, diffing and hash framing
// independent of production helpers so matching regressions cannot pass together.
ReconciliationEffectValidation _legacyValidate(
  LedgerReconciliationSuccessfulRunRow run,
  LedgerReconciliationEffectRow? effect,
) {
  if (effect == null) {
    return const ReconciliationEffectInvalid('exact effect is unavailable');
  }
  if (effect.sessionId != run.sessionId || effect.runId != run.id) {
    return const ReconciliationEffectInvalid(
      'effect does not belong to the reconciliation run',
    );
  }
  try {
    final before = ReconciliationStateSnapshot(
      ledgerJson: _legacyValidateRowList(effect.beforeLedgerJson),
      knowledgeJson: _legacyValidateRowList(effect.beforeKnowledgeJson),
    );
    final after = ReconciliationStateSnapshot(
      ledgerJson: _legacyValidateRowList(effect.afterLedgerJson),
      knowledgeJson: _legacyValidateRowList(effect.afterKnowledgeJson),
    );
    final expectedEffects = _legacyExpectedEffects(before, after);
    if (_legacyStateHash(before) != effect.beforeStateHash ||
        _legacyStateHash(after) != effect.afterStateHash ||
        effect.actualEffectsJson != expectedEffects ||
        effect.effectsHash != computeHash(expectedEffects)) {
      return const ReconciliationEffectInvalid(
        'effect integrity hashes do not match its state',
      );
    }
    return ReconciliationEffectValid(before: before, after: after);
  } catch (_) {
    return const ReconciliationEffectInvalid('effect contains malformed state');
  }
}

String _legacyStateHash(ReconciliationStateSnapshot state) => computeHash(
  _legacyCanonicalJson({
    'ledger': jsonDecode(state.ledgerJson),
    'knowledge': jsonDecode(state.knowledgeJson),
  }),
);

String _legacyExpectedEffects(
  ReconciliationStateSnapshot before,
  ReconciliationStateSnapshot after,
) => _legacyCanonicalJson({
  'ledger': _legacyDiffRows(
    jsonDecode(before.ledgerJson) as List,
    jsonDecode(after.ledgerJson) as List,
    identityKey: 'name',
  ),
  'knowledge': _legacyDiffRows(
    jsonDecode(before.knowledgeJson) as List,
    jsonDecode(after.knowledgeJson) as List,
    identityKey: 'id',
  ),
});

Map<String, dynamic> _legacyDiffRows(
  List<dynamic> before,
  List<dynamic> after, {
  required String identityKey,
}) {
  Map<String, Map<String, dynamic>> index(List<dynamic> rows) => {
    for (final row in rows.whereType<Map<Object?, Object?>>())
      if (row[identityKey] is String)
        row[identityKey] as String: Map<String, dynamic>.from(row),
  };
  final beforeById = index(before);
  final afterById = index(after);
  final ids = {...beforeById.keys, ...afterById.keys}.toList()..sort();
  final added = <Map<String, dynamic>>[];
  final removed = <Map<String, dynamic>>[];
  final changed = <Map<String, dynamic>>[];
  for (final id in ids) {
    final oldValue = beforeById[id];
    final newValue = afterById[id];
    if (oldValue == null) {
      added.add(newValue!);
    } else if (newValue == null) {
      removed.add(oldValue);
    } else if (_legacyCanonicalJson(oldValue) !=
        _legacyCanonicalJson(newValue)) {
      changed.add({'before': oldValue, 'after': newValue});
    }
  }
  return {'added': added, 'removed': removed, 'changed': changed};
}

String _legacyValidateRowList(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List ||
      decoded.any((row) => row is! Map<Object?, Object?>) ||
      !_legacyIsJsonValue(decoded)) {
    throw const FormatException('Expected a JSON row list');
  }
  final canonical = _legacyCanonicalJson(decoded);
  if (canonical != text) {
    throw const FormatException('State snapshot is not canonical');
  }
  return canonical;
}

String _legacyCanonicalJson(Object? value) =>
    jsonEncode(_legacyCanonical(value));

Object? _legacyCanonical(Object? value) {
  if (value is Map<Object?, Object?>) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _legacyCanonical(value[key])};
  }
  if (value is List) return value.map(_legacyCanonical).toList();
  if (!_legacyIsJsonValue(value)) throw const FormatException('non-JSON value');
  return value;
}

bool _legacyIsJsonValue(Object? value) =>
    value == null ||
    value is String ||
    value is num ||
    value is bool ||
    value is List && value.every(_legacyIsJsonValue) ||
    value is Map &&
        value.keys.every((key) => key is String) &&
        value.values.every(_legacyIsJsonValue);
