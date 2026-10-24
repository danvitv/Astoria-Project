import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';

import 'synthetic_consent_selection_fixture.dart';

void main() {
  late SyntheticConsentSelectionFixture f;
  setUp(() {
    f = SyntheticConsentSelectionFixture();
  });
  tearDown(() => f.close());

  test(
    'synthetic visible sessions paginate exact identities, variants and safe labels only',
    () async {
      await f.character(
        'visible',
        name: 'Name ${SyntheticConsentSelectionFixture.secret}',
        variantName: 'Variant ${SyntheticConsentSelectionFixture.secret}',
      );
      await f.character('hidden', hidden: true);
      await f.character(
        'paths',
        name: SyntheticConsentSelectionFixture.pathCanary,
        variantName:
            'https://private.test/${SyntheticConsentSelectionFixture.bodyCanary}',
      );
      await f.roleplay(
        's1',
        'visible',
        jsonEncode([SyntheticConsentSelectionFixture.message('m1')]),
        index: 7,
        updatedAt: 10,
      );
      await f.roleplay('s2', 'paths', '[]', index: 4, updatedAt: 9);
      await f.roleplay('s3', 'orphan', '[]', index: 2, updatedAt: 8);
      await f.roleplay('s-hidden', 'hidden', '[]', updatedAt: 100);
      final before = await f.snapshot();
      f.observe();
      final first = await f.repo.listRoleplaySessions(limit: 2);
      expect(first.items.map((s) => s.sessionId), ['s1', 's2']);
      expect(first.status, SupportConsentSelectionStatus.limited);
      expect(first.nextOffset, 2);
      final s = first.items.first;
      expect(s.characterId, 'visible');
      expect(s.sessionIndex, 7);
      expect(s.variantGroupId, 'synthetic_group');
      expect(s.variantOrder, 2);
      expect(s.messageCount, 1);
      expect(s.status, SupportConsentSelectionStatus.available);
      expect(s.label, contains('Session 8'));
      expect(s.characterLabel, contains('[REDACTED]'));
      expect(first.items[1].characterLabel, 'Character');
      expect(first.items[1].variantLabel, 'Variant');
      final second = await f.repo.listRoleplaySessions(
        offset: first.nextOffset!,
        limit: 2,
      );
      expect(second.items.single.sessionId, 's3');
      expect(second.items.single.variantGroupId, isNull);
      expect(second.status, SupportConsentSelectionStatus.available);
      expect(second.nextOffset, isNull);
      _noCanaries(_sessionStrings([...first.items, ...second.items]));
      expect(() => first.items.clear(), throwsUnsupportedError);
      expect(f.storage.operations, isEmpty);
      _narrowRoleplayReads(f, sessions: true);
      await _preserved(f, before);
    },
  );

  test(
    'synthetic roleplay stored order, shared branch IDs, omissions and durable swipe metadata',
    () async {
      await f.character('c');
      final messages = [
        SyntheticConsentSelectionFixture.message(
          'shared',
          timestamp: 900,
          swipeId: 4,
          agentSwipeId: 3,
        ),
        SyntheticConsentSelectionFixture.message('hidden', hidden: true),
        SyntheticConsentSelectionFixture.message('error', error: true),
        SyntheticConsentSelectionFixture.message('typing', typing: true),
        SyntheticConsentSelectionFixture.message('dup'),
        SyntheticConsentSelectionFixture.message('dup'),
        SyntheticConsentSelectionFixture.message('unsupported', role: 'tool'),
        SyntheticConsentSelectionFixture.message(
          'user',
          role: 'user',
          timestamp: 2,
        ),
        SyntheticConsentSelectionFixture.message(
          'system',
          role: 'system',
          timestamp: null,
        ),
      ];
      await f.roleplay('selected', 'c', jsonEncode(messages));
      await f.roleplay(
        'sibling',
        'c',
        jsonEncode([
          SyntheticConsentSelectionFixture.message('shared', swipeId: 99),
        ]),
        index: 1,
      );
      final before = await f.snapshot();
      f.observe();
      final page = await f.repo.listRoleplayMessages(sessionId: 'selected');
      expect(page.items.map((m) => m.messageId), ['shared', 'user', 'system']);
      expect(page.items.map((m) => m.sessionId), everyElement('selected'));
      expect(page.items.map((m) => m.nativeOrder), [0, 7, 8]);
      expect(page.items.map((m) => m.timestampMs), [900, 2, null]);
      expect(page.items.first.swipeId, 4);
      expect(page.items.first.agentSwipeId, 3);
      expect(page.items[1].swipeId, isNull);
      expect(page.sourceCount, 9);
      expect(page.eligibleCount, 3);
      expect(page.omittedCount, 6);
      expect(page.limitedCount, 0);
      expect(page.bodiesRead, isFalse);
      expect(page.attachmentsIncluded, isFalse);
      _noCanaries(_messageStrings(page));
      _narrowRoleplayReads(f, target: 'selected');
      expect(f.storage.operations, isEmpty);
      await _preserved(f, before);
    },
  );

  test(
    'synthetic eligible message pagination is explicit, never whole range or expanded',
    () async {
      await f.roleplay(
        'selected',
        'orphan',
        jsonEncode([
          SyntheticConsentSelectionFixture.message('a'),
          SyntheticConsentSelectionFixture.message('hidden', hidden: true),
          SyntheticConsentSelectionFixture.message('b'),
          SyntheticConsentSelectionFixture.message('c'),
        ]),
      );
      f.observe();
      final a = await f.repo.listRoleplayMessages(
        sessionId: 'selected',
        limit: 1,
      );
      expect(a.items.single.messageId, 'a');
      expect(a.nextOffset, 1);
      expect(a.omittedCount, 1);
      expect(a.limitedCount, 2);
      final b = await f.repo.listRoleplayMessages(
        sessionId: 'selected',
        offset: 1,
        limit: 1,
      );
      expect(b.items.single.messageId, 'b');
      expect(b.items.single.nativeOrder, 2);
      final end = await f.repo.listRoleplayMessages(
        sessionId: 'selected',
        offset: 3,
        limit: 1,
      );
      expect(end.items, isEmpty);
      expect(end.nextOffset, isNull);
      expect(end.eligibleCount, 3);
      expect(() => a.items.add(b.items.single), throwsUnsupportedError);
      _narrowRoleplayReads(f, target: 'selected');
      expect(f.spy.writes, 0);
    },
  );

  test(
    'synthetic null, empty, invalid and missing targets never enumerate or substitute',
    () async {
      await f.roleplay(
        'first',
        'orphan',
        jsonEncode([SyntheticConsentSelectionFixture.message('a')]),
      );
      await f.supportSession('first-support');
      f.observe();
      for (final id in <String?>[
        null,
        '',
        ' ',
        r'C:\private',
        'x' * 257,
        SyntheticConsentSelectionFixture.secret,
      ]) {
        for (final page in [
          await f.repo.listRoleplayMessages(sessionId: id),
          await f.repo.listSupportMessages(sessionId: id),
        ]) {
          expect(page.status, SupportConsentSelectionStatus.unavailable);
          expect(page.items, isEmpty);
          expect(page.sessionId, isNull);
        }
      }
      expect(f.spy.reads, isEmpty);
      expect(f.storage.operations, isEmpty);
      final missing = await f.repo.listRoleplayMessages(sessionId: 'missing');
      expect(missing.status, SupportConsentSelectionStatus.unavailable);
      expect(missing.items, isEmpty);
      expect(f.spy.reads.single.args, ['missing']);
      expect(f.spy.reads.single.sql, isNot(contains('json_each')));
      f.observe();
      final missingSupport = await f.repo.listSupportMessages(
        sessionId: 'missing-support',
      );
      expect(missingSupport.status, SupportConsentSelectionStatus.unavailable);
      expect(f.spy.reads.single.args, ['missing-support']);
      expect(f.spy.reads.single.sql, isNot(contains('support_messages')));
    },
  );

  test(
    'synthetic hidden exact target is unavailable without enumerating its messages',
    () async {
      await f.character('hidden', hidden: true);
      await f.roleplay('hidden-session', 'hidden', '[{}]');
      f.observe();
      final page = await f.repo.listRoleplayMessages(
        sessionId: 'hidden-session',
      );
      expect(page.status, SupportConsentSelectionStatus.unavailable);
      expect(page.items, isEmpty);
      expect(f.spy.reads.single.sql, isNot(contains('json_each')));
      expect(f.spy.writes, 0);
    },
  );

  test(
    'synthetic malformed/nonarray/oversized sources fail closed before enumeration',
    () async {
      final jsons = [
        '{broken',
        '{}',
        'null',
        '"scalar"',
        jsonEncode([
          {
            'id': 'huge',
            'role': 'user',
            'content':
                'x' * (SupportConsentSelectionRepo.maxRoleplaySourceChars + 1),
          },
        ]),
      ];
      for (var i = 0; i < jsons.length; i++) {
        await f.roleplay('bad$i', 'orphan', jsons[i]);
      }
      final before = await f.snapshot();
      f.observe();
      for (var i = 0; i < jsons.length; i++) {
        final page = await f.repo.listRoleplayMessages(sessionId: 'bad$i');
        expect(
          page.status,
          i == 4
              ? SupportConsentSelectionStatus.limited
              : SupportConsentSelectionStatus.unavailable,
        );
        expect(page.items, isEmpty);
        expect(page.statusLabel, isNot(contains('broken')));
      }
      expect(f.spy.reads.every((r) => !r.sql.contains('json_each')), isTrue);
      final sessions = await f.repo.listRoleplaySessions();
      expect(
        sessions.items
            .map((s) => s.status)
            .where((s) => s == SupportConsentSelectionStatus.unavailable)
            .length,
        4,
      );
      await _preserved(f, before);
    },
  );

  test(
    'synthetic source row cap refuses enumeration and reports explicit limited count',
    () async {
      await f.roleplay(
        'large',
        'orphan',
        jsonEncode(
          List.generate(
            SupportConsentSelectionRepo.maxSourceMessages + 1,
            (i) => {'id': 'm$i', 'role': 'user'},
          ),
        ),
      );
      f.observe();
      final page = await f.repo.listRoleplayMessages(sessionId: 'large');
      expect(page.status, SupportConsentSelectionStatus.limited);
      expect(page.items, isEmpty);
      expect(page.sourceCount, 2001);
      expect(page.limitedCount, 2001);
      expect(page.eligibleCount, 0);
      expect(f.spy.reads.single.sql, isNot(contains('json_each')));
    },
  );

  test(
    'synthetic invalid types, metadata key duplicates, IDs and secrets are omitted',
    () async {
      final entries = <Object?>[
        null,
        3,
        'not an object',
        {},
        {'id': 'negative', 'role': 'assistant', 'swipeId': -1},
        {'id': 'float', 'role': 'assistant', 'timestamp': 1.5},
        {'id': 'badflag', 'role': 'user', 'isHidden': 'false'},
        {
          'id': 'map-swipe',
          'role': 'assistant',
          'swipeId': {'private': SyntheticConsentSelectionFixture.bodyCanary},
        },
        {'id': 'x' * 257, 'role': 'user'},
        {'id': SyntheticConsentSelectionFixture.secret, 'role': 'user'},
        {'id': 'bad/path', 'role': 'user'},
        {'id': 'legacy', 'role': 'assistant'},
      ];
      final raw =
          '${jsonEncode(entries).substring(0, jsonEncode(entries).length - 1)}, {"id":"keydup","id":"other","role":"user"}]';
      await f.roleplay('selected', 'orphan', raw);
      f.observe();
      final page = await f.repo.listRoleplayMessages(sessionId: 'selected');
      expect(page.status, SupportConsentSelectionStatus.available);
      expect(page.items.map((m) => m.messageId), ['legacy']);
      expect(page.omittedCount, 12);
      expect(page.items.single.swipeId, 0);
      expect(page.items.single.agentSwipeId, 0);
      _noCanaries(_messageStrings(page));
      _narrowRoleplayReads(f, target: 'selected');
    },
  );

  test(
    'synthetic current label redactor is refreshed after async SQLite reads',
    () async {
      await f.character(
        'c',
        name: 'Name ROTATED_LABEL_SECRET',
        variantName: 'Variant ROTATED_LABEL_SECRET',
      );
      await f.roleplay('selected', 'c', '[]');
      f.observe();
      f.spy.afterSelect = (_) async {
        f.redactor = SecretRedactor(knownSecrets: ['ROTATED_LABEL_SECRET']);
      };
      final page = await f.repo.listRoleplayMessages(sessionId: 'selected');
      expect(
        page.roleplaySession!.label,
        isNot(contains('ROTATED_LABEL_SECRET')),
      );
      expect(page.roleplaySession!.label, contains('[REDACTED]'));
      final sessions = await f.repo.listRoleplaySessions();
      expect(
        sessions.items.single.label,
        isNot(contains('ROTATED_LABEL_SECRET')),
      );
    },
  );

  test(
    'synthetic invalid request bounds refuse before any DB/vault read',
    () async {
      await f.roleplay('selected', 'orphan', '[]');
      f.observe();
      for (final (offset, limit) in [(-1, 1), (10001, 1), (0, 0), (0, 101)]) {
        expect(
          (await f.repo.listRoleplayMessages(
            sessionId: 'selected',
            offset: offset,
            limit: limit,
          )).status,
          SupportConsentSelectionStatus.unavailable,
        );
        expect(
          (await f.repo.listSupportMessages(
            sessionId: 'selected',
            offset: offset,
            limit: limit,
          )).status,
          SupportConsentSelectionStatus.unavailable,
        );
      }
      for (final (offset, limit) in [(-1, 1), (10001, 1), (0, 0), (0, 51)]) {
        expect(
          (await f.repo.listRoleplaySessions(
            offset: offset,
            limit: limit,
          )).status,
          SupportConsentSelectionStatus.unavailable,
        );
      }
      expect(f.spy.reads, isEmpty);
      expect(f.storage.operations, isEmpty);
    },
  );

  test(
    'synthetic encrypted support metadata exact createdAt/id order, no body/card/other history read',
    () async {
      await f.supportSession('selected');
      await f.supportSession('other');
      await f.supportMessage('z', 'selected', createdAt: 4);
      await f.supportMessage('b', 'selected', createdAt: 2);
      await f.supportMessage('a', 'selected', role: 'user', createdAt: 2);
      await f.supportMessage(
        'failed',
        'selected',
        status: 'error',
        createdAt: 3,
      );
      await f.supportMessage(
        'typing',
        'selected',
        status: 'typing',
        createdAt: 3,
      );
      await f.supportMessage('unknown', 'selected', role: 'tool', createdAt: 3);
      await f.supportMessage('other-message', 'other');
      final before = await f.snapshot();
      f.observe();
      final page = await f.repo.listSupportMessages(
        sessionId: 'selected',
        limit: 2,
      );
      expect(page.items.map((m) => m.messageId), ['a', 'b']);
      expect(page.nextOffset, 2);
      expect(page.items.map((m) => m.nativeOrder), [0, 1]);
      expect(page.items.map((m) => m.createdAtSeconds), [2, 2]);
      expect(page.omittedCount, 3);
      expect(page.limitedCount, 1);
      expect(
        page.items.every(
          (m) =>
              m.sessionId == 'selected' &&
              m.swipeId == null &&
              m.timestampMs == null,
        ),
        isTrue,
      );
      expect(f.storage.reads, 1);
      expect(f.storage.operations, ['read']);
      _narrowSupportReads(f, 'selected');
      _noCanaries(_messageStrings(page));
      f.observe();
      final tail = await f.repo.listSupportMessages(
        sessionId: 'selected',
        offset: 2,
        limit: 2,
      );
      expect(tail.items.single.messageId, 'z');
      expect(tail.items.single.nativeOrder, 5);
      _narrowSupportReads(f, 'selected');
      await _preserved(f, before);
    },
  );

  test(
    'synthetic missing support key locks entire selection with zero child reads/writes',
    () async {
      await f.supportSession('selected');
      await f.supportMessage('m', 'selected');
      final before = await f.snapshot();
      f.storage.values.clear();
      f.observe();
      final page = await f.repo.listSupportMessages(sessionId: 'selected');
      expect(page.status, SupportConsentSelectionStatus.parentLocked);
      expect(page.statusLabel, 'Session locked');
      expect(page.items, isEmpty);
      expect(f.spy.reads.length, 1);
      expect(f.spy.reads.single.sql, contains('support_sessions'));
      expect(f.storage.operations, ['read']);
      await _preserved(f, before);
    },
  );

  test(
    'synthetic malformed encrypted support parent refuses, corrupt child remains metadata-only, not proof',
    () async {
      await f.supportSession('selected');
      await f.supportMessage('m', 'selected');
      await (f.db.update(
        f.db.supportMessages,
      )..where((t) => t.id.equals('m'))).write(
        const SupportMessagesCompanion(
          bodyCiphertext: Value('CORRUPT_BODY_CANARY'),
        ),
      );
      final beforeBody = await f.snapshot();
      f.observe();
      final metadata = await f.repo.listSupportMessages(sessionId: 'selected');
      expect(metadata.items.single.messageId, 'm');
      expect(metadata.bodiesRead, isFalse);
      expect(metadata.statusLabel, 'Metadata only');
      expect(f.storage.operations, ['read']);
      _narrowSupportReads(f, 'selected');
      _noCanaries(_messageStrings(metadata));
      await _preserved(f, beforeBody);
      await (f.db.update(
        f.db.supportSessions,
      )..where((t) => t.id.equals('selected'))).write(
        const SupportSessionsCompanion(
          titleCiphertext: Value('CORRUPT_PARENT_CANARY'),
        ),
      );
      final beforeParent = await f.snapshot();
      f.observe();
      final locked = await f.repo.listSupportMessages(sessionId: 'selected');
      expect(locked.status, SupportConsentSelectionStatus.parentLocked);
      expect(locked.items, isEmpty);
      expect(f.spy.reads.length, 1);
      expect(f.storage.operations, isEmpty);
      await _preserved(f, beforeParent);
    },
  );

  test(
    'synthetic support row cap and empty target remain truthful metadata states',
    () async {
      await f.supportSession('large');
      await f.supportSession('empty');
      final envelope = await f.cipher.encrypt(
        plaintext: SyntheticConsentSelectionFixture.bodyCanary,
        table: 'support_messages',
        rowId: 'template',
        sessionId: 'large',
        field: 'body_ciphertext',
      );
      // Synthetic encrypted bytes intentionally need not authenticate per child:
      // selector never claims individual body integrity and must not decrypt them.
      await f.db.batch((batch) {
        batch.insertAll(
          f.db.supportMessages,
          List.generate(
            2001,
            (i) => SupportMessagesCompanion.insert(
              id: 'm$i',
              sessionId: 'large',
              role: 'user',
              bodyCiphertext: envelope,
            ),
          ),
        );
      });
      final before = await f.snapshot();
      f.observe();
      final large = await f.repo.listSupportMessages(sessionId: 'large');
      expect(large.status, SupportConsentSelectionStatus.limited);
      expect(large.limitedCount, 2001);
      expect(large.items, isEmpty);
      expect(f.spy.reads.length, 2);
      expect(f.spy.reads.last.sql, contains('COUNT(*)'));
      f.observe();
      final empty = await f.repo.listSupportMessages(sessionId: 'empty');
      expect(empty.status, SupportConsentSelectionStatus.available);
      expect(empty.sourceCount, 0);
      expect(empty.items, isEmpty);
      expect(empty.eligibleCount, 0);
      expect(empty.nextOffset, isNull);
      _narrowSupportReads(f, 'empty');
      await _preserved(f, before);
    },
  );

  test(
    'synthetic SQL/redactor errors are fixed unavailable, never empty success or error serialization',
    () async {
      await f.roleplay('selected', 'orphan', '[]');
      await f.supportSession('selected');
      final before = await f.snapshot();
      f.observe();
      final poison = _PoisonError();
      f.spy.selectError = poison;
      final sessions = await f.repo.listRoleplaySessions();
      final roleplay = await f.repo.listRoleplayMessages(sessionId: 'selected');
      final support = await f.repo.listSupportMessages(sessionId: 'selected');
      expect(sessions.status, SupportConsentSelectionStatus.unavailable);
      for (final p in [roleplay, support]) {
        expect(p.status, SupportConsentSelectionStatus.unavailable);
        expect(p.statusLabel, 'Selection unavailable');
        expect(p.items, isEmpty);
      }
      expect(poison.serializations, 0);
      expect(f.spy.writes, 0);
      f.spy.selectError = null;
      await _preserved(f, before);
      final closed = SupportConsentSelectionRepo(
        db: f.db,
        supportRepo: f.support,
        currentRedactor: () => throw poison,
      );
      f.observe();
      expect(
        (await closed.listRoleplayMessages(sessionId: 'selected')).status,
        SupportConsentSelectionStatus.unavailable,
      );
      expect(
        (await closed.listSupportMessages(sessionId: 'selected')).status,
        SupportConsentSelectionStatus.unavailable,
      );
      expect(f.spy.reads, isEmpty);
      expect(poison.serializations, 0);
    },
  );
}

