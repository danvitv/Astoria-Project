import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/application/sync_reconciliation_source.dart';

/// Private replayable snapshot. Disk carries history; memory carries one row.
class ReconciliationStaging implements ReconciliationStateSource {
  ReconciliationStaging._(this.directory, this.sessionId, this.schemaVersion);

  static const maxStagingBytes = ReconciliationJsonCodec.maxSnapshotBytes;
  static const maxRows = ReconciliationJsonCodec.maxRows;

  final Directory directory;
  @override
  final String sessionId;
  @override
  final int schemaVersion;
  final counts = <ReconciliationSection, int>{};
  late final ReconciliationFingerprint fingerprint;

  static Future<ReconciliationStaging> create(
    String sessionId,
    int schemaVersion, {
    Directory? temporaryRoot,
  }) async => ReconciliationStaging._(
    await (temporaryRoot ?? Directory.systemTemp).createTemp('astoria-sync-'),
    sessionId,
    schemaVersion,
  );

  static Future<ReconciliationStaging> capture(
    ReconciliationStateSource source, {
    Directory? temporaryRoot,
  }) async {
    final staging = await create(
      source.sessionId,
      source.schemaVersion,
      temporaryRoot: temporaryRoot,
    );
    final files = <ReconciliationSection, _BufferedStagingFile>{};
    var stagedBytes = 0;
    var rows = 0;
    try {
      for (final section in ReconciliationSection.values) {
        files[section] = _BufferedStagingFile(
          await staging.file(section).open(mode: FileMode.write),
        );
        staging.counts[section] = 0;
      }
      staging.fingerprint = await ReconciliationJsonCodec.fingerprint(
        source,
        onRow: (section, bytes) async {
          stagedBytes += bytes.length + 1;
          if (stagedBytes > maxStagingBytes || ++rows > maxRows) {
            throw const FormatException(
              'Reconciliation staging exceeds budget',
            );
          }
          if (section == ReconciliationSection.runs &&
              staging.counts[section]! >= ReconciliationJsonCodec.maxRunRows) {
            throw const FormatException('Too many reconciliation runs');
          }
          await files[section]!.writeRow(bytes);
          staging.counts[section] = staging.counts[section]! + 1;
        },
      );
      for (final file in files.values) {
        await file.flush();
      }
      return staging;
    } catch (_) {
      for (final file in files.values) {
        await file.close();
      }
      files.clear();
      await staging.dispose();
      rethrow;
    } finally {
      for (final file in files.values) {
        await file.close();
      }
    }
  }

  File file(ReconciliationSection section) =>
      File('${directory.path}${Platform.pathSeparator}${section.name}.jsonl');

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file(section).openRead()) {
      var start = 0;
      for (var index = 0; index < chunk.length; index++) {
        if (chunk[index] != 10) continue;
        _append(bytes, chunk, start, index);
        final row = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (row is! Map<String, dynamic>) {
          throw const FormatException('Reconciliation row is not an object');
        }
        yield row;
        start = index + 1;
      }
      _append(bytes, chunk, start, chunk.length);
    }
    if (bytes.isNotEmpty) {
      throw const FormatException('Truncated reconciliation staging record');
    }
  }

  static void _append(BytesBuilder out, List<int> chunk, int start, int end) {
    if (end - start > ReconciliationJsonCodec.maxRecordBytes - out.length) {
      throw const FormatException(
        'Reconciliation record exceeds memory budget',
      );
    }
    if (end > start) out.add(chunk.sublist(start, end));
  }

  Future<void> verifyFingerprint(String hash, int jsonBytes) async {
    fingerprint = await ReconciliationJsonCodec.fingerprint(this);
    if (fingerprint.hash != hash || fingerprint.jsonBytes != jsonBytes) {
      throw const FormatException(
        'Reconciliation snapshot fingerprint mismatch',
      );
    }
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

/// Batch small rows instead of issuing two native file writes per record.
/// Large records bypass the buffer; each section buffers at most 64 KiB.
class _BufferedStagingFile {
  _BufferedStagingFile(this.file);

  static const _bufferBytes = 64 * 1024;
  final RandomAccessFile file;
  final _pending = BytesBuilder(copy: false);

  Future<void> writeRow(List<int> bytes) async {
    if (bytes.length >= _bufferBytes) {
      await flush();
      await file.writeFrom(bytes);
      await file.writeByte(10);
      return;
    }
    if (_pending.length + bytes.length + 1 > _bufferBytes) await flush();
    _pending.add(bytes);
    _pending.add(const [10]);
  }

  Future<void> flush() async {
    if (_pending.isNotEmpty) await file.writeFrom(_pending.takeBytes());
  }

  Future<void> close() => file.close();
}
