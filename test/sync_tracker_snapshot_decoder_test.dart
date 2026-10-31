import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_tracker_snapshot_decoder.dart';

void main() {
  const source = TrackerSnapshot(
    sessionId: 'branch',
    messageId: 'retained',
    swipeId: 2,
    agentSwipeId: 3,
    committed: true,
    createdAt: 42,
    trackers: [
      Tracker(
        sessionId: 'parent',
        name: 'npc:someone.attitude',
        value: 'unchanged',
        scope: 'ledger',
        provenance: 'retained',
        updatedAt: 40,
        basisRevisionNumber: 7,
        basisRevisionHash: 'old-canon',
      ),
    ],
  );

  Map<String, dynamic> json() =>
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;

  test(
    'only redundant nested owners change, original wire input is untouched',
    () {
      final raw = json();
      final before = jsonEncode(raw);
      final decoded = SyncTrackerSnapshotDecoder.decode('branch', [raw]);
      final expected = source.copyWith(
        trackers: [source.trackers.single.copyWith(sessionId: 'branch')],
      );
      expect(decoded.snapshots.single, expected);
      expect(TrackerSnapshot.fromJson(decoded.items.single), expected);
      expect(jsonEncode(raw), before);
    },
  );

  test(
    'correct owner and extra compatibility fields are preserved exactly',
    () {
      final raw = json();
      ((raw['trackers'] as List).single as Map)['sessionId'] = 'branch';
      raw['legacyMarker'] = 'keep';
      final before = jsonEncode(raw);
      expect(
        jsonEncode(
          SyncTrackerSnapshotDecoder.decode('branch', [raw]).items.single,
        ),
        before,
      );
    },
  );

  test('outer owner is never rebound to the requested session', () {
    expect(
      () => SyncTrackerSnapshotDecoder.decode('another', [json()]),
      throwsFormatException,
    );
  });

  test('malformed later tracker cannot be hidden by owner normalization', () {
    final malformed = json();
    (malformed['trackers'] as List).add({'sessionId': 'parent'});
    expect(
      () => SyncTrackerSnapshotDecoder.decode('branch', [json(), malformed]),
      throwsA(isA<TypeError>()),
    );
  });
}
