import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

import 'helpers/support_game_source_native_fixture.dart';
import 'helpers/support_model_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'matching accepted begin retires preview/emitter/native handles BEFORE queue',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final runtime = f.runtime;
        final controller = m.container.read(
          supportNativeConsentControllerProvider,
        );
        final review = (await controller.prepareReview())!;
        final displayed = controller.view.displayedIntent;
        final emitter = m.emitter();
        final send = m.send(from: emitter);
        final preview = await m.preview(send);
        final epoch = runtime.epoch, owner = runtime.writeOwner;
        final context = runtime.recipientContext;
        final recipient = runtime.recipient;
        m.sql.observations.clear();
        final settle = f.begin(messageIds: {GameSourceNativeFixture.selected});
        expect(runtime.epoch, greaterThan(epoch));
        expect(runtime.pending, 1);
        expect(runtime.writeOwner, owner);
        expect(runtime.recipientContext!.sameAs(context), isTrue);
        expect(runtime.recipient, same(recipient));
        expect(runtime.recipientConfirmed, isTrue);
        expect(preview.isCurrent, isFalse);
        expect(emitter.isCurrent, isFalse);
        expect(send.approve(preview), isNull);
        expect(controller.isDisplayedIntentCurrent(displayed), isFalse);
        expect(await controller.prepareReview(), isNull);
        expect(
          await controller.setGrant(
            review,
            SupportPermission.readGameData,
            true,
          ),
          isFalse,
        );
        expect(await controller.confirmRecipient(review), isFalse);
        f.expectNoSourceReads();
        settle();
        expect(runtime.pending, 0);
        expect(preview.isCurrent, isFalse);
        expect(emitter.isCurrent, isFalse);
        expect(controller.isDisplayedIntentCurrent(displayed), isFalse);
        expect(
          await controller.setGrant(
            review,
            SupportPermission.readGameData,
            true,
          ),
          isFalse,
        );
        expect((await send.finished).saved, isTrue);
        final fresh = m.send();
        final next = await m.preview(fresh);
        expect(next.isCurrent, isTrue);
        fresh.stop();
        await fresh.finished;
        expect(m.adapters, isEmpty);
      });
    },
  );

  for (final kind in ['session', 'ids']) {
    test('unrelated $kind leaves same emitted request usable', () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final send = f.model.send();
        final preview = await f.model.preview(send);
        final epoch = f.runtime.epoch;
        final settle = f.begin(
          sessionId: kind == 'session'
              ? 'unrelated-source'
              : GameSourceNativeFixture.game,
          messageIds: kind == 'ids' ? {'source-excluded'} : null,
        );
        expect(f.runtime.pending, 0);
        expect(f.runtime.epoch, epoch);
        expect(preview.isCurrent, isTrue);
        final approval = send.approve(preview)!;
        final result = await send.dispatch(approval);
        expect(result.saved, isTrue);
        expect(f.model.adapters.single.fetches, 1);
        settle();
      });
    });
  }

  test(
    'nested whole/exact pending balances ONLY adapter contribution',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        f.runtime.pending += 2; // Independently owned queued permission work.
        final whole = f.begin();
        final exact = f.begin(messageIds: {GameSourceNativeFixture.selected});
        final unrelated = f.begin(messageIds: {'source-excluded'});
        expect(f.runtime.pending, 3);
        whole();
        expect(f.runtime.pending, 3);
        exact();
        expect(f.runtime.pending, 2);
        unrelated();
        expect(f.runtime.pending, 2);
        f.runtime.pending -= 2;
        final settings = f.runtime.beginSettingsChange();
        final source = f.begin();
        expect(f.runtime.pending, 2);
        expect(f.runtime.settingsPending, 1);
        source();
        expect(f.runtime.pending, 1);
        expect(f.runtime.settingsPending, 1);
        settings();
        expect(f.runtime.pending, 0);
        expect(f.runtime.settingsPending, 0);
      });
    },
  );

  test(
    'select away removes only matching pending; current-input model remains usable',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final settle = f.begin();
        expect(f.runtime.pending, 1);
        await f.selectAway();
        expect(f.runtime.pending, 0);
        final send = f.model.send();
        final preview = await f.model.preview(send);
        expect(preview.gameMessages, 0);
        expect((await send.dispatch(send.approve(preview)!)).saved, isTrue);
        settle();
        expect(f.runtime.pending, 0);
        expect(f.model.adapters.single.fetches, 1);
      });
    },
  );

  test(
    'already pending registry is sampled on ORIGINAL native owner creation without source loads',
    () async {
      await GameSourceNativeFixture().run((f) async {
        final m = f.model;
        await m.db.customSelect('SELECT 1').getSingle();
        await m.repo.createSession(
          const SupportSession(
            id: ModelProviderFixture.session,
            title: 'Synthetic',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
        // Policy exists before the runtime: no native/model owner was evaluated.
        final permissions = m.container.read(supportPermissionStoreProvider);
        await permissions.selectScopeFromNative(
          ModelProviderFixture.session,
          SupportPermissionScope(
            selectionRevision: 1,
            gameSessionId: GameSourceNativeFixture.game,
            gameHistory: SupportMessageSelection([
              GameSourceNativeFixture.selected,
            ]),
          ),
          isCurrent: () => true,
        );
        final settle = f.begin();
        m.sql.observations.clear();
        final runtime = f.runtime;
        expect(
          m.sql.observations,
          isEmpty,
          reason: 'Subscription loads no policy/history/recipient.',
        );
        runtime.selectSession(ModelProviderFixture.session);
        await runtime.refresh();
        expect(runtime.pending, 1);
        final controller = m.container.read(
          supportNativeConsentControllerProvider,
        );
        expect(await controller.prepareReview(), isNull);
        f.expectNoSourceReads();
        settle();
        expect(runtime.pending, 0);
        expect(m.adapters, isEmpty);
      }, initialize: false);
    },
  );

  test(
    'silent registry disposal fails closed at native admission, no old callback renewal',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final controller = m.container.read(
          supportNativeConsentControllerProvider,
        );
        final displayed = controller.view.displayedIntent;
        final emitter = m.emitter();
        final epoch = f.runtime.epoch;
        final old = f.registry;
        old.dispose(); // No event: the original checkpoint must discover retirement.
        expect(controller.isDisplayedIntentCurrent(displayed), isFalse);
        expect(f.runtime.pending, 1);
        expect(f.runtime.epoch, greaterThan(epoch));
        expect(emitter.isCurrent, isFalse);
        old.beginMutation(sessionId: GameSourceNativeFixture.game)();
        expect(await controller.prepareReview(), isNull);
        expect(f.runtime.pending, 1);
        expect(await m.send().accepted, isFalse);
        expect(m.adapters, isEmpty);
      });
    },
  );

  for (final replacement in ['registry', 'runtime', 'controller', 'model']) {
    test(
      '$replacement replacement does not transplant old callbacks or settlement ownership',
      () async {
        await GameSourceNativeFixture().run((f) async {
          await f.seedGame();
          final m = f.model;
          final oldRuntime = f.runtime, oldRegistry = f.registry;
          final send = m.send();
          final preview = await m.preview(send);
          final settle = f.begin();
          switch (replacement) {
            case 'registry':
              m.container.invalidate(chatSourceMutationRegistryProvider);
            case 'runtime':
              m.container.invalidate(supportNativeRuntimeProvider);
            case 'controller':
              m.container.invalidate(supportNativeConsentControllerProvider);
            case 'model':
              m.container.invalidate(supportModelUiBridgeProvider);
          }
          final nextBridge = m.bridge;
          await m.container.pump();
          expect(nextBridge, isNotNull);
          expect(preview.isCurrent, isFalse);
          expect(send.approve(preview), isNull);
          settle();
          expect((await send.finished).saved, isTrue);
          if (replacement == 'registry' || replacement == 'runtime') {
            expect(oldRuntime.alive, isFalse);
            final epoch = oldRuntime.epoch;
            oldRegistry.beginMutation(
              sessionId: GameSourceNativeFixture.game,
            )();
            expect(oldRuntime.epoch, epoch);
          }
          expect(m.adapters, isEmpty);
        });
      },
    );
  }

  test(
    'notify reentry settles nested source and selects away without leaking pending',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final runtime = f.runtime;
        final old = f.model.emitter();
        var entered = false;
        final stop = runtime.listen(() {
          if (entered || runtime.pending == 0) return;
          entered = true;
          f.begin(messageIds: {GameSourceNativeFixture.selected})();
          runtime.selectSession(ModelProviderFixture.otherSession);
        });
        final settle = f.begin();
        stop();
        expect(entered, isTrue);
        expect(runtime.pending, 0);
        expect(old.isCurrent, isFalse);
        settle();
        expect(runtime.pending, 0);
        expect(f.model.adapters, isEmpty);
      });
    },
  );

  test(
    'unsubscribe/dispose during notification leaves old observer inert and other pending owned',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final runtime = f.runtime;
        runtime.pending += 2;
        var retired = false;
        runtime.listen(() {
          if (retired) return;
          retired = true;
          f.model.container.invalidate(supportNativeRuntimeProvider);
          f.model.bridge;
        });
        final settle = f.begin();
        expect(runtime.alive, isFalse);
        expect(runtime.pending, 2);
        final epoch = runtime.epoch;
        settle();
        expect(runtime.epoch, epoch);
        expect(runtime.pending, 2);
      });
    },
  );

  for (final selection in ['absent', 'local-only', 'model-off']) {
    test(
      '$selection does not trigger history/HTTP/body loads from observation',
      () async {
        await GameSourceNativeFixture().run((f) async {
          if (selection != 'absent') {
            await f.seedGame(
              grantModel: false,
              confirm: selection != 'model-off',
            );
          }
          final m = f.model;
          m.sql.observations.clear();
          m.primitive.decryptAads.clear();
          final settle = f.begin();
          expect(m.sql.observations, isEmpty);
          expect(m.primitive.decryptAads, isEmpty);
          expect(m.adapters, isEmpty);
          expect(f.runtime.pending, selection == 'absent' ? 0 : 1);
          settle();
          f.expectNoSourceReads();
          expect(m.adapters, isEmpty);
        }, configured: selection != 'model-off');
      },
    );
  }

  test(
    'matching source pending does not suppress original queued settings recipient clear',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final settle = f.begin();
        expect(f.runtime.pending, 1);
        expect(await f.model.workspace.setTemperature(0.4), isTrue);
        expect(f.runtime.settingsPending, 0);
        expect(f.runtime.pending, 1);
        expect(
          (await f.runtime.permissions.readForNative(
            ModelProviderFixture.session,
          )).preferences!.recipient,
          isNull,
          reason:
              'Independent settings finally must still clear saved recipient.',
        );
        expect(f.runtime.recipientConfirmed, isFalse);
        settle();
        expect(f.runtime.pending, 0);
        expect(f.model.adapters, isEmpty);
      });
    },
  );

  test(
    'unrelated source preserves actual independently queued native grant merge',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final controller = m.container.read(
          supportNativeConsentControllerProvider,
        );
        final review = (await controller.prepareReview())!;
        final barrier = m.barrier();
        var held = false;
        m.primitive.afterEncrypt = (aad) async {
          if (!held && aad.contains('workspace-permissions-v1')) {
            held = true;
            await barrier.wait();
          }
        };
        final first = controller.setGrant(
          review,
          SupportPermission.readGameData,
          false,
        );
        await barrier.entered.future;
        final settle = f.begin(messageIds: {'source-excluded'});
        final second = controller.setGrant(
          review,
          SupportPermission.reportGameHistory,
          true,
        );
        expect(f.runtime.pending, 2);
        expect(f.runtime.recipientConfirmed, isTrue);
        barrier.release();
        expect(await first, isTrue);
        expect(await second, isTrue);
        settle();
        expect(f.runtime.pending, 0);
        expect(f.runtime.recipientConfirmed, isTrue);
        expect(
          f.runtime.snapshot.preferences!.allows(
            SupportPermission.readGameData,
          ),
          isFalse,
        );
        expect(
          f.runtime.snapshot.preferences!.allows(
            SupportPermission.reportGameHistory,
          ),
          isTrue,
        );
        expect(
          f.runtime.snapshot.preferences!.allows(
            SupportPermission.modelGameHistory,
          ),
          isTrue,
        );
        expect(m.adapters, isEmpty);
      });
    },
  );

  test(
    'ordinary neutral mutations with no assistant observer start ZERO assistant providers/reads/HTTP',
    () async {
      await GameSourceNativeFixture().run((f) async {
        final m = f.model;
        // Override graph is installed but neither native/model nor DB is evaluated.
        f.begin()();
        f.begin(messageIds: {GameSourceNativeFixture.selected})();
        expect(m.container.exists(supportNativeRuntimeProvider), isFalse);
        expect(
          m.container.exists(supportNativeConsentControllerProvider),
          isFalse,
        );
        expect(m.container.exists(supportModelUiBridgeProvider), isFalse);
        expect(m.container.exists(supportNativeViewProvider), isFalse);
        expect(m.container.exists(supportModelRunViewProvider), isFalse);
        expect(m.container.exists(supportWorkspaceProvider), isFalse);
        expect(m.container.exists(supportModelDurableWritesProvider), isFalse);
        expect(
          m.container.exists(supportModelPrivateAdapterFactoryProvider),
          isFalse,
        );
        expect(m.container.exists(appDbProvider), isFalse);
        expect(m.container.exists(credentialVaultProvider), isFalse);
        expect(m.container.exists(apiConfigRepoProvider), isFalse);
        expect(m.container.exists(secretRedactorProvider), isFalse);
        expect(m.sql.observations, isEmpty);
        expect(m.primitive.decryptAads, isEmpty);
        expect(m.adapters, isEmpty);
      }, initialize: false);
    },
  );

  test(
    'source pending denies native authorization but local/model/report rights remain independent',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame(grantModel: false);
        final runtime = f.runtime;
        await runtime.permissions.setGrantFromNative(
          ModelProviderFixture.session,
          SupportPermission.readGameData,
          true,
          isCurrent: () => true,
        );
        await runtime.refresh();
        final grants = runtime.snapshot.preferences!.grants;
        expect(grants, contains(SupportPermission.readGameData));
        expect(grants, isNot(contains(SupportPermission.modelGameHistory)));
        expect(grants, isNot(contains(SupportPermission.reportGameHistory)));
        final settle = f.begin();
        expect(
          await runtime.authorization.prepare(
            supportSessionId: ModelProviderFixture.session,
            use: SupportPermissionUse.localRead,
            sources: [
              SupportPermissionSource.gameHistory(
                ModelProviderFixture.session,
                GameSourceNativeFixture.game,
                SupportMessageSelection([GameSourceNativeFixture.selected]),
              ),
            ],
          ),
          isNull,
        );
        settle();
        expect(runtime.snapshot.preferences!.grants, grants);
        expect(runtime.recipientConfirmed, isTrue);
      });
    },
  );
}
