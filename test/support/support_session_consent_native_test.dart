import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_authorization_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import 'support_session_consent_fixture.dart';
import 'synthetic_consent_selection_fixture.dart';

void main() {
  late SessionConsentFixture f;
  setUp(() async {
    f = SessionConsentFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  Future<SupportNativeSessionChoice?> gameChoice() async =>
      f.controller.prepareSessionHistory(
        await f.review(),
        SupportConsentSelectionSource.roleplay,
        SessionConsentFixture.game,
      );

  test(
    'empty exact native target chooses SESSION only; once; no implicit grant/read',
    () async {
      final r = await f.review();
      f.data.observe();
      final choice = (await f.controller.prepareSessionHistory(
        r,
        SupportConsentSelectionSource.roleplay,
        SessionConsentFixture.game,
      ))!;
      expect(choice.metadata.messageCount, 0);
      expect(choice.metadata.bodiesRead, isFalse);
      expect(choice.metadata.attachmentsIncluded, isFalse);
      expect(
        choice.metadata.roleplaySession!.characterLabel,
        'Synthetic character',
      );
      expect(
        choice.metadata.toString(),
        isNot(contains(SessionConsentFixture.game)),
      );
      expect(f.data.spy.writes, 0);
      expect(f.messageReads, 0);
      expect(
        f.data.storage.reads,
        0,
        reason: 'Game metadata cannot need a vault read',
      );
      expect(f.data.spy.reads.single.args, [SessionConsentFixture.game]);
      expect(
        f.data.spy.reads.single.returnedColumns,
        isNot(contains('messages_json')),
      );
      f.data.spy.observing = false;
      expect((await f.policy()).scope, isNull, reason: 'Preparing never saves');
      expect(await f.controller.selectSessionHistory(choice), isTrue);
      expect(await f.controller.selectSessionHistory(choice), isFalse);
      expect(choice.isCurrent, isFalse);
      final p = await f.policy();
      expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.wholeSession);
      expect(p.scope!.gameHistory, isNull);
      expect(p.grants, isEmpty);
      expect(f.controller.view.gameSessionSelected, isTrue);
      expect(f.controller.view.gameMessageCount, 0);
      expect(f.controller.view.supportSessionSelected, isFalse);
      expect(f.controller.view.needsRecipientConfirmation, isTrue);
      expect(f.recipientReads, 0);
      expect(f.connectionReads, 0);
      expect(f.messageReads, 0);
    },
  );

  test(
    'support choices accept ONLY current policy session and do not decrypt bodies',
    () async {
      await f.data.supportMessage('own-synthetic', SessionConsentFixture.own);
      final review = await f.review();
      final reads = f.sessionReads;
      expect(
        await f.controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.support,
          SessionConsentFixture.foreign,
        ),
        isNull,
      );
      expect(
        f.sessionReads,
        reads,
        reason: 'Foreign metadata is denied before read',
      );
      f.data.observe();
      final choice = (await f.controller.prepareSessionHistory(
        review,
        SupportConsentSelectionSource.support,
        SessionConsentFixture.own,
      ))!;
      expect(choice.metadata.roleplaySession, isNull);
      expect(choice.metadata.messageCount, 1);
      expect(f.messageReads, 0);
      expect(
        f.data.spy.reads.expand((r) => r.returnedColumns),
        isNot(contains('body_ciphertext')),
      );
      expect(f.data.spy.writes, 0);
      f.data.spy.observing = false;
      expect(await f.controller.selectSessionHistory(choice), isTrue);
      expect((await f.policy()).grants, isEmpty);
      expect(f.controller.view.supportSessionSelected, isTrue);
      expect(f.recipientReads, 0);
      expect(f.connectionReads, 0);
    },
  );

  for (final kind in [
    'hidden',
    'orphan',
    'corrupt',
    'wrong-shape',
    'invalid-parent',
  ]) {
    test(
      'exact metadata denies $kind without substituting a catalog candidate',
      () async {
        if (kind == 'hidden') {
          await (f.data.db.update(f.data.db.characters)
                ..where((t) => t.charId.equals('session-consent-character')))
              .write(const CharactersCompanion(hidden: Value(true)));
        } else if (kind == 'orphan') {
          await (f.data.db.delete(
            f.data.db.characters,
          )..where((t) => t.charId.equals('session-consent-character'))).go();
        } else if (kind == 'invalid-parent') {
          await (f.data.db.update(f.data.db.characters)
                ..where((t) => t.charId.equals('session-consent-character')))
              .write(const CharactersCompanion(variantOrder: Value(-1)));
        } else {
          await (f.data.db.update(f.data.db.chatSessions)
                ..where((t) => t.sessionId.equals(SessionConsentFixture.game)))
              .write(
                ChatSessionsCompanion(
                  messagesJson: Value(
                    kind == 'corrupt' ? 'synthetic-corrupt' : '{}',
                  ),
                ),
              );
        }
        expect(await gameChoice(), isNull);
        expect(
          await f.controller.prepareSessionHistory(
            await f.review(),
            SupportConsentSelectionSource.roleplay,
            'not-present',
          ),
          isNull,
        );
        expect((await f.policy()).scope, isNull);
        expect(f.recipientReads, 0);
      },
    );
  }

  test(
    'locked support parent cannot be selected; public metadata contains no plaintext',
    () async {
      await (f.data.db.update(
        f.data.db.supportSessions,
      )..where((t) => t.id.equals(SessionConsentFixture.foreign))).write(
        const SupportSessionsCompanion(
          titleCiphertext: Value('synthetic-locked'),
        ),
      );
      final metadata = await f.data.repo.readSessionMetadata(
        source: SupportConsentSelectionSource.support,
        sessionId: SessionConsentFixture.foreign,
      );
      expect(metadata.status, SupportConsentSelectionStatus.parentLocked);
      expect(metadata.isAvailable, isFalse);
      expect(
        metadata.toString(),
        isNot(contains(SyntheticConsentSelectionFixture.secret)),
      );
      expect(
        metadata.toString(),
        isNot(contains(SyntheticConsentSelectionFixture.bodyCanary)),
      );
      expect(metadata.roleplaySession, isNull);
      final review = await f.review();
      await (f.data.db.update(
        f.data.db.supportSessions,
      )..where((t) => t.id.equals(SessionConsentFixture.own))).write(
        const SupportSessionsCompanion(
          titleCiphertext: Value('synthetic-locked'),
        ),
      );
      expect(
        await f.controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.support,
          SessionConsentFixture.own,
        ),
        isNull,
      );
    },
  );

  test(
    'pending UNSELECTED candidate is checked before metadata read',
    () async {
      final review = await f.review();
      final settle = f.sources.beginMutation(
        sessionId: SessionConsentFixture.game,
        messageIds: {'new-not-in-any-selection'},
      );
      expect(
        f.runtime.pending,
        0,
        reason: 'Candidate is not the current scope',
      );
      final reads = f.sessionReads;
      expect(
        await f.controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.roleplay,
          SessionConsentFixture.game,
        ),
        isNull,
      );
      expect(f.sessionReads, reads);
      settle();
      final fresh = await gameChoice();
      expect(fresh, isNotNull);
    },
  );

  test(
    'candidate begin AND settled ABA during prepare loses original checkpoint',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeSession = () async {
        entered.complete();
        await release.future;
      };
      final pending = gameChoice();
      await entered.future;
      final settle = f.sources.beginMutation(
        sessionId: SessionConsentFixture.game,
        messageIds: {'new-id'},
      );
      settle();
      release.complete();
      expect(await pending, isNull);
      expect((await f.policy()).scope, isNull);
    },
  );

  for (final kind in ['target', 'unrelated']) {
    test(
      '$kind mutation after prepare preserves only the proper original choice',
      () async {
        final choice = (await gameChoice())!;
        final settle = f.sources.beginMutation(
          sessionId: kind == 'target'
              ? SessionConsentFixture.game
              : 'unrelated',
          messageIds: {'brand-new-id'},
        );
        settle();
        expect(choice.isCurrent, kind == 'unrelated');
        expect(
          await f.controller.selectSessionHistory(choice),
          kind == 'unrelated',
        );
        expect((await f.policy()).scope != null, kind == 'unrelated');
      },
    );
  }

  for (final phase in ['confirmation-read', 'latest-row']) {
    test(
      '$phase candidate mutation denies without any permission row',
      () async {
        final choice = (await gameChoice())!;
        final entered = Completer<void>(), release = Completer<void>();
        if (phase == 'confirmation-read') {
          f.beforeSession = () async {
            entered.complete();
            await release.future;
          };
        } else {
          f.repo.pauseAdmission();
        }
        final pending = f.controller.selectSessionHistory(choice);
        expect(
          f.runtime.localActionsAvailable,
          isFalse,
          reason: 'Original local token starts before the first await',
        );
        await (phase == 'confirmation-read'
            ? entered.future
            : f.repo.entered!.future);
        final settle = f.sources.beginMutation(
          sessionId: SessionConsentFixture.game,
          messageIds: {'brand-new-id'},
        );
        settle();
        if (phase == 'confirmation-read') {
          release.complete();
        } else {
          f.repo.release!.complete();
        }
        expect(await pending, isFalse);
        expect((await f.policy()).scope, isNull);
        expect(await f.controller.selectSessionHistory(choice), isFalse);
      },
    );
  }

  test(
    'confirm-read reentry cannot restore its original issuer or save selection',
    () async {
      final choice = (await gameChoice())!;
      f.beforeSession = () async {
        f.controller.invalidateDisplayedIntents();
      };
      expect(await f.controller.selectSessionHistory(choice), isFalse);
      expect((await f.policy()).scope, isNull);
      expect(f.runtime.localActionsAvailable, isTrue);
    },
  );

  test(
    'native notify reentry retires choice before confirmation metadata access',
    () async {
      final choice = (await gameChoice())!;
      final reads = f.sessionReads;
      final stop = f.runtime.listen(() {
        f.controller.invalidateDisplayedIntents();
      });
      expect(await f.controller.selectSessionHistory(choice), isFalse);
      stop();
      expect(f.sessionReads, reads);
      expect((await f.policy()).scope, isNull);
    },
  );

  test(
    'latest-row policy replacement cannot inherit the old candidate approval',
    () async {
      final choice = (await gameChoice())!;
      f.repo.pauseAdmission();
      final pending = f.controller.selectSessionHistory(choice);
      await f.repo.entered!.future;
      final independent = SupportPermissionStore(f.data.support);
      await independent.selectScopeFromNative(
        SessionConsentFixture.own,
        SupportPermissionScope(
          selectionRevision: 1,
          safeCategories: [SupportSafeCategory.theme],
        ),
        isCurrent: () => true,
      );
      final retained = await f.data.db
          .select(f.data.db.supportContextBlocks)
          .get();
      f.repo.release!.complete();
      expect(await pending, isFalse);
      expect(
        await f.data.db.select(f.data.db.supportContextBlocks).get(),
        retained,
      );
      expect((await f.policy()).scope!.gameSessionId, isNull);
      expect((await f.policy()).grants, isEmpty);
    },
  );

  test(
    'native policy away-and-back never renews an ORIGINAL candidate',
    () async {
      final choice = (await gameChoice())!;
      expect(await f.controller.selectTheme(await f.review(), true), isTrue);
      expect(await f.controller.selectTheme(await f.review(), false), isTrue);
      expect(choice.isCurrent, isFalse);
      expect(await f.controller.selectSessionHistory(choice), isFalse);
      expect((await f.policy()).scope!.gameSessionId, isNull);
    },
  );

  test(
    'exact metadata port cannot substitute another source or session',
    () async {
      final controller = SupportNativeConsentController(
        runtime: f.runtime,
        sessionSources: f.sources,
        readMessages: (_, _, _) async => throw StateError('No message reads'),
        readSession: (_, _) => f.data.repo.readSessionMetadata(
          source: SupportConsentSelectionSource.support,
          sessionId: SessionConsentFixture.foreign,
        ),
      );
      final review = (await controller.prepareReview(resolveRecipient: false))!;
      expect(
        await controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.roleplay,
          SessionConsentFixture.game,
        ),
        isNull,
      );
      expect((await f.policy()).scope, isNull);
    },
  );

  for (final kind in [
    'deleted',
    'changed-metadata',
    'session-ABA',
    'controller',
    'registry',
  ]) {
    test(
      'fresh exact confirmation refuses $kind original native choice',
      () async {
        final choice = (await gameChoice())!;
        switch (kind) {
          case 'deleted':
            await (f.data.db.delete(
                  f.data.db.chatSessions,
                )..where((t) => t.sessionId.equals(SessionConsentFixture.game)))
                .go();
          case 'changed-metadata':
            await (f.data.db.update(
                  f.data.db.chatSessions,
                )..where((t) => t.sessionId.equals(SessionConsentFixture.game)))
                .write(const ChatSessionsCompanion(updatedAt: Value(999)));
          case 'session-ABA':
            f.runtime.selectSession(SessionConsentFixture.foreign);
            f.runtime.selectSession(SessionConsentFixture.own);
            await f.runtime.refresh();
          case 'controller':
            f.controller.invalidateDisplayedIntents();
          case 'registry':
            f.sources.dispose();
        }
        expect(await f.controller.selectSessionHistory(choice), isFalse);
        expect((await f.policy()).scope, isNull);
      },
    );
  }

  test(
    'theme/connections and one selected list preserve the OTHER whole extent',
    () async {
      expect(
        await f.controller.selectSessionHistory((await gameChoice())!),
        isTrue,
      );
      final supportChoice = (await f.controller.prepareSessionHistory(
        await f.review(),
        SupportConsentSelectionSource.support,
        SessionConsentFixture.own,
      ))!;
      expect(await f.controller.selectSessionHistory(supportChoice), isTrue);
      expect(await f.controller.selectTheme(await f.review(), true), isTrue);
      expect(
        await f.controller.selectConnections(await f.review(), true),
        isTrue,
      );
      var p = await f.policy();
      expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.wholeSession);
      expect(p.scope!.supportHistoryExtent, SupportHistoryExtent.wholeSession);
      await f.data.supportMessage('selected-own', SessionConsentFixture.own);
      final selected = (await f.controller.prepareMessages(
        await f.review(),
        SupportConsentSelectionSource.support,
        SessionConsentFixture.own,
      ))!;
      expect(
        await f.controller.selectMessages(selected, ['selected-own']),
        isTrue,
      );
      p = await f.policy();
      expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.wholeSession);
      expect(
        p.scope!.supportHistoryExtent,
        SupportHistoryExtent.selectedMessages,
      );
      expect(p.scope!.supportHistory!.messageIds, ['selected-own']);
      expect(
        p.scope!.safeCategories,
        containsAll([
          SupportSafeCategory.theme,
          SupportSafeCategory.connections,
        ]),
      );
      expect(p.grants, isEmpty);
    },
  );

  test(
    'new ID accepted in whole current session retires leases; persistent grant survives',
    () async {
      expect(
        await f.controller.selectSessionHistory((await gameChoice())!),
        isTrue,
      );
      await f.permissions.setGrantFromNative(
        SessionConsentFixture.own,
        SupportPermission.readGameData,
        true,
        isCurrent: () => true,
      );
      await f.runtime.refresh();
      final lease = await f.runtime.authorization.prepare(
        supportSessionId: SessionConsentFixture.own,
        use: SupportPermissionUse.localRead,
        sources: [
          SupportPermissionSource.gameSessionHistory(
            SessionConsentFixture.game,
          ),
        ],
      );
      expect(lease, isNotNull);
      final epoch = f.runtime.epoch, owner = f.runtime.writeOwner;
      final settle = f.sources.beginMutation(
        sessionId: SessionConsentFixture.game,
        messageIds: {'brand-new-id'},
      );
      expect(f.runtime.epoch, greaterThan(epoch));
      expect(f.runtime.writeOwner, owner);
      expect(f.runtime.pending, 1);
      await (f.data.db.update(
        f.data.db.chatSessions,
      )..where((t) => t.sessionId.equals(SessionConsentFixture.game))).write(
        ChatSessionsCompanion(
          messagesJson: Value(
            jsonEncode([
              {
                'id': 'brand-new-id',
                'role': 'user',
                'content': 'Synthetic new body',
              },
            ]),
          ),
        ),
      );
      settle();
      settle();
      expect(f.runtime.pending, 0);
      var staleLoads = 0;
      await expectLater(
        f.runtime.authorization.loadLocal(lease!, () async {
          staleLoads++;
          return 'synthetic-loader-result';
        }),
        throwsA(isA<SupportAuthorizationDenied>()),
      );
      expect(staleLoads, 0);
      expect((await f.policy()).allows(SupportPermission.readGameData), isTrue);
      expect(
        (await f.policy()).scope!.gameHistoryExtent,
        SupportHistoryExtent.wholeSession,
      );
      expect(
        await f.runtime.authorization.prepare(
          supportSessionId: SessionConsentFixture.own,
          use: SupportPermissionUse.localRead,
          sources: [
            SupportPermissionSource.gameSessionHistory(
              SessionConsentFixture.game,
            ),
          ],
        ),
        isNotNull,
      );
    },
  );
}
