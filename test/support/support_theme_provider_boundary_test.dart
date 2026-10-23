import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  themeProviderTest(
    'actual providers Apply and fresh Undo once, zero recipient/API',
    (f) async {
      expect(f.runtime.snapshot.preferences!.recipient, isNull);
      final intent = f.emit()!;
      final review = await f.review(intent);
      expect(f.harness.store.checkedWrites, isEmpty);
      final originalService = f.binding.service;
      final job = f.confirm(intent, review);
      expect(f.binding.busy, isTrue);
      expect(f.runtime.pending, 0);
      expect(intent.confirm(review), isNull);
      final applied = await job;
      expect(applied.effect, SupportThemeEffect.applied);
      expect(applied.journal, SupportThemeJournalSave.settled);
      expect(applied.status, SupportMutationStatus.applied);
      expect(f.binding.service, same(originalService));
      expect(f.binding.busy, isFalse);
      expect(f.backing.activeId, 'b');
      final saved = (await f.repo.getMutationsForSession(
        ThemeProviderFixture.session,
      )).single;
      final undoIntent = f.emit()!;
      final undoReview = (await undoIntent.prepareLastUndo())!;
      expect(undoIntent.preview(undoReview)!.kind, SupportThemeActionKind.undo);
      final undone = await f.confirm(undoIntent, undoReview);
      expect(undone.effect, SupportThemeEffect.undone);
      expect(undone.status, SupportMutationStatus.undone);
      expect(undoIntent.confirm(undoReview), isNull);
      expect(await f.emit()!.prepareLastUndo(), isNull);
      expect(f.harness.store.checkedWrites, ['b', 'a']);
      final finalRow = (await f.repo.getMutationsForSession(
        ThemeProviderFixture.session,
      )).single;
      expect(finalRow.beforeJson, saved.beforeJson);
      expect(finalRow.afterJson, saved.afterJson);
      expect(finalRow.createdAt, saved.createdAt);
    },
  );

  for (final right in [
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  ]) {
    themeProviderTest('actual native denial of ${right.name}', (f) async {
      final review = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      expect(await f.controller.setGrant(review, right, false), isTrue);
      if (right == SupportPermission.readSafeSettings) {
        final reads = f.harness.store.freshReads;
        expect(f.emit(), isNull);
        expect(f.harness.store.freshReads, reads);
      } else {
        final intent = f.emit()!;
        final observation = (await intent.observe())!;
        expect(
          await intent.prepareApply(
            intent.installed(observation)!.choices.last,
          ),
          isNull,
        );
      }
      expect(f.harness.store.checkedWrites, isEmpty);
    });
  }
  themeProviderTest('actual C category removal denies before theme storage', (
    f,
  ) async {
    final review = (await f.controller.prepareReview(resolveRecipient: false))!;
    expect(await f.controller.selectTheme(review, false), isTrue);
    final reads = f.harness.store.freshReads;
    expect(f.emit(), isNull);
    expect(f.harness.store.freshReads, reads);
    expect(f.harness.store.checkedWrites, isEmpty);
  });

  for (final boundary in ['ui', 'issuer', 'controller', 'sessionABA']) {
    themeProviderTest(
      'emitted $boundary retirement cannot transplant approval',
      (f) async {
        final original = f.emit()!;
        final review = await f.review(original);
        switch (boundary) {
          case 'ui':
            f.uiLifetime = Object();
          case 'issuer':
            f.controller.invalidateDisplayedIntents();
          case 'controller':
            f.container.invalidate(supportNativeConsentControllerProvider);
            f.binding;
          case 'sessionABA':
            f.workspace.selectSession(ThemeProviderFixture.other);
            f.workspace.selectSession(ThemeProviderFixture.session);
            await f.workspace.refresh();
            await f.runtime.refresh(resolve: false);
        }
        expect(original.confirm(review), isNull);
        expect(f.harness.store.checkedWrites, isEmpty);
        final fresh = f.emit()!;
        expect(fresh.confirm(review), isNull);
        expect(
          (await f.confirm(fresh, await f.review(fresh))).effect,
          SupportThemeEffect.applied,
        );
      },
    );
  }
  themeProviderTest(
    'same-service foreign UI observation/choice/review stays original',
    (f) async {
      final a = f.emit()!, b = f.emit()!;
      final observation = (await a.observe())!;
      expect(b.installed(observation), isNull);
      final choice = a.installed(observation)!.choices.last;
      expect(await b.prepareApply(choice), isNull);
      final review = (await a.prepareApply(choice))!;
      expect(b.preview(review), isNull);
      expect(b.confirm(review), isNull);
      expect(f.harness.store.checkedWrites, isEmpty);
    },
  );
  themeProviderTest(
    'retained labels reproject coordinator change; approval not renewed',
    (f) async {
      const label = 'SYNTHETIC_PROVIDER_THEME_LABEL';
      await f.harness.notifier.importPreset(
        f.backing.presets[1].copyWith(name: label),
      );
      final intent = f.emit()!;
      final observation = (await intent.observe())!;
      final choice = intent
          .installed(observation)!
          .choices
          .singleWhere((c) => c.value!.id == 'b');
      final review = (await intent.prepareApply(choice))!;
      expect(choice.value!.name, label);
      final signals = f.presentations.length;
      f.redaction.registerSecret(label);
      expect(choice.value!.name, SecretRedactor.removed);
      expect(intent.preview(review)!.after.name, SecretRedactor.removed);
      expect(f.presentations.length, greaterThan(signals));
      expect(intent.confirm(review), isNull);
      final revoke = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      expect(
        await f.controller.setGrant(
          revoke,
          SupportPermission.readSafeSettings,
          false,
        ),
        isTrue,
      );
      expect(choice.value, isNull);
      expect(intent.installed(observation), isNull);
      expect(intent.preview(review), isNull);
    },
  );
  themeProviderTest(
    'legacy strings and automatic local theme topic are non-executing',
    (f) async {
      expect(await f.workspace.applyMutationPlan('b'), isFalse);
      expect(await f.workspace.rollbackMutation('success-shaped-id'), isFalse);
      expect(await f.workspace.triggerQuickAction('theme_setup'), isTrue);
      expect(f.harness.store.checkedWrites, isEmpty);
      expect(
        await f.repo.getMutationsForSession(ThemeProviderFixture.session),
        isEmpty,
      );
    },
  );
  themeProviderTest(
    'forged C emitted anchor refuses before theme/API loading',
    (f) async {
      final reads = f.harness.store.freshReads;
      expect(
        f.binding.emit(
          displayedIntent: _ForgedAnchor(),
          uiLifetime: Object(),
          isUiCurrent: () => true,
        ),
        isNull,
      );
      expect(f.harness.store.freshReads, reads);
      expect(f.harness.store.checkedWrites, isEmpty);
    },
  );
  themeProviderTest(
    'synchronous owner-predicate reentry cannot consume final review twice',
    (f) async {
      late final SupportThemeUiIntent intent;
      late final SupportThemeReview review;
      var reenter = false, entered = false;
      intent = f.binding.emit(
        displayedIntent: f.controller.view.displayedIntent!,
        uiLifetime: Object(),
        isUiCurrent: () {
          if (reenter && !entered) {
            entered = true;
            expect(intent.confirm(review), isNull);
          }
          return true;
        },
      )!;
      review = await f.review(intent);
      reenter = true;
      expect(
        (await f.confirm(intent, review)).effect,
        SupportThemeEffect.applied,
      );
      expect(entered, isTrue);
      expect(f.harness.store.checkedWrites, ['b']);
    },
  );
}

final class _ForgedAnchor implements SupportNativeDisplayedIntent {}
