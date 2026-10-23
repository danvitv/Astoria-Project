import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';

import 'helpers/support_native_fixture.dart';

void main() {
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
    final review = (await f.controller.prepareReview(resolveRecipient: false))!;
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
        SupportPermission.confirmedSettingsChanges,
        true,
      ),
      isTrue,
    );
    f.api.ids.clear();
    f.settingsReads = 0;
  });
  tearDown(() => f.close());

  test(
    'local anchor excludes own native configuration and recipient epoch',
    () {
      final context = f.runtime.localContext;
      final intent = f.controller.captureLocalDisplayedIntent()!;
      final oldGlobal = f.runtime.epoch;
      final finish = f.revisions.beginMutation();
      f.runtime.checkConfiguration();
      expect(f.runtime.epoch, greaterThan(oldGlobal));
      expect(f.runtime.localContext.sameAs(context), isTrue);
      expect(f.runtime.localActionsAvailable, isTrue);
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isTrue);
      finish();
      f.runtime.checkConfiguration();
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isTrue);
      expect(context.recipient, isNull);
      expect(f.api.ids, isEmpty);
      expect(f.settingsReads, 0);
      expect(f.selectedLoads, 0);
    },
  );

  for (final right in [
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  ]) {
    test('$right fences before admission through original finally', () async {
      final review = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      final intent = f.controller.captureLocalDisplayedIntent()!;
      final context = f.runtime.localContext;
      f.database.repoA.pauseAdmission();
      final job = f.controller.setGrant(review, right, false);
      try {
        expect(f.runtime.localActionsAvailable, isFalse);
        expect(f.runtime.localContext.sameAs(context), isFalse);
        expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
        await f.database.repoA.entered!.future;
      } finally {
        f.database.repoA.release!.complete();
        expect(await job, isTrue);
      }
      expect(f.runtime.localActionsAvailable, isTrue);
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
      expect(
        f.runtime.localPermissionSnapshot.preferences?.allows(right),
        isFalse,
      );
    });
  }

  test(
    'scope change fences before binding and does not resurrect anchor',
    () async {
      final review = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      final intent = f.controller.captureLocalDisplayedIntent()!;
      f.database.repoA.pauseAdmission();
      final job = f.controller.selectConnections(review, false);
      try {
        expect(f.runtime.localActionsAvailable, isFalse);
        expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
        await f.database.repoA.entered!.future;
      } finally {
        f.database.repoA.release!.complete();
        expect(await job, isTrue);
      }
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
      expect(
        f.runtime.localPermissionSnapshot.preferences?.allows(
          SupportPermission.readSafeSettings,
        ),
        isFalse,
      );
    },
  );

  test(
    'recipient confirmation and model-only queued toggle do not retire local',
    () async {
      final context = f.runtime.localContext;
      final intent = f.controller.captureLocalDisplayedIntent()!;
      final review = (await f.controller.prepareReview())!;
      expect(await f.controller.confirmRecipient(review), isTrue);
      expect(f.runtime.localContext.sameAs(context), isTrue);
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isTrue);
      final modelReview = (await f.controller.prepareReview())!;
      f.database.repoA.pauseAdmission();
      final job = f.controller.setGrant(
        modelReview,
        SupportPermission.modelSupportHistory,
        true,
      );
      try {
        await f.database.repoA.entered!.future;
        expect(f.runtime.localActionsAvailable, isTrue);
        expect(f.runtime.localContext.sameAs(context), isTrue);
        expect(f.controller.isLocalDisplayedIntentCurrent(intent), isTrue);
      } finally {
        f.database.repoA.release!.complete();
        expect(await job, isTrue);
      }
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isTrue);
    },
  );

  test(
    'fresh durable local revocation is reconciled without recipient load',
    () async {
      final intent = f.controller.captureLocalDisplayedIntent()!;
      await f.database.b.setGrantFromNative(
        NativeFixture.id,
        SupportPermission.readSafeSettings,
        false,
        isCurrent: () => true,
      );
      expect(await f.runtime.refresh(), isTrue);
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
      expect(f.api.ids, isEmpty);
      expect(f.settingsReads, 0);
      expect(f.selectedLoads, 0);
    },
  );

  test(
    'session ABA and foreign controller cannot transplant local anchor',
    () async {
      final intent = f.controller.captureLocalDisplayedIntent()!;
      final other = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      expect(other.isLocalDisplayedIntentCurrent(intent), isFalse);
      final finishOld = f.runtime.beginLocalPermissionChange();
      f.runtime.selectSession('replacement');
      f.runtime.selectSession(NativeFixture.id);
      await f.runtime.refresh();
      finishOld();
      finishOld();
      expect(f.runtime.localActionsAvailable, isTrue);
      expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
      expect(f.controller.captureLocalDisplayedIntent(), isNotNull);
    },
  );

  test('issuer retirement, pending nesting and disposal stay deny-only', () {
    final intent = f.controller.captureLocalDisplayedIntent()!;
    f.controller.invalidateDisplayedIntents();
    expect(f.controller.isLocalDisplayedIntentCurrent(intent), isFalse);
    final first = f.runtime.beginLocalPermissionChange();
    final second = f.runtime.beginLocalPermissionChange();
    first();
    first();
    expect(f.runtime.localActionsAvailable, isFalse);
    second();
    expect(f.runtime.localActionsAvailable, isTrue);
    f.runtime.dispose();
    expect(f.runtime.localPermissionSnapshot.isAvailable, isFalse);
    expect(f.controller.captureLocalDisplayedIntent(), isNull);
  });
}
