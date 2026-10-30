import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_repo_interfaces.dart';

enum ReconciliationSection {
  runs,
  effects,
  invalidations,
  manifests,
  manifestEntries,
  acceptances,
  collectors,
  observations,
  completedClaims,
}

/// Replayable section rows. No caller needs the whole journal in memory.
abstract interface class ReconciliationStateSource {
  String get sessionId;
  int get schemaVersion;
  Stream<Map<String, dynamic>> readSection(ReconciliationSection section);
}

/// Optional ownership check, also enforced immediately before a DB commit.
abstract interface class ReconciliationSourceGuard {
  void checkCurrent();
}

class ReconciliationFingerprint {
  const ReconciliationFingerprint({
    required this.hash,
    required this.jsonBytes,
  });

  final String hash;
  final int jsonBytes;
}

/// Optional scalable capability; legacy implementations retain their map API.
abstract interface class SyncPagedReconciliationStateStore
    implements SyncReconciliationStateStore {
  Future<bool> hasBySessionId(String sessionId);
  Future<ReconciliationFingerprint?> fingerprintBySessionId(String sessionId);

  /// Holds the DB snapshot only during [consume], which must materialize local
  /// staging or fingerprint rows. Never issue cloud requests from this callback.
  Future<T?> withExportSnapshot<T>(
    String sessionId,
    Future<T> Function(ReconciliationStateSource source) consume,
  );

  /// Replays a fully downloaded, verified local source in one DB transaction.
  /// In particular, normalization/merge decisions must not restart per page.
  Future<void> mergeFromSource(
    String sessionId,
    ReconciliationStateSource source,
  );
}

class ReconciliationJsonCodec {
  // These bounds limit the working record/metadata sets, not physical files.
  static const maxRecordBytes = 32 * 1024 * 1024;
  static const maxRunRows = 10000;
  static const maxMetadataBytes = 64 * 1024 * 1024;
  static const maxSnapshotBytes = 8 * 1024 * 1024 * 1024;
  static const maxRows = 500000;

  /// Exactly the existing schema-1/2 map encoding, including key/array order.
  static Stream<List<int>> encode(
    ReconciliationStateSource source, {
    Future<void> Function(ReconciliationSection, List<int>)? onRow,
  }) async* {
    final header = jsonEncode({
      '__reconciliationState': true,
      'schemaVersion': source.schemaVersion,
      'sessionId': source.sessionId,
    });
    yield utf8.encode(header.substring(0, header.length - 1));
    var metadataBytes = 0;
    var runRows = 0;
    var rows = 0;
    for (final section in ReconciliationSection.values) {
      yield utf8.encode(',"${section.name}":[');
      var first = true;
      await for (final row in source.readSection(section)) {
        if (++rows > maxRows) {
          throw const FormatException('Too many reconciliation records');
        }
        if (!first) yield const [44];
        final bytes = encodeRow(row);
        if (section == ReconciliationSection.runs ||
            section == ReconciliationSection.invalidations ||
            section == ReconciliationSection.collectors) {
          metadataBytes += bytes.length;
          if (metadataBytes > maxMetadataBytes ||
              (section == ReconciliationSection.runs &&
                  ++runRows > maxRunRows)) {
            throw const FormatException(
              'Reconciliation metadata exceeds budget',
            );
          }
        }
        await onRow?.call(section, bytes);
        yield bytes;
        first = false;
      }
      yield const [93];
    }
    yield const [125];
  }

  static List<int> encodeRow(Map<String, dynamic> row) {
    final bytes = utf8.encode(jsonEncode(row));
    if (bytes.length > maxRecordBytes) {
      throw const FormatException(
        'Reconciliation record exceeds memory budget',
      );
    }
    return bytes;
  }

  static Future<ReconciliationFingerprint> fingerprint(
    ReconciliationStateSource source, {
    Future<void> Function(ReconciliationSection, List<int>)? onRow,
  }) async {
    final result = _DigestSink();
    final hash = sha256.startChunkedConversion(result);
    var bytes = 0;
    await for (final chunk in encode(source, onRow: onRow)) {
      bytes += chunk.length;
      if (bytes > maxSnapshotBytes) {
        throw const FormatException(
          'Reconciliation snapshot exceeds disk budget',
        );
      }
      hash.add(chunk);
    }
    hash.close();
    return ReconciliationFingerprint(hash: result.value!, jsonBytes: bytes);
  }
}

class MapReconciliationStateSource implements ReconciliationStateSource {
  const MapReconciliationStateSource(this.data);
  final Map<String, dynamic> data;

  @override
  String get sessionId => data['sessionId'] as String;

  @override
  int get schemaVersion => data['schemaVersion'] as int;

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    final rows = data[section.name] as List? ?? const [];
    for (final row in rows) {
      yield Map<String, dynamic>.from(row as Map);
    }
  }
}

class _DigestSink implements Sink<Digest> {
  String? value;
  @override
  void add(Digest digest) => value = digest.toString();
  @override
  void close() {}
}