void _narrowRoleplayReads(
  SyntheticConsentSelectionFixture f, {
  String? target,
  bool sessions = false,
}) {
  for (final read in f.spy.reads) {
    final sql = read.sql.toLowerCase();
    expect(sql, isNot(contains('api_configs')));
    expect(sql, isNot(contains('support_')));
    for (final forbidden in [
      '\$.content',
      '\$.reasoning',
      '\$.swipes',
      '\$.imagePath',
      'draft',
      'avatar_path',
      'description',
    ]) {
      expect(sql, isNot(contains(forbidden.toLowerCase())));
    }
    if (sessions) {
      // Only the ordinary picker's branch timestamp is extracted for ordering.
      expect(sql, contains(r'$.branchedat'));
      expect(sql, isNot(contains(r'$.sessionname')));
      expect(sql, isNot(contains('select session_vars_json')));
    } else {
      expect(sql, isNot(contains('session_vars_json')));
    }
    expect(read.returnedRows!, lessThanOrEqualTo(sessions ? 51 : 2000));
    if (target != null) {
      expect(read.args, [target]);
      expect(sql, contains('session_id = ?'));
    }
    expect(
      read.returnedColumns.intersection({
        'messages_json',
        'content',
        'reasoning',
        'avatar_path',
        'session_vars_json',
      }),
      isEmpty,
    );
  }
}

