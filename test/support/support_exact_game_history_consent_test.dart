import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'helpers/support_exact_history_consent_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

final class _ForgedIntent implements SupportNativeDisplayedIntent {}

SupportNativeRightView _local(SupportNativeView view) =>
    view.rights.firstWhere((v) => v.right == SupportPermission.readGameData);

Future<SupportNativeReview> _review(ExactHistoryConsentFixture f) async =>
    (await f.controller.prepareReview(
      displayedIntent: f.controller.view.displayedIntent,
    ))!;

Future<bool> _enable(ExactHistoryConsentFixture f, SupportNativeReview r) =>
    f.controller.setGrant(r, SupportPermission.readGameData, true);

Future<void> _confirmSyntheticRecipient(ExactHistoryConsentFixture f) async {
  await f.otherPermissions.selectRecipientFromNative(
    ExactHistoryConsentFixture.id,
    permissionRecipient(),
    isCurrent: () => true,
  );
  f.recipientAvailable = true;
  await f.runtime.refresh(resolve: true);
  expect(await f.controller.confirmRecipient(await _review(f)), isTrue);
}

// These are actual controller/store tests, not a second permission predicate.
// Tripwires surround construction, initialization, assertions AND cleanup.
void _isolated(
  String name,
  Future<void> Function(ExactHistoryConsentFixture f) body, {
  SupportPermissionScope? scope,
}) {
  test(name, () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channels = [
      SystemChannels.platform,
      MethodChannel('plugins.flutter.io/path_provider'),
      MethodChannel('plugins.flutter.io/shared_preferences'),
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    ];
    final attempts = <String>[];
    messenger.setMockMessageHandler('flutter/assets', (_) async {
      attempts.add('flutter/assets');
      throw StateError('Native consent test forbids asset bootstrap');
    });
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts.add('${channel.name}:${call.method}');
        throw StateError('Native consent test forbids platform resources');
      });
    }
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = ExactHistoryConsentFixture();
            try {
              await f.seed(scope: scope);
              await body(f);
            } finally {
              await f.close();
              expect(f.sql.forbiddenReads, isEmpty);
              expect(f.connectionLoads, 0);
            }
          },
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) {
                attempts.add('socket.connect');
                throw StateError('Native consent test forbids sockets');
              },
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
            attempts.add('socket.startConnect');
            throw StateError('Native consent test forbids sockets');
          },
        ),
        createHttpClient: (_) {
          attempts.add('http.client');
          throw StateError('Native consent test forbids HTTP');
        },
      );
    } finally {
      messenger.setMockMessageHandler('flutter/assets', null);
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      expect(attempts, isEmpty);
    }
  });
}

