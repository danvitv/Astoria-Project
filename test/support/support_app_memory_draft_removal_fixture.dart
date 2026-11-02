import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';

import 'support_app_memory_draft_text_fixture.dart';
export 'support_app_memory_draft_text_fixture.dart';

Map<String, Object?> draftRemovalArguments() => {
  'sessionId': DomainLoopFixture.session,
  'draftId': draftTextId,
};

Future<void> startDraftRemoval(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool confirmation = true,
  bool undo = false,
}) => f.start(
  tester,
  confirmation: confirmation,
  instruction: undo
      ? 'Отмени удаление черновика Memory'
      : 'Удали черновик Memory',
);

/// Reuse the original domain/model/SQL/FakeVault/tripwire fixture, no new harness.
/// The raw arrangement is deterministic so expected delimiter edits are not
/// calculated using the production scanner being tested.
String arrangeRemovalDrafts(String raw, String position) {
  final split = raw.indexOf('\n  },\n  {') + '\n  }'.length;
  final target = raw
      .substring(raw.indexOf('{'), split)
      .replaceFirst('"content":', r'"\u0063ontent":');
  final sibling = raw.substring(split + 1, raw.lastIndexOf(']')).trim();
  final other = sibling.replaceFirst('sibling-draft', 'other-sibling');
  return switch (position) {
    'sole' => '[ \n$target\t ]',
    'first' => '[ \n$target \t,\n$sibling\n ]',
    'middle' => '[ $sibling ,\n$target\t, $other\n]',
    _ => '[ $sibling ,\n$target\t ]',
  };
}

String expectedRemovedArray(String raw, String position) {
  final id = raw.indexOf('"id": "$draftTextId"');
  final objectStart = raw.lastIndexOf('{', id);
  // Target's final generatedAt precedes its unknown native fields. The marker
  // is unique in the fixture, independent of braces inside unknown nested JSON.
  final marker = raw.indexOf('"unknownNumber": 1.2300e+02', id);
  final objectEnd = raw.indexOf('\n  }', marker) + '\n  }'.length;
  if (position == 'first' || position == 'middle') {
    return raw.substring(0, objectStart) +
        raw.substring(raw.indexOf(',', objectEnd) + 1);
  }
  if (position == 'last') {
    return raw.substring(0, raw.lastIndexOf(',', objectStart)) +
        raw.substring(objectEnd);
  }
  return raw.substring(0, objectStart) + raw.substring(objectEnd);
}

void preservedRemovalRow(
  MemoryBookRow before,
  MemoryBookRow after,
  String raw,
) {
  expect(after, before.copyWith(pendingDraftsJson: raw));
  expect(jsonDecode(after.pendingDraftsJson), isA<List<Object?>>());
}

void scriptRemovalUndo(DomainLoopFixture f, {void Function(String)? handle}) =>
    f.script(
      f.screen.core.call('astoria_memory_draft_delete_receipts', {}),
      next: (round) {
        if (round != 2)
          return f.screen.core.answer('Exact native removal Undo settled.');
        final records = f.lastData()['records'] as List;
        expect(records, hasLength(1));
        final id = (records.single as Map)['receipt'] as String;
        handle?.call(id);
        return f.screen.core.call('astoria_memory_draft_delete_undo', {
          'receipt': id,
        }, id: 'fresh_genuine_removal_undo');
      },
    );
