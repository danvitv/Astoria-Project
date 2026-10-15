import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/gallery_entry.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_comparator.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_download.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_schema.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

const canary = 'SECRET_CANARY';

class _UnknownObject {
  const _UnknownObject();
  @override
  String toString() => throw StateError('Unknown toString forbidden');
  @override
  int get hashCode => throw StateError('Unknown hash forbidden');
  @override
  bool operator ==(Object other) =>
      throw StateError('Unknown equality forbidden');
  Map<String, dynamic> toJson() => throw StateError('Unknown JSON forbidden');
}

SyncConflict conflict(String type, [int n = 1]) {
  final entry = SyncManifestEntry(
    type: type,
    id: '${canary}_$n',
    path: '/$canary/arbitrary',
    updatedAt: 1700000000,
    hash: canary,
  );
  return SyncConflict(
    key: canary,
    type: type,
    id: entry.id,
    localEntry: entry.copyWith(updatedAt: 1700000000000),
    cloudEntry: entry,
    name: canary,
  );
}

Map<String, dynamic> world(String type) => switch (type) {
  'character' => {
    'id': canary,
    'name': canary,
    'currentSessionIndex': 0,
    'extensions': <String, dynamic>{canary: canary},
  },
  'character_knowledge' => {
    '__characterKnowledge': true,
    'sessionId': canary,
    'facts': [
      {'id': canary, 'lifecycle': 'active', 'basisRevision': 1},
    ],
    'baseline': {
      'baselineCardJson': canary,
      'cardUpdatePolicy': 'follow_source',
    },
  },
  _ => {
    '__memoryGraph': true,
    'sessionId': canary,
    'catalog': <Object?>[],
    'entities': [
      {'id': canary, 'description': canary},
    ],
    'salience': <Object?>[],
    'cadence': <Object?>[],
    'consolidation': <Object?>[],
  },
};