void _narrowSupportReads(SyntheticConsentSelectionFixture f, String target) {
  for (final read in f.spy.reads) {
    expect(read.args, [target]);
    expect(read.sql, isNot(contains('api_configs')));
    expect(read.sql, isNot(contains('support_context')));
    expect(read.sql, isNot(contains('support_mutation')));
    expect(read.sql, isNot(contains('body_ciphertext')));
    expect(read.sql, isNot(contains('cards_ciphertext')));
    expect(
      read.returnedColumns.intersection({
        'body_ciphertext',
        'cards_ciphertext',
      }),
      isEmpty,
    );
    if (read.sql.contains('support_messages')) {
      expect(read.sql, contains('session_id = ?'));
    } else {
      expect(read.sql, contains('support_sessions'));
      expect(read.sql, contains('"id" = ?'));
    }
  }
}

Future<void> _preserved(
  SyntheticConsentSelectionFixture f,
  String before,
) async {
  expect(f.spy.writes, 0);
  expect(f.storage.operations.every((o) => o == 'read'), isTrue);
  f.spy.observing = false;
  expect(await f.snapshot(), before);
}

Iterable<String> _sessionStrings(
  Iterable<SupportConsentSessionOption> sessions,
) sync* {
  for (final s in sessions) {
    yield s.sessionId;
    yield s.characterId;
    yield s.variantGroupId ?? '';
    yield s.characterLabel;
    yield s.variantLabel;
    yield s.label;
    yield s.toString();
  }
}

Iterable<String> _messageStrings(SupportConsentMessagePage page) sync* {
  yield page.sessionId ?? '';
  yield page.statusLabel;
  yield page.toString();
  if (page.roleplaySession != null) {
    yield* _sessionStrings([page.roleplaySession!]);
  }
  for (final m in page.items) {
    yield m.sessionId;
    yield m.messageId;
    yield m.role.name;
    yield m.label;
    yield m.toString();
  }
}

void _noCanaries(Iterable<String> values) {
  for (final value in values) {
    for (final canary in [
      SyntheticConsentSelectionFixture.secret,
      SyntheticConsentSelectionFixture.bodyCanary,
      SyntheticConsentSelectionFixture.cardCanary,
      SyntheticConsentSelectionFixture.reasoningCanary,
      SyntheticConsentSelectionFixture.pathCanary,
      'CORRUPT_BODY_CANARY',
      'CORRUPT_PARENT_CANARY',
    ]) {
      expect(value, isNot(contains(canary)));
    }
  }
}

final class _PoisonError {
  int serializations = 0;
  @override
  String toString() {
    serializations++;
    throw StateError(SyntheticConsentSelectionFixture.secret);
  }
}
