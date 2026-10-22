import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_authorization_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'helpers/support_native_fixture.dart';

void main() {
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  Future<SupportAuthorizationLease?> prepare(SupportPermissionUse use) =>
      f.runtime.authorization.prepare(
        supportSessionId: NativeFixture.id,
        use: use,
        sources: [
          SupportPermissionSource.safeProjection(
            NativeFixture.id,
            SupportSafeCategory.connections,
          ),
        ],
      );

  test(
    'fresh native lease denies before loader while durable revoke waits',
    () async {
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      final current = (await f.controller.prepareReview())!;
      final old = (await prepare(SupportPermissionUse.localRead))!;
      f.database.repoA.pauseAdmission();
      final revoke = f.controller.setGrant(
        current,
        SupportPermission.readSafeSettings,
        false,
      );
      await f.database.repoA.entered!.future;
      var loads = 0;
      try {
        expect(f.runtime.pending, 1);
        expect(
          (await f.database.b.readForNative(
            NativeFixture.id,
          )).preferences!.allows(SupportPermission.readSafeSettings),
          isTrue,
        );
        await expectLater(
          f.runtime.authorization.loadLocal(old, () async => ++loads),
          throwsA(isA<SupportAuthorizationDenied>()),
        );
        final fresh = await prepare(SupportPermissionUse.localRead);
        if (fresh != null) {
          await f.runtime.authorization.loadLocal(fresh, () async => ++loads);
        }
        expect(loads, 0);
        expect(fresh, isNull);
      } finally {
        f.database.repoA.release!.complete();
        expect(await revoke, isTrue);
      }
    },
  );

  test(
    'fresh lease cannot read old scope while native selection is queued',
    () async {
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      f.database.repoA.pauseAdmission();
      final selection = f.controller.selectConnections(
        (await f.controller.prepareReview())!,
        false,
      );
      await f.database.repoA.entered!.future;
      try {
        expect(f.runtime.pending, 1);
        expect(
          (await f.database.b.readForNative(
            NativeFixture.id,
          )).preferences!.scope!.safeCategories,
          contains(SupportSafeCategory.connections),
        );
        expect(await prepare(SupportPermissionUse.localRead), isNull);
        expect(await prepare(SupportPermissionUse.reportPreparation), isNull);
        expect(f.selectedLoads, 0);
      } finally {
        f.database.repoA.release!.complete();
        expect(await selection, isTrue);
      }
      expect(await prepare(SupportPermissionUse.localRead), isNull);
    },
  );

  test(
    'new native lifetime cannot hydrate model lease but local/report remain independent',
    () async {
      expect(
        await f.controller.confirmRecipient(
          (await f.controller.prepareReview())!,
        ),
        isTrue,
      );
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
        ),
        isTrue,
      );
      expect(await prepare(SupportPermissionUse.modelContext), isNotNull);
      f.runtime.selectSession(NativeFixture.id, force: true);
      expect(await f.controller.prepareReview(), isNotNull);
      expect(f.runtime.recipientConfirmed, isFalse);
      expect(await prepare(SupportPermissionUse.localRead), isNotNull);
      expect(await prepare(SupportPermissionUse.reportPreparation), isNotNull);
      expect(await prepare(SupportPermissionUse.modelContext), isNull);
    },
  );

  for (final loss in ['settings', 'configuration', 'dispose']) {
    test(
      'fresh leases and current consume deny during $loss before loader or publication',
      () async {
        final review = (await f.controller.prepareReview())!;
        expect(
          await f.controller.setGrant(
            review,
            SupportPermission.readSafeSettings,
            true,
          ),
          isTrue,
        );
        final old = (await prepare(SupportPermissionUse.localRead))!;
        final data = await f.runtime.authorization.loadLocal(
          old,
          () async => 'STATIC_SAFE_DTO',
        );
        void Function()? settle;
        switch (loss) {
          case 'settings':
            settle = f.runtime.beginSettingsChange();
          case 'configuration':
            settle = f.revisions.beginMutation();
          case 'dispose':
            f.runtime.dispose();
        }
        var loads = 0, consumed = 0;
        expect(await prepare(SupportPermissionUse.localRead), isNull);
        expect(await prepare(SupportPermissionUse.reportPreparation), isNull);
        await expectLater(
          f.runtime.authorization.loadLocal(old, () async => ++loads),
          throwsA(isA<SupportAuthorizationDenied>()),
        );
        await expectLater(
          f.runtime.authorization.consume(old, data, (_) => consumed++),
          throwsA(isA<SupportAuthorizationDenied>()),
        );
        expect(loads, 0);
        expect(consumed, 0);
        settle?.call();
        if (loss != 'dispose') {
          expect(await prepare(SupportPermissionUse.localRead), isNotNull);
          expect(
            await prepare(SupportPermissionUse.reportPreparation),
            isNotNull,
          );
        }
      },
    );
  }

  test(
    'authorization preparation rechecks admission after real encrypted policy await',
    () async {
      expect(
        await f.controller.setGrant(
          (await f.controller.prepareReview())!,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.database.primitive.beforeDecrypt = (_) async {
        if (!paused) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final preparing = prepare(SupportPermissionUse.localRead);
      await entered.future;
      final settle = f.runtime.beginSettingsChange();
      release.complete();
      expect(await preparing, isNull);
      settle();
    },
  );

  test(
    'late loader result cannot wrap or consume after native pending revoke',
    () async {
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      final current = (await f.controller.prepareReview())!;
      final lease = (await prepare(SupportPermissionUse.localRead))!;
      final data = await f.runtime.authorization.loadLocal(
        lease,
        () async => 'STATIC_SAFE_DTO',
      );
      final entered = Completer<void>(), release = Completer<void>();
      final loading = f.runtime.authorization.loadLocal(lease, () async {
        entered.complete();
        await release.future;
        return 'STATIC_LATE_SAFE_DTO';
      });
      await entered.future;
      f.database.repoA.pauseAdmission();
      final revoke = f.controller.setGrant(
        current,
        SupportPermission.readSafeSettings,
        false,
      );
      await f.database.repoA.entered!.future;
      try {
        release.complete();
        await expectLater(loading, throwsA(isA<SupportAuthorizationDenied>()));
        var transformations = 0, consumed = 0;
        await expectLater(
          f.runtime.authorization.wrapLocal(
            lease,
            data,
            SupportProvenanceWrapper.summary,
            (_) => ++transformations,
          ),
          throwsA(isA<SupportAuthorizationDenied>()),
        );
        await expectLater(
          f.runtime.authorization.consume(lease, data, (_) => consumed++),
          throwsA(isA<SupportAuthorizationDenied>()),
        );
        expect(transformations, 0);
        expect(consumed, 0);
      } finally {
        f.database.repoA.release!.complete();
        expect(await revoke, isTrue);
      }
    },
  );

  test(
    'confirmed flag alone cannot authorize unavailable or mismatched current model descriptor',
    () async {
      expect(
        await f.controller.confirmRecipient(
          (await f.controller.prepareReview())!,
        ),
        isTrue,
      );
      final review = (await f.controller.prepareReview())!;
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.readSafeSettings,
          true,
        ),
        isTrue,
      );
      expect(
        await f.controller.setGrant(
          review,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
        ),
        isTrue,
      );
      final resolved = f.runtime.recipient as SupportResolvedRecipient;
      f.runtime.recipient = const SupportRecipientUnavailable(
        SupportRecipientUnavailableReason.staleContext,
      );
      expect(f.runtime.recipientConfirmed, isTrue);
      expect(await prepare(SupportPermissionUse.modelContext), isNull);
      expect(await prepare(SupportPermissionUse.localRead), isNotNull);
      expect(await prepare(SupportPermissionUse.reportPreparation), isNotNull);
      f.runtime.recipient = SupportResolvedRecipient(
        context: SupportRecipientContext(
          supportSessionId: NativeFixture.id,
          epoch: resolved.context.epoch - 1,
        ),
        recipient: resolved.recipient,
        connectionLabel: resolved.connectionLabel,
        protocolLabel: resolved.protocolLabel,
        routingLabel: resolved.routingLabel,
        originLabel: resolved.originLabel,
        operationLabel: resolved.operationLabel,
      );
      expect(await prepare(SupportPermissionUse.modelContext), isNull);
      f.runtime.recipient = SupportResolvedRecipient(
        context: resolved.context,
        recipient: SupportPermissionRecipient(
          connectionId: resolved.recipient.connectionId,
          modelId: 'different-current-model',
          protocol: resolved.recipient.protocol,
          nativeRoute: resolved.recipient.nativeRoute,
          configurationRevision: resolved.recipient.configurationRevision,
        ),
        connectionLabel: resolved.connectionLabel,
        protocolLabel: resolved.protocolLabel,
        routingLabel: resolved.routingLabel,
        originLabel: resolved.originLabel,
        operationLabel: resolved.operationLabel,
      );
      expect(await prepare(SupportPermissionUse.modelContext), isNull);
      f.runtime.recipient = resolved;
      expect(await prepare(SupportPermissionUse.modelContext), isNotNull);
    },
  );
}
