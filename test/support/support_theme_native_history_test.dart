import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';

import 'support_theme_history_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  historyTest(
    'native 33 bounded rows recover strict facts and no receipt/approval',
    (f) async {
      await seedHistory(f, count: 33);
      final service = f.binding.service, intent = nativeHistoryIntent(f);
      final decryptedIds = <String>{};
      f.primitive.event = (event) async {
        if (event.startsWith('decrypt-before:') &&
            event.contains('|support_mutation_journal|')) {
          decryptedIds.add(event.split('|')[2]);
        }
      };
      await readOnlyHistory(f, () async {
        final page = await service.discoverHistory(intent);
        final view = service.projectHistory(intent, page);
        expect(view.availability, SupportThemeHistoryAvailability.available);
        expect(view.entries.length, 32);
        expect(decryptedIds.length, 32);
        expect(decryptedIds, isNot(contains(historyId(0))));
        expect(
          view.entries.every(
            (e) =>
                e.state == SupportThemeRecoveryState.history &&
                e.status == SupportMutationStatus.applied &&
                e.before?.active == false &&
                e.after?.active == false,
          ),
          isTrue,
        );
        final next = await service.discoverHistory(
          intent,
          cursor: view.nextCursor,
        );
        expect(
          service.projectHistory(intent, next).entries.single.operationId,
          historyId(0),
        );
        expect(
          () => (page as Object) as SupportThemeApproval,
          throwsA(isA<TypeError>()),
        );
        expect(
          () => (page as Object) as SupportThemeApplied,
          throwsA(isA<TypeError>()),
        );
      });
    },
  );

  historyTest('native empty differs from unknown-row unavailable', (f) async {
    final service = f.binding.service, intent = nativeHistoryIntent(f);
    await readOnlyHistory(f, () async {
      final view = service.projectHistory(
        intent,
        await service.discoverHistory(intent),
      );
      expect(view.availability, SupportThemeHistoryAvailability.available);
      expect(view.entries, isEmpty);
    });
    await seedHistory(f, unknownCodec: true);
    await readOnlyHistory(f, () async {
      final view = service.projectHistory(
        intent,
        await service.discoverHistory(intent),
      );
      expect(view.availability, SupportThemeHistoryAvailability.available);
      expect(view.entries.single.state, SupportThemeRecoveryState.unavailable);
      expect(view.entries.single.before, isNull);
    });
  });

  for (final status in SupportMutationStatus.values) {
    historyTest('native ${status.value} is a historical/uncertain fact only', (
      f,
    ) async {
      await seedHistory(f, status: status.value);
      final service = f.binding.service, intent = nativeHistoryIntent(f);
      await readOnlyHistory(f, () async {
        final row = service
            .projectHistory(intent, await service.discoverHistory(intent))
            .entries
            .single;
        expect(
          row.state,
          status.unresolved
              ? SupportThemeRecoveryState.uncertain
              : SupportThemeRecoveryState.history,
        );
        expect(row.status, status);
        expect(row.before?.active, isFalse);
        expect(row.after?.active, isFalse);
      });
    });
  }

  for (final state in [
    'corrupt-before',
    'corrupt-after',
    'unknown-status',
    'locked-key',
  ]) {
    historyTest('native $state never disappears into false empty', (f) async {
      await seedHistory(f);
      if (state == 'locked-key') {
        f.storage.readError = StateError('SYNTHETIC_LOCKED');
      } else {
        await changeHistory(f, historyId(0), switch (state) {
          'corrupt-before' => 'before_ciphertext',
          'corrupt-after' => 'after_ciphertext',
          _ => 'status',
        }, 'unknown');
      }
      final service = f.binding.service, intent = nativeHistoryIntent(f);
      await readOnlyHistory(f, () async {
        final view = service.projectHistory(
          intent,
          await service.discoverHistory(intent),
        );
        if (state == 'locked-key') {
          expect(
            view.availability,
            SupportThemeHistoryAvailability.unavailable,
          );
        } else {
          expect(
            view.entries.single.state,
            SupportThemeRecoveryState.unavailable,
          );
          expect(view.entries.single.before, isNull);
        }
      });
    });
  }

  historyTest(
    'native excludes foreign session/domain/target before evidence AEAD',
    (f) async {
      await seedHistory(f);
      await seedHistory(f, session: ThemeProviderFixture.other);
      await seedHistory(f, domain: 'foreign.domain');
      await seedHistory(f, target: 'foreign-target');
      await seedHistoryCanaries(f);
      final decrypts = <String>[];
      final unrelated = <String>[];
      f.primitive.event = (e) async {
        if (e.startsWith('decrypt-before:') &&
            e.contains('|unrelated-history-')) {
          unrelated.add(e);
        }
        if (e.startsWith('decrypt-before:') &&
            e.contains('|support_mutation_journal|')) {
          decrypts.add(e);
        }
      };
      final service = f.binding.service, intent = nativeHistoryIntent(f);
      await readOnlyHistory(f, () async {
        expect(
          service
              .projectHistory(intent, await service.discoverHistory(intent))
              .entries
              .single
              .operationId,
          historyId(0),
        );
        expect(decrypts, hasLength(2));
        expect(unrelated, isEmpty);
        expect(
          decrypts.every(
            (e) => e.contains('|${historyId(0)}|$historySession|'),
          ),
          isTrue,
        );
      });
    },
  );

  historyTest(
    'native new known label/id and closed policy reproject without fallback',
    (f) async {
      await seedHistory(f, count: 33);
      final service = f.binding.service, intent = nativeHistoryIntent(f);
      final page = await service.discoverHistory(intent);
      expect(
        service.projectHistory(intent, page).entries.first.after!.name,
        'History B',
      );
      f.redaction.registerSecret('History B');
      await readOnlyHistory(f, () async {
        final view = service.projectHistory(intent, page);
        expect(view.entries.first.after!.name, SecretRedactor.removed);
        expect(view.nextCursor, isNull);
      });
      f.redaction.registerSecret(historyId(32));
      await readOnlyHistory(f, () async {
        final row = service.projectHistory(intent, page).entries.first;
        expect(row.state, SupportThemeRecoveryState.unavailable);
        expect(row.operationId, isNull);
        expect(row.before, isNull);
      });
      f.redaction.dispose();
      await readOnlyHistory(f, () async {
        expect(
          service.projectHistory(intent, page).availability,
          SupportThemeHistoryAvailability.unavailable,
        );
      });
    },
  );

  historyTest(
    'native same-service different emitted intent cannot transplant page/cursor',
    (f) async {
      await seedHistory(f, count: 33);
      final service = f.binding.service,
          a = nativeHistoryIntent(f),
          b = nativeHistoryIntent(f);
      final page = await service.discoverHistory(a);
      final cursor = service.projectHistory(a, page).nextCursor!;
      await readOnlyHistory(f, () async {
        expect(
          service.projectHistory(b, page).availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        final denied = await service.discoverHistory(b, cursor: cursor);
        expect(
          service.projectHistory(b, denied).availability,
          SupportThemeHistoryAvailability.unavailable,
        );
      });
    },
  );

  for (final boundary in [historyId(32), historyId(1)]) {
    historyTest(
      'native exact encrypted $boundary cursor expectation denies evidence re-encryption',
      (f) async {
        await seedHistory(f, count: 33);
        final intent = f.emit()!;
        final page = (await intent.discoverHistory())!;
        final cursor = intent.history(page)!.nextCursor!;
        // Same plaintext/status/order, different real AEAD bytes on original DB.
        await f.repo.putMutation((await f.repo.getMutationById(boundary))!);
        await readOnlyHistory(f, () async {
          final denied = (await intent.discoverHistory(cursor: cursor))!;
          expect(
            intent.history(denied)!.availability,
            SupportThemeHistoryAvailability.unavailable,
          );
        });
      },
    );
  }

  historyTest(
    'native corrupt boundary row remains visible unavailable with denied continuation',
    (f) async {
      await seedHistory(f, count: 33);
      await changeHistory(f, historyId(1), 'before_ciphertext', 'corrupt');
      final intent = f.emit()!;
      await readOnlyHistory(f, () async {
        final page = (await intent.discoverHistory())!;
        final view = intent.history(page)!;
        expect(view.entries.last.state, SupportThemeRecoveryState.unavailable);
        expect(view.nextCursor, isNotNull);
        final denied = (await intent.discoverHistory(cursor: view.nextCursor))!;
        expect(
          intent.history(denied)!.availability,
          SupportThemeHistoryAvailability.unavailable,
        );
      });
    },
  );

  historyTest(
    'native current theme identifier retirement removes both labels without fallback',
    (f) async {
      await seedHistory(f);
      final intent = f.emit()!;
      final page = (await intent.discoverHistory())!;
      f.redaction.registerSecret('b');
      await readOnlyHistory(f, () async {
        final row = intent.history(page)!.entries.single;
        expect(row.state, SupportThemeRecoveryState.unavailable);
        expect(row.before, isNull);
        expect(row.after, isNull);
      });
    },
  );

  historyTest(
    'native live job is checked again at current projection, never stale settled history',
    (f) async {
      final applied = await f.apply();
      final intent = f.emit()!;
      final page = (await intent.discoverHistory())!;
      expect(
        intent.history(page)!.entries.single.state,
        SupportThemeRecoveryState.history,
      );
      final undoReview = (await intent.prepareLastUndo())!;
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(intent, undoReview);
      await gate.started.future;
      expect(applied.applied, isNotNull);
      await readOnlyHistory(f, () async {
        final view = intent.history(page)!;
        expect(view.entries.single.state, SupportThemeRecoveryState.liveJob);
        expect(view.entries.single.before, isNull);
        expect(view.entries.single.status, isNull);
      });
      gate.release.complete();
      expect((await job).status, SupportMutationStatus.undone);
    },
  );
}
