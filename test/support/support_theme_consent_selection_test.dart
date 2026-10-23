import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'support_theme_consent_fixture.dart';
import 'support_theme_consent_isolation.dart';

void main() {
  themeConsentTest(
    'theme and connections toggle independently preserving exact histories',
    (f) async {
      Future<void> check(Set<SupportSafeCategory> expected) async {
        final policy = await f.policy();
        expect(policy.scope!.safeCategories, expected);
        expect(policy.scope!.gameSessionId, 'synthetic-game');
        expect(policy.scope!.gameHistory!.messageIds, ['game-a', 'game-c']);
        expect(policy.scope!.supportHistory!.messageIds, ['support-a']);
        expect(policy.scope!.selectedData, isEmpty);
        expect(policy.grants, isEmpty);
        expect(policy.recipient, isNull);
      }

      var revision = (await f.policy()).scope!.selectionRevision;
      expect(await f.controller.selectTheme(await f.review(), true), true);
      await check({SupportSafeCategory.connections, SupportSafeCategory.theme});
      expect((await f.policy()).scope!.selectionRevision, ++revision);
      expect(
        await f.controller.selectConnections(await f.review(), false),
        true,
      );
      await check({SupportSafeCategory.theme});
      expect((await f.policy()).scope!.selectionRevision, ++revision);
      expect(
        await f.controller.selectConnections(await f.review(), true),
        true,
      );
      await check({SupportSafeCategory.connections, SupportSafeCategory.theme});
      expect(await f.controller.selectTheme(await f.review(), false), true);
      await check({SupportSafeCategory.connections});
      expect(await f.controller.selectTheme(await f.review(), true), true);
      await check({SupportSafeCategory.connections, SupportSafeCategory.theme});
      expect(f.resolverReads, 0);
      expect(f.settingsReads, 0);
      expect(f.apiReads, 0);
      expect(f.metadataReads, 0);
    },
    scope: ThemeConsentFixture.scope(
      categories: SupportSafeCategory.values,
      histories: true,
      selectedData: {
        SupportDataCategory.attachment: ['synthetic-attachment'],
      },
    ),
  );

  for (final theme in [false, true]) {
    themeConsentTest(
      'actual metadata history edits preserve both categories; theme=$theme',
      (f) async {
        f.allowMetadata = true;
        final choice = (await f.controller.prepareMessages(
          await f.review(),
          SupportConsentSelectionSource.support,
          ThemeConsentFixture.id,
        ))!;
        expect(choice.page.items.map((m) => m.messageId), [
          'support-a',
          'support-b',
          'support-c',
        ]);
        expect(choice.page.bodiesRead, false);
        expect(choice.page.attachmentsIncluded, false);
        expect(
          await f.controller.selectMessages(choice, ['support-c', 'support-a']),
          true,
        );
        var policy = await f.policy();
        expect(policy.scope!.supportHistory!.messageIds, [
          'support-a',
          'support-c',
        ]);
        expect(policy.scope!.gameHistory!.messageIds, ['game-a', 'game-c']);
        expect(policy.scope!.safeCategories, {
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
        });
        expect(policy.scope!.selectedData, isEmpty);
        expect(policy.grants, isEmpty);
        final empty = (await f.controller.prepareMessages(
          await f.review(),
          SupportConsentSelectionSource.support,
          ThemeConsentFixture.id,
        ))!;
        expect(await f.controller.selectMessages(empty, []), true);
        policy = await f.policy();
        expect(policy.scope!.supportHistory, isNull);
        expect(policy.scope!.gameHistory!.messageIds, ['game-a', 'game-c']);
        expect(policy.scope!.safeCategories, {
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
        });
        expect(f.metadataReads, 4);
        expect(f.resolverReads, 0);
        expect(f.settingsReads, 0);
        expect(f.apiReads, 0);
        expect(
          f.primitive.decryptAads.any((a) => a.contains('support_messages')),
          false,
        );
      },
      scope: ThemeConsentFixture.scope(
        histories: true,
        categories: [
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
          SupportSafeCategory.studioPresets,
        ],
        selectedData: {
          SupportDataCategory.character: ['synthetic-character'],
        },
      ),
    );
  }

  for (final theme in [false, true]) {
    themeConsentTest(
      'actual roleplay metadata edits preserve theme and exact support history; theme=$theme',
      (f) async {
        f.allowMetadata = true;
        final choice = (await f.controller.prepareMessages(
          await f.review(),
          SupportConsentSelectionSource.roleplay,
          'synthetic-game',
        ))!;
        expect(choice.page.items.map((m) => m.messageId), [
          'game-a',
          'game-b',
          'game-c',
        ]);
        expect(choice.page.bodiesRead, false);
        expect(
          await f.controller.selectMessages(choice, ['game-c', 'game-a']),
          true,
        );
        var policy = await f.policy();
        expect(policy.scope!.gameHistory!.messageIds, ['game-a', 'game-c']);
        expect(policy.scope!.supportHistory!.messageIds, ['support-a']);
        expect(policy.scope!.safeCategories, {
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
        });
        expect(policy.scope!.selectedData, isEmpty);
        final empty = (await f.controller.prepareMessages(
          await f.review(),
          SupportConsentSelectionSource.roleplay,
          'synthetic-game',
        ))!;
        expect(await f.controller.selectMessages(empty, []), true);
        policy = await f.policy();
        expect(policy.scope!.gameSessionId, 'synthetic-game');
        expect(policy.scope!.gameHistory, isNull);
        expect(policy.scope!.supportHistory!.messageIds, ['support-a']);
        expect(policy.scope!.safeCategories, {
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
        });
        expect(policy.grants, isEmpty);
        expect(f.resolverReads, 0);
        expect(f.settingsReads, 0);
        expect(f.apiReads, 0);
        expect(f.metadataReads, 4);
      },
      scope: ThemeConsentFixture.scope(
        histories: true,
        categories: [
          SupportSafeCategory.connections,
          if (theme) SupportSafeCategory.theme,
        ],
      ),
    );
  }

  themeConsentTest(
    'retained metadata choice cannot remove newer theme scope',
    (f) async {
      f.allowMetadata = true;
      final review = await f.review();
      final choice = (await f.controller.prepareMessages(
        review,
        SupportConsentSelectionSource.support,
        ThemeConsentFixture.id,
      ))!;
      expect(await f.controller.selectTheme(review, true), true);
      final row = await f.row();
      final reads = f.metadataReads;
      expect(await f.controller.selectMessages(choice, ['support-a']), false);
      expect(f.metadataReads, reads);
      expect(await f.row(), row);
      expect((await f.policy()).scope!.safeCategories, {
        SupportSafeCategory.connections,
        SupportSafeCategory.theme,
      });
    },
    scope: ThemeConsentFixture.scope(
      categories: [SupportSafeCategory.connections],
    ),
  );

  themeConsentTest(
    'same-turn old category decision cannot cancel original admitted theme write',
    (f) async {
      final review = await f.review();
      final barrier = ThemeConsentBarrier();
      f.primitive.afterEncrypt = (aad) async {
        if (aad.endsWith('|protected_facts_ciphertext')) await barrier.wait();
      };
      final selecting = f.controller.selectTheme(review, true);
      try {
        await barrier.entered.future;
        expect(f.runtime.pending, 1);
        expect(await f.controller.selectConnections(review, true), false);
        expect(await f.controller.selectTheme(review, false), false);
      } finally {
        f.primitive.afterEncrypt = null;
        barrier.release();
      }
      expect(await selecting, true);
      expect((await f.policy()).scope!.safeCategories, {
        SupportSafeCategory.theme,
      });
      expect((await f.policy()).grants, isEmpty);
      expect(f.resolverReads, 0);
    },
  );
}