void main() {
  _isolated('empty game session ID cannot manufacture exact-history scope', (
    f,
  ) async {
    final bytes = await f.row();
    expect(
      () => SupportPermissionScope(
        selectionRevision: 1,
        gameSessionId: '',
        gameHistory: SupportMessageSelection(['game-a']),
      ),
      throwsStateError,
    );
    expect(_local(f.controller.view).available, isFalse);
    expect(await f.row(), bytes);
  });

  for (final companions in [false, true]) {
    _isolated(
      'exact history available without any recipient; companions=$companions; local grant is passive',
      (f) async {
        final displayed = f.controller.view;
        expect(displayed.needsRecipientConfirmation, isTrue);
        expect(displayed.gameMessageCount, 2);
        expect(displayed.supportMessageCount, companions ? 1 : 0);
        expect(_local(displayed).available, isTrue);
        expect(displayed.rights.every((v) => !v.enabled), isTrue);
        final r = await _review(f);
        final recipientReads = f.recipientReads;
        expect(_local(r.view).available, isTrue);
        expect(await _enable(f, r), isTrue);
        final p = await f.policy();
        expect(p.grants, {SupportPermission.readGameData});
        expect(p.recipient, isNull);
        expect(
          p.scope!.sameAs(
            ExactHistoryConsentFixture.exactScope(companions: companions),
          ),
          isTrue,
        );
        expect(_local(f.controller.view).enabled, isTrue);
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(
          f.recipientReads,
          recipientReads,
          reason: 'No recipient prerequisite on local enable',
        );
        expect(f.metadataReads, 0);
        expect(
          f.sql.gameReads,
          isEmpty,
          reason: 'Toggle never invokes the exact-history reader',
        );
        expect(f.runtime.inspection, isNull);
        final source = SupportPermissionSource.gameHistory(
          ExactHistoryConsentFixture.id,
          p.scope!.gameSessionId!,
          p.scope!.gameHistory!,
        );
        expect(source.allowedFor(p, SupportPermissionUse.localRead), isTrue);
        expect(
          source.allowedFor(p, SupportPermissionUse.modelContext),
          isFalse,
        );
        expect(
          source.allowedFor(p, SupportPermissionUse.reportPreparation),
          isFalse,
        );
      },
      scope: ExactHistoryConsentFixture.exactScope(companions: companions),
    );
  }

  final emptyScopes = <String, SupportPermissionScope?>{
    'no scope': null,
    'game ID without exact history': SupportPermissionScope(
      selectionRevision: 1,
      gameSessionId: ExactHistoryConsentFixture.gameId,
    ),
    'only support history and connection metadata': SupportPermissionScope(
      selectionRevision: 1,
      supportHistory: SupportMessageSelection(['support-a']),
      safeCategories: [SupportSafeCategory.connections],
    ),
  };
  for (final entry in emptyScopes.entries) {
    _isolated('strict default deny: ${entry.key}', (f) async {
      final r = await _review(f);
      final row = await f.row();
      expect(_local(f.controller.view).available, isFalse);
      expect(_local(r.view).available, isFalse);
      expect(await _enable(f, r), isFalse);
      expect(await f.row(), row);
      expect((await f.policy()).grants, isEmpty);
      expect(f.metadataReads, 0);
      expect(f.sql.gameReads, isEmpty);
    }, scope: entry.value);
  }

  for (final category in SupportDataCategory.values) {
    for (final mixed in [false, true]) {
      final data = {
        category: ['synthetic-${category.name}'],
      };
      final scope = mixed
          ? ExactHistoryConsentFixture.exactScope(selectedData: data)
          : SupportPermissionScope(
              selectionRevision: 1,
              gameSessionId: ExactHistoryConsentFixture.gameId,
              selectedData: data,
              safeCategories: [SupportSafeCategory.diagnostics],
            );
      _isolated('strict deny ${category.name}, history mixed=$mixed', (
        f,
      ) async {
        await _confirmSyntheticRecipient(f);
        final r = await _review(f);
        final row = await f.row();
        final p = await f.policy();
        if (mixed ||
            {
              SupportDataCategory.character,
              SupportDataCategory.memory,
              SupportDataCategory.lore,
              SupportDataCategory.canon,
              SupportDataCategory.variables,
            }.contains(category)) {
          expect(
            p.hasScopeFor(SupportPermission.readGameData),
            isTrue,
            reason:
                'The generic policy stays broader than native implementation',
          );
        }
        expect(f.runtime.recipientConfirmed, isTrue);
        expect(_local(f.controller.view).available, isFalse);
        expect(_local(r.view).available, isFalse);
        expect(await _enable(f, r), isFalse);
        expect(await f.row(), row);
        expect((await f.policy()).grants, isEmpty);
        for (final right in [
          SupportPermission.readDiagnostics,
          SupportPermission.modelGameData,
          SupportPermission.modelPromptProviderSnippets,
          SupportPermission.modelAttachments,
          SupportPermission.reportPersonalDataAttachments,
        ]) {
          expect(
            r.view.rights.firstWhere((v) => v.right == right).available,
            isFalse,
          );
          expect(await f.controller.setGrant(r, right, true), isFalse);
        }
        expect(f.sql.gameReads, isEmpty);
      }, scope: scope);
    }
  }

  _isolated(
    'native picker saves exact ordered IDs, never loads bodies or grants rights',
    (f) async {
      final choice = (await f.controller.prepareMessages(
        await _review(f),
        SupportConsentSelectionSource.roleplay,
        ExactHistoryConsentFixture.gameId,
      ))!;
      expect(choice.page.items.map((m) => m.messageId), [
        'game-a',
        'game-b',
        'game-c',
      ]);
      expect(
        choice.page.toString(),
        isNot(contains(ExactHistoryConsentFixture.bodyCanary)),
      );
      expect(
        await f.controller.selectMessages(choice, ['game-c', 'game-a']),
        isTrue,
      );
      final p = await f.policy();
      expect(p.scope!.gameHistory!.messageIds, ['game-a', 'game-c']);
      expect(p.scope!.selectedData, isEmpty);
      expect(p.grants, isEmpty);
      expect(f.runtime.recipientConfirmed, isFalse);
      expect(_local(f.controller.view).available, isTrue);
      expect(f.metadataReads, 2);
      expect(f.sql.gameReads, isNotEmpty);
      expect(
        f.sql.forbiddenReads,
        isEmpty,
        reason: 'Actual picker returns metadata projections only',
      );
    },
  );

  for (final status in ['missing', 'locked', 'corrupt']) {
    _isolated(
      'exact selection cannot enable under $status policy',
      (f) async {
        final row = (await f.row())!;
        switch (status) {
          case 'missing':
            await (f.db.delete(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(row.id))).go();
          case 'locked':
            await (f.db.update(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(row.id))).write(
              const SupportContextBlocksCompanion(
                protectedFactsCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'corrupt':
            final block = (await f.repo.getContextBlockById(row.id))!;
            await f.repo.putContextBlock(
              block.copyWith(protectedFactsJson: 'synthetic-corrupt'),
            );
        }
        await f.runtime.refresh();
        final r = await _review(f);
        final bytes = await f.row();
        expect(_local(r.view).available, isFalse);
        expect(await _enable(f, r), isFalse);
        expect(await f.row(), bytes);
        expect(f.sql.gameReads, isEmpty);
      },
      scope: ExactHistoryConsentFixture.exactScope(),
    );
  }

  for (final pending in ['settings', 'configuration', 'write']) {
    _isolated(
      'exact history view is unavailable during pending $pending',
      (f) async {
        final r = await _review(f);
        if (pending == 'write') {
          f.repo.pauseAdmission();
          final write = _enable(f, r);
          await f.repo.entered!.future;
          try {
            expect(f.runtime.pending, 1);
            expect(_local(f.controller.view).available, isFalse);
            expect(await f.controller.prepareReview(), isNull);
            expect((await f.policy()).grants, isEmpty);
            expect(f.sql.gameReads, isEmpty);
          } finally {
            f.repo.release!.complete();
            expect(await write, isTrue);
          }
        } else {
          final settle = pending == 'settings'
              ? f.runtime.beginSettingsChange()
              : f.revisions.beginMutation();
          try {
            expect(_local(f.controller.view).available, isFalse);
            final bytes = await f.row();
            expect(await _enable(f, r), isFalse);
            expect(await f.row(), bytes);
          } finally {
            settle();
          }
        }
      },
      scope: ExactHistoryConsentFixture.exactScope(),
    );
  }

  for (final loss in [
    'scope',
    'scope ABA',
    'session ABA',
    'issuer',
    'configuration ABA',
    'cancel',
    'dispose',
  ]) {
    _isolated(
      'old exact-history displayed intent and review reject $loss',
      (f) async {
        final displayed = f.controller.view;
        final r = await _review(f);
        switch (loss) {
          case 'scope':
          case 'scope ABA':
            await f.otherPermissions.selectScopeFromNative(
              ExactHistoryConsentFixture.id,
              ExactHistoryConsentFixture.exactScope(
                revision: 2,
                companions: true,
              ),
              isCurrent: () => true,
            );
            if (loss == 'scope ABA') {
              await f.otherPermissions.selectScopeFromNative(
                ExactHistoryConsentFixture.id,
                ExactHistoryConsentFixture.exactScope(revision: 3),
                isCurrent: () => true,
              );
            }
            await f.runtime.refresh();
          case 'session ABA':
            f.runtime.selectSession('synthetic-away');
            f.runtime.selectSession(ExactHistoryConsentFixture.id);
            await f.runtime.refresh();
          case 'issuer':
            f.controller.invalidateDisplayedIntents();
          case 'configuration ABA':
            final settle = f.revisions.beginMutation();
            settle();
          case 'cancel':
            f.controller.cancelReview();
          case 'dispose':
            f.runtime.dispose();
        }
        final bytes = await f.row();
        expect(
          f.controller.isDisplayedIntentCurrent(displayed.displayedIntent),
          isFalse,
        );
        expect(await _enable(f, r), isFalse);
        expect(await f.row(), bytes);
        expect(f.sql.gameReads, isEmpty);
      },
      scope: ExactHistoryConsentFixture.exactScope(),
    );
  }

  _isolated(
    'only original live issuer accepts exact-history review; forged/foreign intents deny',
    (f) async {
      final displayed = f.controller.view;
      final r = await _review(f);
      final other = SupportNativeConsentController(
        runtime: f.runtime,
        readMessages: f.controller.readMessages,
      );
      final bytes = await f.row();
      expect(
        other.isDisplayedIntentCurrent(displayed.displayedIntent),
        isFalse,
      );
      expect(
        await other.prepareReview(displayedIntent: displayed.displayedIntent),
        isNull,
      );
      expect(
        await other.setGrant(r, SupportPermission.readGameData, true),
        isFalse,
      );
      expect(
        await f.controller.prepareReview(displayedIntent: _ForgedIntent()),
        isNull,
      );
      expect(await f.row(), bytes);
      expect(await _enable(f, r), isTrue);
      expect(f.sql.gameReads, isEmpty);
    },
    scope: ExactHistoryConsentFixture.exactScope(),
  );

  _isolated(
    'same-review queued local/change grants merge without implied model/report/network rights',
    (f) async {
      final r = await _review(f);
      f.repo.pauseAdmission();
      final a = _enable(f, r);
      await f.repo.entered!.future;
      final b = f.controller.setGrant(
        r,
        SupportPermission.confirmedSettingsChanges,
        true,
      );
      f.repo.release!.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect((await f.policy()).grants, {
        SupportPermission.readGameData,
        SupportPermission.confirmedSettingsChanges,
      });
      expect(f.sql.gameReads, isEmpty);
    },
    scope: ExactHistoryConsentFixture.exactScope(),
  );

  _isolated(
    'exact local grant merges an independent adapter report grant without changing old scope',
    (f) async {
      final displayed = f.controller.view;
      final r = await _review(f);
      f.repo.pauseAdmission();
      final local = _enable(f, r);
      await f.repo.entered!.future;
      try {
        await f.otherPermissions.setGrantFromNative(
          ExactHistoryConsentFixture.id,
          SupportPermission.reportGameHistory,
          true,
          isCurrent: () => true,
        );
      } finally {
        f.repo.release!.complete();
      }
      expect(await local, isTrue);
      final p = await f.policy();
      expect(p.grants, {
        SupportPermission.readGameData,
        SupportPermission.reportGameHistory,
      });
      expect(p.scope!.sameAs(ExactHistoryConsentFixture.exactScope()), isTrue);
      expect(
        f.controller.isDisplayedIntentCurrent(displayed.displayedIntent),
        isTrue,
      );
      expect(f.metadataReads, 0);
      expect(f.sql.gameReads, isEmpty);
    },
    scope: ExactHistoryConsentFixture.exactScope(),
  );

  for (final replacement in [
    'scope',
    'policy',
    'recipient',
    'retired issuer',
  ]) {
    _isolated(
      'queued exact enable rejects changed $replacement byte-for-byte',
      (f) async {
        final r = await _review(f);
        f.repo.pauseAdmission();
        final enabling = _enable(f, r);
        await f.repo.entered!.future;
        try {
          if (replacement == 'retired issuer') {
            f.controller.invalidateDisplayedIntents();
          } else if (replacement == 'scope') {
            await f.otherPermissions.selectScopeFromNative(
              ExactHistoryConsentFixture.id,
              ExactHistoryConsentFixture.exactScope(
                revision: 2,
                selectedData: {
                  SupportDataCategory.character: ['unsupported-character'],
                },
              ),
              isCurrent: () => true,
            );
          } else if (replacement == 'recipient') {
            await f.otherPermissions.selectRecipientFromNative(
              ExactHistoryConsentFixture.id,
              permissionRecipient(),
              isCurrent: () => true,
            );
          } else {
            await f.replacePolicy(
              scope: ExactHistoryConsentFixture.exactScope(),
              identity: 'replacement-policy',
            );
          }
          final bytes = await f.row();
          f.repo.release!.complete();
          expect(await enabling, isFalse);
          expect(await f.row(), bytes);
        } finally {
          if (!f.repo.release!.isCompleted) f.repo.release!.complete();
          await enabling;
        }
        expect(f.sql.gameReads, isEmpty);
      },
      scope: ExactHistoryConsentFixture.exactScope(),
    );
  }

  _isolated(
    'independent model/report-only toggles neither enable nor invoke local history read',
    (f) async {
      await _confirmSyntheticRecipient(f);
      final r = await _review(f);
      for (final right in [
        SupportPermission.modelGameHistory,
        SupportPermission.reportGameHistory,
      ]) {
        expect(await f.controller.setGrant(r, right, true), isTrue);
      }
      final p = await f.policy();
      expect(p.grants, {
        SupportPermission.modelGameHistory,
        SupportPermission.reportGameHistory,
      });
      expect(_local(f.controller.view).enabled, isFalse);
      expect(f.metadataReads, 0);
      expect(f.sql.gameReads, isEmpty);
      final source = SupportPermissionSource.gameHistory(
        ExactHistoryConsentFixture.id,
        p.scope!.gameSessionId!,
        p.scope!.gameHistory!,
      );
      expect(source.allowedFor(p, SupportPermissionUse.localRead), isFalse);
    },
    scope: ExactHistoryConsentFixture.exactScope(),
  );
}
