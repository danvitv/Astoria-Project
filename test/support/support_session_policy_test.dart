import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'helpers/support_permission_test_fixtures.dart';
import 'support_session_consent_fixture.dart';

void main() {
  const codec = SupportPermissionCodec();
  SupportPermissionScope whole({int revision = 1}) => SupportPermissionScope(
    selectionRevision: revision,
    gameSessionId: SessionConsentFixture.game,
    gameHistoryExtent: SupportHistoryExtent.wholeSession,
    supportHistoryExtent: SupportHistoryExtent.wholeSession,
  );
  SupportPermissionPreferences policy(SupportPermissionScope scope) =>
      SupportPermissionPreferences(
        supportSessionId: SessionConsentFixture.own,
        policyIdentity: 'synthetic-policy',
        revision: 1,
        scope: scope,
      );

  test('old selected canonical bytes and null retain exact v1 semantics', () {
    final p = policy(
      SupportPermissionScope(
        selectionRevision: 1,
        gameSessionId: SessionConsentFixture.game,
        gameHistory: SupportMessageSelection(['synthetic-one']),
      ),
    );
    final oldBytes = jsonEncode({
      'version': 1,
      'session': p.supportSessionId,
      'identity': p.policyIdentity,
      'revision': p.revision,
      'grants': {for (final r in SupportPermission.values) r.name: false},
      'scope': {
        'revision': 1,
        'gameSession': SessionConsentFixture.game,
        'gameHistory': ['synthetic-one'],
        'supportHistory': null,
        'safeCategories': <String>[],
        'data': <String, Object?>{},
      },
      'recipient': null,
    });
    final block = codec.encode(p, 1);
    expect(block.protectedFactsJson, oldBytes);
    final decoded = codec.decode(p.supportSessionId, block);
    expect(decoded.scope!.sameAs(p.scope), isTrue);
    expect(decoded.scope!.hasSupportHistory, isFalse);
    final none = policy(
      SupportPermissionScope(
        selectionRevision: 2,
        gameSessionId: SessionConsentFixture.game,
      ),
    );
    expect(none.hasScopeFor(SupportPermission.readGameData), isFalse);
    expect(none.hasScopeFor(SupportPermission.reportSupportHistory), isFalse);
    expect(
      SupportPermissionSource.gameSessionHistory(
        SessionConsentFixture.game,
      ).isSelectedBy(none),
      isFalse,
    );
  });

  test(
    'whole explicit v2 keeps the same row identity; all fourteen stay OFF',
    () {
      final p = policy(whole());
      final block = codec.encode(p, 1);
      expect(block.id, codec.idFor(p.supportSessionId));
      expect(block.summary, SupportPermissionCodec.marker);
      final json = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
      expect(json['version'], 2);
      expect(json['scope']['gameHistoryExtent'], 'wholeSession');
      expect(json['scope']['supportHistoryExtent'], 'wholeSession');
      expect(json['scope']['gameHistory'], isNull);
      final decoded = codec.decode(p.supportSessionId, block);
      expect(decoded.scope!.sameAs(p.scope), isTrue);
      for (final right in SupportPermission.values) {
        expect(decoded.allows(right), isFalse, reason: right.name);
      }
      for (final source in [
        SupportPermissionSource.gameSessionHistory(SessionConsentFixture.game),
        SupportPermissionSource.supportSessionHistory(
          SessionConsentFixture.own,
        ),
      ]) {
        expect(source.selectedIds, isEmpty);
        expect(
          source.allowedFor(decoded, SupportPermissionUse.modelContext),
          isFalse,
        );
        expect(
          source.allowedFor(decoded, SupportPermissionUse.reportPreparation),
          isFalse,
        );
      }
    },
  );

  test(
    'exact and whole sources never cross-match; support only owns its policy',
    () {
      final wholePolicy = policy(whole());
      final selected = policy(
        SupportPermissionScope(
          selectionRevision: 1,
          gameSessionId: SessionConsentFixture.game,
          gameHistory: SupportMessageSelection(['synthetic-one']),
          supportHistory: SupportMessageSelection(['synthetic-one']),
        ),
      );
      final game = SupportPermissionSource.gameSessionHistory(
        SessionConsentFixture.game,
      );
      final support = SupportPermissionSource.supportSessionHistory(
        SessionConsentFixture.own,
      );
      expect(game.isSelectedBy(wholePolicy), isTrue);
      expect(support.isSelectedBy(wholePolicy), isTrue);
      expect(game.isSelectedBy(selected), isFalse);
      expect(support.isSelectedBy(selected), isFalse);
      expect(
        SupportPermissionSource.supportSessionHistory(
          SessionConsentFixture.foreign,
        ).isSelectedBy(wholePolicy),
        isFalse,
      );
      expect(
        SupportPermissionSource.gameSessionHistory(
          'unrelated-game',
        ).isSelectedBy(wholePolicy),
        isFalse,
      );
      final exactGame = SupportPermissionSource.gameHistory(
        SessionConsentFixture.own,
        SessionConsentFixture.game,
        SupportMessageSelection(['synthetic-one']),
      );
      expect(exactGame.isSelectedBy(selected), isTrue);
      expect(exactGame.isSelectedBy(wholePolicy), isFalse);
      expect(exactGame.sameAs(game), isFalse);
      final exactSupport = SupportPermissionSource.supportHistory(
        SessionConsentFixture.own,
        SupportMessageSelection(['synthetic-one']),
      );
      expect(exactSupport.isSelectedBy(selected), isTrue);
      expect(exactSupport.isSelectedBy(wholePolicy), isFalse);
      expect(exactSupport.sameAs(support), isFalse);
    },
  );

  test(
    'scope validation forbids whole-plus-IDs, missing target and aliases',
    () {
      expect(
        () => SupportPermissionScope(
          selectionRevision: 1,
          gameHistoryExtent: SupportHistoryExtent.wholeSession,
        ),
        throwsStateError,
      );
      for (final game in [true, false]) {
        expect(
          () => SupportPermissionScope(
            selectionRevision: 1,
            gameSessionId: SessionConsentFixture.game,
            gameHistoryExtent: game
                ? SupportHistoryExtent.wholeSession
                : SupportHistoryExtent.selectedMessages,
            supportHistoryExtent: game
                ? SupportHistoryExtent.selectedMessages
                : SupportHistoryExtent.wholeSession,
            gameHistory: game ? SupportMessageSelection(['one']) : null,
            supportHistory: game ? null : SupportMessageSelection(['one']),
          ),
          throwsStateError,
        );
      }
      expect(
        () => SupportPermissionSource.gameSessionHistory('bad\n'),
        throwsStateError,
      );
      expect(() => SupportMessageSelection([]), throwsStateError);
    },
  );

  for (final malformed in [
    'unknown-version',
    'v1-whole-fields',
    'missing-game-extent',
    'missing-support-extent',
    'null-extent',
    'all-alias',
    'unknown-field',
    'whole-with-ids',
    'whole-without-game',
    'empty-list',
    'duplicate-key',
    'null-v2-scope',
  ]) {
    test(
      'strict decoding denies $malformed without restoring old approvals',
      () {
        final p = policy(whole());
        final block = codec.encode(p, 1);
        final m = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
        final s = m['scope'] as Map<String, dynamic>;
        switch (malformed) {
          case 'unknown-version':
            m['version'] = 3;
          case 'v1-whole-fields':
            m['version'] = 1;
          case 'missing-game-extent':
            s.remove('gameHistoryExtent');
          case 'missing-support-extent':
            s.remove('supportHistoryExtent');
          case 'null-extent':
            s['gameHistoryExtent'] = null;
          case 'all-alias':
            s['gameHistoryExtent'] = 'all';
          case 'unknown-field':
            s['all'] = true;
          case 'whole-with-ids':
            s['gameHistory'] = ['one'];
          case 'whole-without-game':
            s['gameSession'] = null;
          case 'empty-list':
            s['supportHistory'] = <String>[];
          case 'duplicate-key':
            break;
          case 'null-v2-scope':
            m['scope'] = null;
        }
        final raw = malformed == 'duplicate-key'
            ? jsonEncode(
                m,
              ).replaceFirst('"version":2', '"version":2,"version":1')
            : jsonEncode(m);
        expect(
          () => codec.decode(
            p.supportSessionId,
            block.copyWith(protectedFactsJson: raw),
          ),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
      },
    );
  }

  test(
    'extent participates in scope sameness; dependent grants require fresh enable',
    () {
      var p = policy(whole()).withNativeRecipient(permissionRecipient());
      for (final right in [
        SupportPermission.readGameData,
        SupportPermission.modelGameHistory,
        SupportPermission.modelSupportHistory,
        SupportPermission.reportGameHistory,
        SupportPermission.reportSupportHistory,
      ]) {
        p = p.withNativeGrant(right, true);
      }
      final selected = SupportPermissionScope(
        selectionRevision: 1,
        gameSessionId: SessionConsentFixture.game,
        gameHistory: SupportMessageSelection(['one']),
        supportHistoryExtent: SupportHistoryExtent.wholeSession,
      );
      expect(p.scope!.sameAs(selected), isFalse);
      p = p.withNativeScope(selected);
      expect(p.grants, isEmpty);
      p = p.withNativeGrant(SupportPermission.modelSupportHistory, true);
      p = p.withNativeRecipient(permissionRecipient(model: 'changed'));
      expect(p.allows(SupportPermission.modelSupportHistory), isFalse);
    },
  );

  test(
    'actual encrypted v2 survives new store/controller without native authority',
    () async {
      final f = SessionConsentFixture();
      try {
        await f.seed();
        await f.permissions.selectScopeFromNative(
          SessionConsentFixture.own,
          whole(),
          isCurrent: () => true,
        );
        final reloaded = SupportPermissionStore(f.data.support);
        final p = (await reloaded.readForNative(
          SessionConsentFixture.own,
        )).preferences!;
        expect(p.scope!.sameAs(whole()), isTrue);
        expect(p.grants, isEmpty);
        final row = await f.data.support.getContextBlockById(
          codec.idFor(p.supportSessionId),
        );
        expect(jsonDecode(row!.protectedFactsJson)['version'], 2);
        final actual =
            (await f.data.db.select(f.data.db.supportContextBlocks).get())
                .singleWhere((r) => r.id == codec.idFor(p.supportSessionId));
        expect(
          actual.protectedFactsCiphertext,
          isNot(contains('wholeSession')),
        );
        final old = (await f.controller.prepareSessionHistory(
          await f.review(),
          SupportConsentSelectionSource.roleplay,
          SessionConsentFixture.game,
        ))!;
        final replacement = f.newController();
        expect(replacement.view.gameSessionSelected, isTrue);
        expect(replacement.view.supportSessionSelected, isTrue);
        expect(replacement.view.needsRecipientConfirmation, isTrue);
        expect(await replacement.selectSessionHistory(old), isFalse);
        f.controller.invalidateDisplayedIntents();
        expect(await f.controller.selectSessionHistory(old), isFalse);
        expect(f.recipientReads, 0);
        expect(f.connectionReads, 0);
      } finally {
        await f.close();
      }
    },
  );
}
