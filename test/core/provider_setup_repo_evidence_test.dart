import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';

import 'provider_setup_repo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mismatch in [
    'action',
    'target',
    'session',
    'before',
    'after',
    'domain',
    'status',
  ]) {
    providerRepoTest(
      'inconsistent $mismatch evidence is refused before any row write',
      (f) async {
        final draft = f.draft();
        final evidence = f.evidence(
          journalId: 'synthetic-evidence',
          action: SupportProviderSetupAction.create,
          after: draft.view,
        );
        final invalid = switch (mismatch) {
          'action' => evidence.copyWith(
            beforeJson: SupportProviderSetupEvidence.encode(
              action: SupportProviderSetupAction.update,
              sessionId: evidence.sessionId,
              connectionId: draft.view.connectionId,
              state: null,
            ),
          ),
          'target' => evidence.copyWith(targetId: 'synthetic-other-id'),
          'session' => evidence.copyWith(sessionId: 'synthetic-other-session'),
          'before' => evidence.copyWith(beforeJson: evidence.afterJson),
          'after' => evidence.copyWith(afterJson: evidence.beforeJson),
          'domain' => evidence.copyWith(domain: 'arbitrary.dispatcher'),
          _ => evidence.copyWith(status: 'applied'),
        };
        final before = await f.snapshot();
        f.events.clear();
        expect(
          await f.setup.create(
            draft: draft,
            pendingEvidence: invalid,
            isCurrent: f.isCurrent,
          ),
          isNull,
        );
        expect(f.events, isEmpty);
        expect(await f.snapshot(), before);
      },
    );
  }

  providerRepoTest(
    'journal ID collision does not dispatch another row create',
    (f) async {
      await f.create(f.draft());
      final before = await f.snapshot();
      final another = f.draft();
      expect(await f.create(another), isNull);
      expect(await f.snapshot(), before);
      expect(await f.row(another.view.connectionId), isNull);
    },
  );

  providerRepoTest(
    'observed history remains observation, never restored quick Undo',
    (f) async {
      final created = (await f.create(f.draft()))!;
      final observed = await f.support.readCurrentMutation(
        id: created.journalId,
        sessionId: created.sessionId,
        domain: SupportProviderSetupRepo.domain,
        targetId: created.connectionId,
        isCurrent: f.isCurrent,
      );
      expect(observed, isNotNull);
      final recreated = SupportProviderSetupRepo(
        db: f.db,
        apiRepo: f.api,
        supportRepo: f.support,
      );
      expect(
        await recreated.undo(original: created, isCurrent: f.isCurrent),
        isNull,
      );
      expect(await f.row(created.connectionId), isNotNull);
    },
  );
}
