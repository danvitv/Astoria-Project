import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/backup/backup_cancel.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_authorization_service.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'helpers/support_native_observer_fixture.dart';

void main() {
  late NativeObserverFixture f;
  setUp(() async {
    f = await NativeObserverFixture.create();
    await f.seed();
  });
  tearDown(() => f.close());
  SupportNativeRightView local(SupportNativeView view) => view.rights
      .firstWhere((v) => v.right == SupportPermission.readSafeSettings);

  test(
    'production shared API begin and settlement synchronously revoke without passive reads',
    () async {
      final seen = <SupportNativeView>[];
      final sub = f.container.listen(
        supportNativeViewProvider,
        (_, next) => seen.add(next),
      );
      addTearDown(sub.close);
      await f.grant(model: true);
      await f.inspect();
      expect(f.view.inspection, isNotNull);
      final old = (await f.prepare(SupportPermissionUse.localRead))!;
      final data = await f.runtime.authorization.loadLocal(
        old,
        () async => 'synthetic safe DTO',
      );
      final reads = f.settings.reads, revision = f.revisions.revision;
      final edit = f.api.put(
        NativeObserverFixture.original.copyWith(model: 'changed-model'),
      );
      expect(f.revisions.isStable, isFalse);
      expect(f.revisions.revision, revision + 1);
      expect(f.view.busy, isTrue);
      expect(f.view.availability, SupportPermissionAvailability.unavailable);
      expect(f.view.inspection, isNull);
      expect(local(f.view).available, isFalse);
      expect(f.view.needsRecipientConfirmation, isTrue);
      expect(f.settings.reads, reads);
      expect(seen.last.inspection, isNull);
      expect(await f.prepare(SupportPermissionUse.localRead), isNull);
      var consumed = 0;
      await expectLater(
        f.runtime.authorization.consume(old, data, (_) => consumed++),
        throwsA(isA<SupportAuthorizationDenied>()),
      );
      expect(consumed, 0);
      await edit;
      expect(f.revisions.isStable, isTrue);
      expect(f.view.busy, isFalse);
      expect(local(f.view).available, isTrue);
      expect(f.view.inspection, isNull);
      expect(f.view.recipient, isA<SupportRecipientUnavailable>());
      expect(f.settings.reads, reads);
      expect(await f.prepare(SupportPermissionUse.modelContext), isNull);
      expect(await f.prepare(SupportPermissionUse.localRead), isNotNull);
      expect(
        await f.prepare(SupportPermissionUse.reportPreparation),
        isNotNull,
      );
    },
  );

  test(
    'explicit review while registry pending is readonly and cannot write',
    () async {
      await f.grant();
      final settle = f.revisions.beginMutation();
      final review = (await f.controller.prepareReview())!;
      expect(review.view.busy, isTrue);
      expect(review.view.recipient, isA<SupportRecipientUnavailable>());
      expect(await f.controller.confirmRecipient(review), isFalse);
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          false,
        ),
        isFalse,
      );
      settle();
    },
  );

  test(
    'initial sample exposes current pending state and closed/reopened view follows settlement',
    () async {
      // Destroy only native composition; ordinary shared registry and API stay live.
      f.container.invalidate(supportNativeRuntimeProvider);
      final settle = f.revisions.beginMutation();
      final runtime = f.runtime;
      runtime.selectSession(NativeObserverFixture.id);
      expect(await runtime.refresh(), isTrue);
      var notifications = 0;
      var sub = f.container.listen(
        supportNativeViewProvider,
        (_, _) => notifications++,
      );
      expect(f.view.busy, isTrue);
      expect(local(f.view).available, isFalse);
      sub.close();
      settle();
      sub = f.container.listen(
        supportNativeViewProvider,
        (_, _) => notifications++,
      );
      addTearDown(sub.close);
      expect(f.view.busy, isFalse);
      expect(local(f.view).available, isTrue);
      final before = notifications;
      final nested = f.revisions.beginMutation();
      expect(notifications, greaterThan(before));
      expect(f.view.busy, isTrue);
      nested();
      expect(f.view.busy, isFalse);
    },
  );

  test(
    'actual root BackupService ABA never revives inspection or confirmed model authority',
    () async {
      final sub = f.container.listen(supportNativeViewProvider, (_, _) {});
      addTearDown(sub.close);
      await f.grant(model: true);
      await f.inspect();
      final oldRecipient = f.runtime.snapshot.preferences!.recipient!;
      final before = await f.imports.db
          .select(f.imports.db.supportMessages)
          .get();
      final service = await f.backup;
      final reads = f.settings.reads;
      for (final endpoint in [
        'https://changed.invalid/v1/chat/completions',
        NativeObserverFixture.original.endpoint,
      ]) {
        final zip = await f.imports.zip(
          tables: {
            'api_configs': [
              {
                'config_id': NativeObserverFixture.original.id,
                'name': 'Synthetic restored',
                'endpoint': endpoint,
                'api_key': NativeObserverFixture.original.apiKey,
                'model': NativeObserverFixture.original.model,
              },
            ],
          },
        );
        final pending = service.importBackupFromFile(zip);
        expect(f.revisions.isStable, isFalse);
        expect(f.view.busy, isTrue);
        expect(f.view.inspection, isNull);
        expect(await f.prepare(SupportPermissionUse.localRead), isNull);
        await pending;
        expect(f.view.busy, isFalse);
        expect(f.view.needsRecipientConfirmation, isTrue);
        expect(f.settings.reads, reads);
        expect(await f.prepare(SupportPermissionUse.modelContext), isNull);
      }
      final current = (await f.controller.prepareReview())!;
      final resolved = current.view.recipient as SupportResolvedRecipient;
      expect(resolved.recipient.nativeRoute, oldRecipient.nativeRoute);
      expect(resolved.recipient.sameAs(oldRecipient), isFalse);
      expect(await f.controller.confirmRecipient(current), isTrue);
      expect(
        await f.prepare(SupportPermissionUse.modelContext),
        isNull,
      ); // changed binding clears dependent grant
      expect(
        await f.imports.db.select(f.imports.db.supportMessages).get(),
        before,
      );
      expect(
        (await f.repo.getMessageById('observer-message'))!.body,
        'STATIC_ENCRYPTED_OBSERVER_HISTORY',
      );
    },
  );

  for (final outcome in ['failed', 'canceled', 'nested']) {
    test(
      'root import $outcome remains reactive until full settlement without automatic loads',
      () async {
        final sub = f.container.listen(supportNativeViewProvider, (_, _) {});
        addTearDown(sub.close);
        await f.grant();
        await f.inspect();
        final service = await f.backup;
        final reads = f.settings.reads;
        final path = outcome == 'failed'
            ? await f.imports.textFile('synthetic invalid backup')
            : await f.imports.zip();
        final entered = Completer<void>(), release = Completer<void>();
        if (outcome == 'nested') {
          f.imports.db.beforePurge = () {
            entered.complete();
            return release.future;
          };
        }
        final pending = service.importBackupFromFile(
          path,
          onDetected: outcome == 'canceled'
              ? (_) => service.cancelImport()
              : null,
        );
        expect(f.view.busy, isTrue);
        expect(f.view.inspection, isNull);
        if (outcome == 'failed') {
          await expectLater(pending, throwsA(isA<Exception>()));
        } else if (outcome == 'nested') {
          await entered.future;
          final settle = f.revisions.beginMutation();
          release.complete();
          await pending;
          expect(f.view.busy, isTrue);
          expect(local(f.view).available, isFalse);
          settle();
        } else {
          await expectLater(pending, throwsA(isA<ImportCancelledException>()));
        }
        expect(f.view.busy, isFalse);
        expect(f.view.inspection, isNull);
        expect(f.view.needsRecipientConfirmation, isTrue);
        expect(f.settings.reads, reads);
      },
    );
  }

  test(
    'registry disposal revokes current view; late ordinary API/import completion cannot revive it',
    () async {
      final sub = f.container.listen(supportNativeViewProvider, (_, _) {});
      addTearDown(sub.close);
      await f.grant();
      await f.inspect();
      final service = await f.backup;
      final entered = Completer<void>(), release = Completer<void>();
      f.imports.db.beforePurge = () {
        entered.complete();
        return release.future;
      };
      final import = service.importBackupFromFile(await f.imports.zip());
      await entered.future;
      final api = f.api;
      final write = api.put(
        NativeObserverFixture.original.copyWith(model: 'ordinary-admitted'),
      );
      f.revisions.dispose();
      expect(f.view.availability, SupportPermissionAvailability.unavailable);
      expect(local(f.view).available, isFalse);
      expect(f.view.inspection, isNull);
      release.complete();
      await Future.wait([import, write]);
      expect(f.revisions.isStable, isFalse);
      expect(
        (await api.getById(NativeObserverFixture.original.id))!.model,
        'ordinary-admitted',
      );
      expect(await f.prepare(SupportPermissionUse.localRead), isNull);
      expect(f.view.inspection, isNull);
    },
  );

  test(
    'runtime/view rebuild detaches old lifetime, idempotent teardown and fresh leases stay current',
    () async {
      final seen = <SupportNativeView>[];
      final sub = f.container.listen(
        supportNativeViewProvider,
        (_, next) => seen.add(next),
      );
      addTearDown(sub.close);
      await f.grant(model: true);
      await f.inspect();
      final old = f.runtime, oldController = f.controller;
      f.container.invalidate(supportNativeRuntimeProvider);
      await f.container.pump();
      expect(old.alive, isFalse);
      expect(old.inspection, isNull);
      expect(
        oldController.view.availability,
        SupportPermissionAvailability.unavailable,
      );
      expect(f.runtime, isNot(same(old)));
      f.runtime.selectSession(NativeObserverFixture.id);
      expect(await f.controller.prepareReview(), isNotNull);
      expect(f.view.needsRecipientConfirmation, isTrue);
      expect(await f.prepare(SupportPermissionUse.modelContext), isNull);
      expect(await f.prepare(SupportPermissionUse.localRead), isNotNull);
      final oldEpoch = old.epoch, currentEpoch = f.runtime.epoch;
      old.dispose();
      old.dispose();
      old.invalidateConfiguration();
      expect(old.epoch, oldEpoch);
      final settle = f.revisions.beginMutation();
      settle();
      expect(old.epoch, oldEpoch);
      expect(f.runtime.epoch, greaterThan(currentEpoch));
      expect(seen.last.inspection, isNull);
      expect(seen.last.sessionId, NativeObserverFixture.id);
    },
  );

  test(
    'native shutdown publishes only unavailable terminal snapshots and is idempotent',
    () async {
      await f.grant();
      await f.inspect();
      final terminal = <SupportNativeView>[];
      final sub = f.container.listen(
        supportNativeViewProvider,
        (_, next) => terminal.add(next),
      );
      addTearDown(sub.close);
      final runtime = f.runtime;
      runtime.dispose();
      expect(terminal, isNotEmpty);
      expect(
        terminal.every(
          (v) =>
              v.availability == SupportPermissionAvailability.unavailable &&
              v.inspection == null &&
              v.rights.every((r) => !r.available && !r.enabled),
        ),
        isTrue,
      );
      expect(f.view.inspection, isNull);
      expect(await f.prepare(SupportPermissionUse.localRead), isNull);
      final epoch = runtime.epoch, notifications = terminal.length;
      runtime.dispose();
      final settle = f.revisions.beginMutation();
      settle();
      expect(runtime.epoch, epoch);
      expect(terminal.length, notifications);
    },
  );

  test(
    'late selected settings completion cannot publish after API ABA or replacement owner',
    () async {
      final sub = f.container.listen(supportNativeViewProvider, (_, _) {});
      addTearDown(sub.close);
      await f.grant();
      final old = f.runtime;
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.settings.afterRead = () async {
        if (!paused) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final inspect = old.inspectSelectedConnection(
        NativeObserverFixture.id,
        () => true,
      );
      await entered.future;
      await f.api.put(
        NativeObserverFixture.original.copyWith(model: 'temporary'),
      );
      await f.api.put(NativeObserverFixture.original);
      f.container.invalidate(supportNativeRuntimeProvider);
      await f.container.pump();
      release.complete();
      expect(await inspect, isFalse);
      expect(old.inspection, isNull);
      expect(f.view.inspection, isNull);
    },
  );

  test(
    'consumer/container disposal cannot abort admitted ordinary writes even with throwing native observer',
    () async {
      await f.grant();
      final runtime = f.runtime, api = f.api, revisions = f.revisions;
      final credentialReads = f.storage.reads;
      runtime.listen(() => throw StateError('STATIC_OBSERVER_ERROR_CANARY'));
      final service = await f.backup;
      final entered = Completer<void>(), release = Completer<void>();
      f.imports.db.beforePurge = () {
        entered.complete();
        return release.future;
      };
      final import = service.importBackupFromFile(await f.imports.zip());
      await entered.future;
      final write = api.put(
        NativeObserverFixture.original.copyWith(model: 'after-consumer-close'),
      );
      f.container.dispose();
      expect(runtime.alive, isFalse);
      expect(runtime.inspection, isNull);
      final epoch = runtime.epoch;
      release.complete();
      await Future.wait([import, write]);
      expect(
        (await api.getById(NativeObserverFixture.original.id))!.model,
        'after-consumer-close',
      );
      expect(runtime.epoch, epoch);
      expect(revisions.isStable, isFalse);
      expect(f.storage.reads, credentialReads);
    },
  );
}
