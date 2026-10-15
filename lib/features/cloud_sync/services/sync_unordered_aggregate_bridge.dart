import 'dart:convert';

import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'sync_serialization.dart';
import 'sync_unordered_aggregate.dart';

/// Authenticates representation-only matches without importing domain rows.
class SyncUnorderedAggregateBridge {
  const SyncUnorderedAggregateBridge({
    required this.download,
    required this.readLocal,
    required this.isDeleted,
  });

  final Future<String> Function(String) download;
  final Future<Map<String, dynamic>?> Function(String, String) readLocal;
  final Future<bool> Function(String, String) isDeleted;

  static bool supports(String type) =>
      type == 'memory_graph' || type == 'character_knowledge';

  Future<SyncManifest> bridge(SyncManifest local, SyncManifest? cloud) async {
    if (cloud == null) return local;
    final entries = Map<String, SyncManifestEntry>.from(local.entries);
    final accepted = Map<String, String>.from(local.acceptedLocalHashes);
    for (final remote in cloud.entries.values) {
      final entry = entries[remote.key];
      if (!supports(remote.type) ||
          remote.deleted ||
          entry == null ||
          entry.deleted ||
          entry.hash == remote.hash) {
        continue;
      }
      final snapshot = await readLocal(remote.type, remote.id);
      final canonical = _canonical(snapshot, remote);
      if (canonical == null) continue;
      // Validation precedes raw hashing; the canonical budget also bounds the
      // compact raw encoding (permutations do not change its byte length).
      final rawHash = SyncSerialization.computeSyncHash(snapshot);
      if (rawHash != (accepted[remote.key] ?? entry.hash)) _changed();
      if (await isDeleted(remote.type, remote.id)) _changed();
      await _checkSnapshot(remote, rawHash);

      String raw;
      try {
        raw = await download(remote.path);
      } on CloudFileNotFoundException {
        throw StateError('Required aggregate cloud payload is missing');
      } catch (_) {
        throw StateError('Aggregate cloud payload download failed');
      }
      await _checkSnapshot(remote, rawHash);
      // The adapter has already allocated the string. Bound decoding and
      // account for whitespace/escaped wire representation independently.
      if (raw.length > SyncUnorderedAggregate.maxBytes ||
          utf8.encode(raw).length > SyncUnorderedAggregate.maxBytes) {
        continue;
      }
      Object? payload;
      try {
        payload = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      final remoteCanonical = _canonical(payload, remote);
      if (remoteCanonical == null) continue;
      if (SyncSerialization.computeSyncHash(payload) != remote.hash) {
        throw StateError('Aggregate cloud payload fingerprint mismatch');
      }
      if (canonical != remoteCanonical) continue;
      entries[remote.key] = remote;
      accepted[remote.key] = rawHash;
    }
    final result = local.copyWith(
      entries: entries,
      acceptedLocalHashes: accepted,
    );
    await verifyAnchors(result);
    return result;
  }

  /// Recheck all raw anchors before publication/finalization, including old
  /// explicit anchors. A reorder is drift too: the manifest builder hashes it.
  Future<void> verifyAnchors(SyncManifest manifest) async {
    for (final anchor in manifest.acceptedLocalHashes.entries) {
      final entry = manifest.entries[anchor.key];
      if (entry == null || !supports(entry.type) || entry.deleted) continue;
      await _checkSnapshot(entry, anchor.value);
    }
  }

  Future<void> _checkSnapshot(SyncManifestEntry entry, String expected) async {
    if (await isDeleted(entry.type, entry.id)) _changed();
    final current = await readLocal(entry.type, entry.id);
    if (_canonical(current, entry) == null ||
        SyncSerialization.computeSyncHash(current) != expected) {
      _changed();
    }
  }

  String? _canonical(Object? payload, SyncManifestEntry entry) =>
      SyncUnorderedAggregate.canonicalize(
        payload,
        type: entry.type,
        sessionId: entry.id,
      );

  Never _changed() =>
      throw StateError('Aggregate changed during sync equivalence; retry');
}