void main() {
  const comparator = SyncConflictDiagnosticComparator();
  test('raw map order and numeric representation yield only safe evidence', () {
    final a = {'id': canary, 'name': canary, 'tokenCount': 1};
    final b = {'tokenCount': 1.0, 'name': canary, 'id': canary};
    expect(jsonEncode(a), isNot(jsonEncode(b)));
    final result = comparator.inspect('character', a, b);
    expect(result.limited, isFalse);
    expect(result.paths.map((p) => p.toString()), contains(r'$: order'));
    expect(
      result.paths.map((p) => p.toString()),
      contains('tokenCount: shape (local-only metadata)'),
    );
    expect(result.paths.join(), isNot(contains(canary)));
    final parent = comparator.inspect(
      'character_knowledge',
      {
        'baseline': {'baselineHash': canary, 'updatedAt': 1},
      },
      {
        'baseline': {'updatedAt': 1, 'baselineHash': canary},
      },
    );
    expect(parent.paths.single.toString(), 'baseline: order');
    final scalar = comparator.inspect(
      'character',
      {'tokenCount': 1},
      {'tokenCount': 1.0},
    );
    expect(scalar.paths.single.difference, SyncDiagnosticDifference.shape);
    final opaque = comparator.inspect(
      'character',
      {
        'extensions': {canary: 1, '${canary}_2': 2},
      },
      {
        'extensions': {'${canary}_2': 2, canary: 1.0},
      },
    );
    expect(opaque.paths.single.toString(), 'extensions.*: value');
    expect(opaque.paths.join(), isNot(contains(canary)));
  });
  test('unknown objects are limited without serializers or hashes', () async {
    final report = await SyncConflictDiagnostics(
      readLocal: (_, _) async => {
        'id': canary,
        'name': canary,
        'extensions': {'safe': const _UnknownObject()},
      },
      download: (_) async => jsonEncode(world('character')),
    ).diagnose([conflict('character')]);
    expect(report.items.single.status, SyncDiagnosticStatus.inspectionLimited);
    expect(report.toSafeText(), isNot(contains(canary)));
  });
  test(
    'equal payload has no paths; fixed missing/auth/local failure statuses',
    () async {
      expect(
        comparator
            .inspect('character', world('character'), world('character'))
            .equal,
        isTrue,
      );
      for (final failure in <(Object, SyncDiagnosticStatus)>[
        (
          const CloudFileNotFoundException(canary),
          SyncDiagnosticStatus.cloudMissing,
        ),
        (
          const SyncDiagnosticAuthUnavailable(),
          SyncDiagnosticStatus.authUnavailable,
        ),
      ]) {
        final report = await SyncConflictDiagnostics(
          readLocal: (_, _) async => world('character'),
          download: (_) => throw failure.$1,
        ).diagnose([conflict('character')]);
        expect(report.items.single.status, failure.$2);
        expect(report.toSafeText(), isNot(contains(canary)));
      }
      final failed = await SyncConflictDiagnostics(
        readLocal: (_, _) => throw StateError(canary),
        download: (_) => throw StateError(canary),
      ).diagnose([conflict('character')]);
      expect(failed.items.single.status, SyncDiagnosticStatus.localReadFailed);
      final invalid = conflict('character');
      final badId = SyncConflict(
        key: canary,
        type: invalid.type,
        id: '../secret',
        localEntry: invalid.localEntry,
        cloudEntry: invalid.cloudEntry,
        name: canary,
      );
      final rejected = await SyncConflictDiagnostics(
        readLocal: (_, _) => throw StateError(canary),
        download: (_) => throw StateError(canary),
      ).diagnose([badId]);
      expect(
        rejected.items.single.status,
        SyncDiagnosticStatus.invalidIdentity,
      );
    },
  );
  test(
    'representative 12+16+1 mix yields values-free static schema paths',
    () async {
      final conflicts = [
        for (var i = 0; i < 12; i++) conflict('character', i),
        for (var i = 0; i < 16; i++) conflict('character_knowledge', i),
        conflict('memory_graph'),
      ];
      final downloads = <String>[];
      final report = await SyncConflictDiagnostics(
        readLocal: (type, _) async => world(type),
        download: (path) async {
          downloads.add(path);
          final type = path.contains('/characters/')
              ? 'character'
              : path.contains('/character_knowledge/')
              ? 'character_knowledge'
              : 'memory_graph';
          final data = world(type);
          if (type == 'character') data['currentSessionIndex'] = 3;
          if (type == 'character_knowledge') {
            (data['facts'] as List).first['lifecycle'] = 'retracted';
          }
          if (type == 'memory_graph') {
            (data['entities'] as List).first['description'] = 'different';
          }
          return jsonEncode(data);
        },
      ).diagnose(conflicts);
      expect(report.items.length, 29);
      expect(
        report.items.every((i) => i.status == SyncDiagnosticStatus.compared),
        isTrue,
      );
      expect(report.toSafeText(), isNot(contains(canary)));
      expect(report.toString(), report.toSafeText());
      expect(downloads, conflicts.map((c) => cloudPath(c.type, c.id)).toList());
      expect(report.items.first.paths.first.localOnlyMetadata, isTrue);
      expect(
        report.items.first.localTimestampUnit,
        SyncDiagnosticTimestampUnit.millisecondsLikely,
      );
      expect(
        report.items.first.cloudTimestampUnit,
        SyncDiagnosticTimestampUnit.secondsLikely,
      );
    },
  );

  test(
    'metadata, materialization, lifecycle, provenance and graph are retained',
    () {
      for (final field in [
        'currentSessionIndex',
        'tokenCount',
        'depthPrompt',
        'depthPromptDepth',
        'world',
        'displayName',
        'updatedAt',
        'avatarPath',
      ]) {
        final result = comparator.inspect(
          'character',
          {'id': canary, field: 0},
          {'id': canary, field: 1},
        );
        expect(result.paths.map((p) => p.path), contains(field));
      }
      for (final schema in diagnosticSchemas.entries.where(
        (s) => s.key.endsWith('[]') || s.key == 'baseline',
      )) {
        for (final field in schema.value) {
          final parent = schema.key.replaceAll('[]', '');
          final type = parent == 'gallery'
              ? 'character'
              : ['facts', 'baseline'].contains(parent)
              ? 'character_knowledge'
              : 'memory_graph';
          final stableKey = parent == 'cadence' ? 'chatSessionId' : 'id';
          final unordered = schema.key.endsWith('[]') && parent != 'gallery';
          final a = <String, dynamic>{
            parent: schema.key.endsWith('[]')
                ? [
                    {if (unordered) stableKey: canary, field: 0},
                  ]
                : {field: 0},
          };
          final b = <String, dynamic>{
            parent: schema.key.endsWith('[]')
                ? [
                    {if (unordered) stableKey: canary, field: 1},
                  ]
                : {field: 1},
          };
          expect(
            comparator.inspect(type, a, b).paths.map((p) => p.path),
            contains(
              unordered && field == stableKey
                  ? schema.key
                  : '${schema.key}.$field',
            ),
          );
        }
      }
    },
  );

  test(
    'gallery model is materialized explicitly; row ordering and size differ',
    () {
      const image = GalleryEntry(
        id: canary,
        characterId: canary,
        imagePath: canary,
      );
      expect(
        comparator
            .inspect(
              'character',
              {
                'gallery': [image],
              },
              {
                'gallery': [image.toJson()],
              },
            )
            .equal,
        isTrue,
      );
      final a = {
        'facts': [
          {'id': 'a', 'lifecycle': 'active'},
          {'id': 'b', 'lifecycle': 'retracted'},
        ],
      };
      final b = {'facts': (a['facts'] as List).reversed.toList()};
      expect(
        comparator
            .inspect('character_knowledge', a, b)
            .paths
            .any(
              (p) =>
                  p.path == 'facts[]' &&
                  p.difference == SyncDiagnosticDifference.order,
            ),
        isTrue,
      );
      expect(
        comparator
            .inspect('character_knowledge', a, {'facts': <Object?>[]})
            .paths
            .any((p) => p.difference == SyncDiagnosticDifference.size),
        isTrue,
      );
    },
  );

  test(
    'dynamic secret keys, values, recursive and unknown schema never escape',
    () {
      final recursive = <String, dynamic>{};
      recursive[canary] = recursive;
      final result = comparator.inspect(
        'character',
        {'extensions': recursive},
        {
          'extensions': {canary: canary},
        },
      );
      expect(result.paths.join(), isNot(contains(canary)));
      expect(result.paths.map((p) => p.path), contains('extensions.*'));
      expect(
        comparator.inspect('character', {canary: canary}, {}).equal,
        isFalse,
      );
      final deep = comparator.inspect(
        'character',
        {'extensions': recursive},
        {'extensions': recursive},
      );
      expect(deep.limited, isTrue);
      expect(deep.paths.length, lessThanOrEqualTo(128));
      expect(
        SyncDiagnosticPath(canary, SyncDiagnosticDifference.value).toString(),
        isNot(contains(canary)),
      );
    },
  );

  test('unsupported API never reads or downloads; item cap', () async {
    final report = await SyncConflictDiagnostics(
      readLocal: (_, _) => throw StateError(canary),
      download: (_) => throw StateError(canary),
    ).diagnose(List.generate(51, (_) => conflict(canary)));
    expect(report.items.length, 50);
    expect(report.truncated, isTrue);
    expect(
      report.items.every((i) => i.status == SyncDiagnosticStatus.unsupported),
      isTrue,
    );
    expect(report.toSafeText(), isNot(contains(canary)));
  });

  test(
    'malformed, oversized, root, missinglocal, Dio canary yield fixed statuses',
    () async {
      for (final pair in [
        ('{', SyncDiagnosticStatus.invalidJson),
        ('[]', SyncDiagnosticStatus.unknownRoot),
        ('{"arbitrary":1}', SyncDiagnosticStatus.unknownRoot),
        (
          'x' * (SyncConflictDiagnostics.maxPayloadBytes + 1),
          SyncDiagnosticStatus.oversized,
        ),
        (
          'é' * (SyncConflictDiagnostics.maxPayloadBytes ~/ 2 + 1),
          SyncDiagnosticStatus.oversized,
        ),
      ]) {
        final report = await SyncConflictDiagnostics(
          readLocal: (_, _) async => world('character'),
          download: (_) async => pair.$1,
        ).diagnose([conflict('character')]);
        expect(report.items.single.status, pair.$2);
      }
      final missing = await SyncConflictDiagnostics(
        readLocal: (_, _) async => null,
        download: (_) => throw StateError(canary),
      ).diagnose([conflict('character')]);
      expect(missing.items.single.status, SyncDiagnosticStatus.missingLocal);
      final failed = await SyncConflictDiagnostics(
        readLocal: (_, _) async => world('character'),
        download: (_) => throw DioException(
          requestOptions: RequestOptions(
            path: canary,
            headers: {'Authorization': canary},
          ),
          message: canary,
        ),
      ).diagnose([conflict('character')]);
      expect(failed.items.single.status, SyncDiagnosticStatus.cloudReadFailed);
      expect(failed.toSafeText(), isNot(contains(canary)));
    },
  );

  test(
    'local changes during cloud await do not mutate or imply equivalence',
    () async {
      final gate = Completer<String>();
      final local = world('character');
      final future = SyncConflictDiagnostics(
        readLocal: (_, _) async => local,
        download: (_) => gate.future,
      ).diagnose([conflict('character')]);
      await Future<void>.delayed(Duration.zero);
      local['currentSessionIndex'] = 99;
      gate.complete(jsonEncode(local));
      final report = await future;
      expect(
        report.items.single.status,
        SyncDiagnosticStatus.changedDuringRead,
      );
      expect(local['currentSessionIndex'], 99);
    },
  );
}
