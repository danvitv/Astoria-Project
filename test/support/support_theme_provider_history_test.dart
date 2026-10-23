import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_history_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final state in ['exhausted', 'corrupt', 'identityABA']) {
    historyTest('P durable $state policy denies old history without fallback', (
      f,
    ) async {
      await seedHistory(f);
      final intent = f.emit()!;
      final page = (await intent.discoverHistory())!;
      final p = f.runtime.snapshot.preferences!;
      const codec = SupportPermissionStore.codec;
      final block = (await f.repo.getContextBlockById(
        codec.idFor(historySession),
      ))!;
      if (state == 'corrupt') {
        await f.repo.putContextBlock(
          block.copyWith(protectedFactsJson: '{"version":99}'),
        );
      } else {
        SupportPermissionPreferences policy(String identity, int revision) =>
            SupportPermissionPreferences(
              supportSessionId: historySession,
              policyIdentity: identity,
              revision: revision,
              scope: p.scope,
              grants: p.grants,
            );
        await f.repo.putContextBlock(
          codec.encode(
            policy(
              'replacement-policy',
              state == 'exhausted' ? maxSupportPermissionRevision : p.revision,
            ),
            block.createdAt,
          ),
        );
        await f.runtime.refresh(resolve: false);
        if (state == 'identityABA') {
          await f.repo.putContextBlock(codec.encode(p, block.createdAt));
        }
      }
      await f.runtime.refresh(resolve: false);
      await readOnlyHistory(f, () async {
        expect(
          intent.history(page)!.availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        final denied = (await intent.discoverHistory())!;
        expect(
          intent.history(denied)!.availability,
          SupportThemeHistoryAvailability.unavailable,
        );
      });
    });
  }

  historyTest('P restored JSON/strings cannot forge native history handles', (
    f,
  ) async {
    final Object payload = {'cursor': 'history-000', 'session': historySession};
    await readOnlyHistory(f, () async {
      expect(
        () => payload as SupportThemeHistoryCursor,
        throwsA(isA<TypeError>()),
      );
      expect(
        () => payload as SupportThemeHistoryPage,
        throwsA(isA<TypeError>()),
      );
    });
  });
  historyTest(
    'P actual emitted local history needs no model/recipient/change grant/theme read',
    (f) async {
      await seedHistory(f, count: 33);
      final review = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.confirmedSettingsChanges,
          false,
        ),
        isTrue,
      );
      final intent = f.emit()!;
      await readOnlyHistory(f, () async {
        expect(f.runtime.snapshot.preferences!.recipient, isNull);
        final page = (await intent.discoverHistory())!;
        final view = intent.history(page)!;
        expect(view.availability, SupportThemeHistoryAvailability.available);
        expect(view.entries.length, 32);
        final next = (await intent.discoverHistory(cursor: view.nextCursor))!;
        expect(intent.history(next)!.entries.single.operationId, historyId(0));
        expect(await intent.prepareLastUndo(), isNull);
      });
    },
  );

  historyTest('P foreign pages and cursors denied independently before SQL', (
    f,
  ) async {
    await seedHistory(f, count: 33);
    final a = f.emit()!, b = f.emit()!;
    final page = (await a.discoverHistory())!;
    final cursor = a.history(page)!.nextCursor!;
    await readOnlyHistory(f, () async {
      expect(b.history(page), isNull);
      final statements = f.sql.statements.length;
      expect(await b.discoverHistory(cursor: cursor), isNull);
      expect(f.sql.statements.length, statements);
      expect(
        () => (cursor as Object) as SupportThemeApproval,
        throwsA(isA<TypeError>()),
      );
      expect(
        () => (page as Object) as SupportThemeReview,
        throwsA(isA<TypeError>()),
      );
    });
  });

  for (final boundary in [
    'grant',
    'scope',
    'epochABA',
    'sessionABA',
    'issuer',
    'controller',
    'service',
    'cipher',
    'theme',
    'uiABA',
    'redactor',
  ]) {
    historyTest('P $boundary cannot transplant original history continuation', (
      f,
    ) async {
      await seedHistory(f, count: 33);
      final intent = f.emit()!;
      final page = (await intent.discoverHistory())!;
      final cursor = intent.history(page)!.nextCursor!;
      switch (boundary) {
        case 'grant':
          await grantOff(f);
        case 'scope':
          await scopeOff(f);
        case 'epochABA':
          f.runtime.invalidateLease();
          await f.runtime.refresh(resolve: false);
        case 'sessionABA':
          f.workspace.selectSession(ThemeProviderFixture.other);
          f.workspace.selectSession(historySession);
          await f.workspace.refresh();
          await f.runtime.refresh(resolve: false);
        case 'issuer':
          f.controller.invalidateDisplayedIntents();
        case 'controller':
          f.container.invalidate(supportNativeConsentControllerProvider);
          await f.reconcile();
        case 'service':
          f.container.invalidate(supportThemeActionServiceProvider);
          await f.reconcile();
        case 'cipher':
          await f.replaceCipher();
        case 'theme':
          await f.replaceTheme();
        case 'uiABA':
          f.uiLifetime = Object();
        case 'redactor':
          f.redaction.registerSecret('History B');
      }
      await readOnlyHistory(f, () async {
        final denied = (await intent.discoverHistory(cursor: cursor))!;
        expect(
          intent.history(denied)!.availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        final fresh = f.emit();
        if (fresh != null) {
          expect(fresh.history(page), isNull);
          expect(await fresh.discoverHistory(cursor: cursor), isNull);
        }
      });
    });
  }

  for (final checkpoint in ['metadata', 'evidence-before', 'evidence-after']) {
    for (final retirement in [
      'ui',
      'epoch',
      'redactor',
      'service',
      'sessionABA',
    ]) {
      historyTest(
        'P $retirement retirement at real awaited $checkpoint denies late history',
        (f) async {
          await seedHistory(f);
          final intent = f.emit()!;
          final barrier = f.barrier();
          var held = false;
          Future<void> hook(String e) async {
            final match = switch (checkpoint) {
              'metadata' => e.contains('SELECT id, session_id'),
              'evidence-before' =>
                e.startsWith('decrypt-before:') &&
                    e.contains('|support_mutation_journal|'),
              _ =>
                e.startsWith('decrypt-after:') &&
                    e.contains('|support_mutation_journal|'),
            };
            if (!held && match) {
              held = true;
              await barrier.wait();
            }
          }

          f.sql.event = hook;
          f.primitive.event = hook;
          await readOnlyHistory(f, () async {
            final pending = intent.discoverHistory();
            await barrier.entered.future;
            switch (retirement) {
              case 'ui':
                f.uiLifetime = Object();
              case 'epoch':
                f.runtime.invalidateLease();
              case 'redactor':
                f.redaction.registerSecret('History B');
              case 'service':
                f.binding.service.dispose();
              case 'sessionABA':
                f.runtime.selectSession(ThemeProviderFixture.other);
                f.runtime.selectSession(historySession);
            }
            barrier.release.complete();
            final page = (await pending)!;
            expect(held, isTrue);
            expect(
              intent.history(page)!.availability,
              SupportThemeHistoryAvailability.unavailable,
            );
          });
        },
      );
    }
  }

  for (final checkpoint in ['metadata', 'evidence-before', 'evidence-after']) {
    for (final edit in ['grant', 'scope']) {
      historyTest(
        'P actual C $edit begins at awaited $checkpoint and retires reader before its write',
        (f) async {
          await seedHistory(f);
          final intent = f.emit()!;
          final review = (await f.controller.prepareReview(
            resolveRecipient: false,
          ))!;
          final journal =
              (await f.db
                      .customSelect(
                        'SELECT * FROM support_mutation_journal ORDER BY id',
                      )
                      .get())
                  .map((r) => r.data)
                  .toList();
          final barrier = f.barrier();
          var held = false;
          Future<void> hook(String e) async {
            final match = switch (checkpoint) {
              'metadata' => e.contains('SELECT id, session_id'),
              'evidence-before' =>
                e.startsWith('decrypt-before:') &&
                    e.contains('|support_mutation_journal|'),
              _ =>
                e.startsWith('decrypt-after:') &&
                    e.contains('|support_mutation_journal|'),
            };
            if (!held && match) {
              held = true;
              await barrier.wait();
            }
          }

          f.sql.event = hook;
          final journalEncrypts = <String>[];
          f.primitive.event = (e) async {
            if (e.startsWith('encrypt:') &&
                e.contains('|support_mutation_journal|')) {
              journalEncrypts.add(e);
            }
            await hook(e);
          };
          final pending = intent.discoverHistory();
          await barrier.entered.future;
          // REAL C synchronously revokes admission before its own queued durable
          // policy edit. That deliberate write is not attributed to discovery.
          final change = edit == 'grant'
              ? f.controller.setGrant(
                  review,
                  SupportPermission.readSafeSettings,
                  false,
                )
              : f.controller.selectTheme(review, false);
          barrier.release.complete();
          try {
            final page = (await pending)!;
            expect(
              intent.history(page)!.availability,
              SupportThemeHistoryAvailability.unavailable,
            );
          } finally {
            expect(
              await change,
              isTrue,
            ); // Drain the actual C write under guards.
          }
          expect(held, isTrue);
          expect(
            (await f.db
                    .customSelect(
                      'SELECT * FROM support_mutation_journal ORDER BY id',
                    )
                    .get())
                .map((r) => r.data)
                .toList(),
            journal,
          );
          expect(journalEncrypts, isEmpty);
          expect(f.harness.store.checkedWrites, isEmpty);
          expect(f.harness.store.ordinaryWrites, isEmpty);
          expect(f.backing.activeId, 'a');
          if (edit == 'grant') {
            expect(
              f.runtime.snapshot.preferences!.allows(
                SupportPermission.readSafeSettings,
              ),
              isFalse,
            );
          } else {
            expect(
              f.runtime.snapshot.preferences!.scope!.safeCategories.contains(
                SupportSafeCategory.theme,
              ),
              isFalse,
            );
          }
          // Once the independent edit settles, all five-table/vault/theme/write
          // baselines apply again to the denied original reader.
          await readOnlyHistory(f, () async {
            final denied = (await intent.discoverHistory())!;
            expect(
              intent.history(denied)!.availability,
              SupportThemeHistoryAvailability.unavailable,
            );
          });
        },
      );
    }
  }

  historyTest(
    'P retained started job and replacement reader never invent settlement',
    (f) async {
      final original = f.emit()!;
      final review = await f.review(original);
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final custody = f.custody;
      final job = f.confirm(original, review);
      await gate.started.future;
      await f.replaceCipher();
      final reader = f.emit()!;
      expect(f.custody, same(custody));
      await readOnlyHistory(f, () async {
        final page = (await reader.discoverHistory())!;
        final row = reader.history(page)!.entries.single;
        expect(row.state, SupportThemeRecoveryState.liveJob);
        expect(row.before, isNull);
        expect(row.status, isNull);
      });
      gate.release.complete();
      expect((await job).status, SupportMutationStatus.applied);
      await readOnlyHistory(f, () async {
        final page = (await reader.discoverHistory())!;
        expect(
          reader.history(page)!.entries.single.state,
          SupportThemeRecoveryState.history,
        );
        expect(
          reader.history(page)!.entries.single.status,
          SupportMutationStatus.applied,
        );
      });
    },
  );

  historyTest('P reconstructed history cannot restore last Undo or replay', (
    f,
  ) async {
    await seedHistory(f);
    f.container.invalidate(supportThemeOriginalHandlesProvider);
    await f.reconcile();
    final intent = f.emit()!;
    await readOnlyHistory(f, () async {
      final page = (await intent.discoverHistory())!;
      expect(
        intent.history(page)!.entries.single.state,
        SupportThemeRecoveryState.history,
      );
      expect(await intent.prepareLastUndo(), isNull);
      expect(
        () => (page as Object) as SupportThemeApplied,
        throwsA(isA<TypeError>()),
      );
      expect(
        () => (page as Object) as SupportThemeApproval,
        throwsA(isA<TypeError>()),
      );
    });
  });

  historyTest('P genuine DB loss retires retained pages and cursors', (
    f,
  ) async {
    await seedHistory(f, count: 33);
    final intent = f.emit()!;
    final page = (await intent.discoverHistory())!;
    final cursor = intent.history(page)!.nextCursor!;
    await f.replaceDatabase();
    await readOnlyHistory(f, () async {
      expect(
        intent.history(page)!.availability,
        SupportThemeHistoryAvailability.unavailable,
      );
      final unavailable = (await intent.discoverHistory(cursor: cursor))!;
      expect(
        intent.history(unavailable)!.availability,
        SupportThemeHistoryAvailability.unavailable,
      );
    });
  });
}
