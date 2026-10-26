import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/native_history/history_json_framer.dart';
import 'package:glaze_flutter/core/db/native_history/history_message_unit.dart';

import 'helpers/source_navigation_cleanroom_cases.dart' as cleanroom;

void main() {
  test('independent cleanroom source navigation contract', () async {
    // Keep the executor's throwing assertions, including every positive body
    // scenario. This registers its SDK-only runner in the project test suite.
    await cleanroom.main();
  });
  test(
    'stream framing preserves whitespace/escapes/Unicode complete original units',
    () {
      const raw =
          '[ \n {"id":"a","role":"user","content":"😀 } [ \\"x\\""}, '
          '{"id":"b","role":"assistant","content":"tail","unknown":{"authored key":"kept"}} ] \t';
      final bytes = utf8.encode(raw);
      for (final size in [1, 2, 3, 7, 8192]) {
        final framer = HistoryJsonFramer(), units = <String>[];
        for (var offset = 0; offset < bytes.length; offset += size) {
          framer.add(
            bytes.sublist(offset, (offset + size).clamp(0, bytes.length)),
            units.add,
          );
        }
        framer.finish();
        expect(units, hasLength(2));
        expect(HistoryMessageUnit(units.first).content, '😀 } [ "x"');
        expect(HistoryMessageUnit(units.last).object['unknown'], {
          'authored key': 'kept',
        });
        expect(framer.offset, bytes.length);
        expect(raw, contains(units.first));
        expect(raw, contains(units.last));
      }
    },
  );
  test('malformed/truncated/trailing framing is never complete history', () {
    for (final raw in ['', '[', '[{},]', '[{}]x', '[[{}]]', '[{} {}]']) {
      final framer = HistoryJsonFramer();
      expect(
        () => {framer.add(utf8.encode(raw), (_) {}), framer.finish()},
        throwsFormatException,
        reason: raw,
      );
    }
  });
  test(
    'oversized valid complete unit is refused rather than split or omitted',
    () {
      final raw = jsonEncode([
        {'id': 'huge', 'role': 'user', 'content': 'x' * 65536},
      ]);
      final framer = HistoryJsonFramer();
      expect(() => framer.add(utf8.encode(raw), (_) {}), throwsFormatException);
      expect(framer.complete, isFalse);
    },
  );
  test(
    'strict unit rejects duplicate keys, malformed Unicode and inactive disagreement',
    () {
      for (final raw in [
        r'{"id":"a","id":"b","role":"user","content":"x"}',
        r'{"id":"a","role":"user","content":"\ud800"}',
        r'{"id":"a","role":"assistant","content":"x","swipes":["other"],"swipeId":0}',
      ]) {
        expect(() => HistoryMessageUnit(raw), throwsFormatException);
      }
      expect(
        HistoryMessageUnit(
          '{"id":"a","role":"user","content":"x","isHidden":true}',
        ).eligible,
        isFalse,
      );
    },
  );
}
