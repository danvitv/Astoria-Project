import '../../../core/models/tracker_snapshot.dart';

/// Legacy branches copied nested Tracker.sessionId labels verbatim. The outer
/// snapshot owns its embedded values; those labels must not redirect an import.
/// Validate the outer owner and every row before normalizing ONLY nested labels.
abstract final class SyncTrackerSnapshotDecoder {
  static ({List<TrackerSnapshot> snapshots, List<Map<String, dynamic>> items})
  decode(String sessionId, List<Map<String, dynamic>> items) {
    if (items.any((item) => item['sessionId'] != sessionId)) {
      throw const FormatException('Tracker snapshot belongs to another chat');
    }
    // Decode the whole original payload first: compatibility must not hide a
    // malformed later record or strip any values, provenance or canon stamps.
    final decoded = items.map(TrackerSnapshot.fromJson).toList();
    return (
      snapshots: [
        for (final snapshot in decoded)
          snapshot.copyWith(
            trackers: [
              for (final tracker in snapshot.trackers)
                tracker.copyWith(sessionId: sessionId),
            ],
          ),
      ],
      items: [
        for (final item in items)
          {
            ...item,
            if (item['trackers'] is List)
              'trackers': [
                for (final tracker in item['trackers'] as List)
                  {...tracker as Map<String, dynamic>, 'sessionId': sessionId},
              ],
          },
      ],
    );
  }
}
