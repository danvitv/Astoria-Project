import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, QueryInterceptor, QueryExecutor;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_authorization_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import 'helpers/support_model_fixture.dart';
import 'helpers/support_permission_test_fixtures.dart';

final class _PauseMissingGlobalProbe extends QueryInterceptor {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool observed = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (!observed &&
        statement.contains('support_context_blocks') &&
        args.contains(SupportPermissionCodec.globalId)) {
      observed = true;
      if (rows.isNotEmpty) throw StateError('Expected missing global profile.');
      entered.complete();
      await release.future;
    }
    return rows;
  }
}

// Existing declared-schema native memory fixture, fake key storage, real AEAD.
// No app startup, runtime database, platform vault, sockets or provider service.
void main() {
  const id = SupportModelFixture.session, other = 'synthetic-other';
  const codec = SupportPermissionCodec();
  late SupportModelFixture f;
  late HttpOverrides? previousHttp;
  late _NoNetwork network;
  setUp(() async {
    previousHttp = HttpOverrides.current;
    network = _NoNetwork();
    HttpOverrides.global = network;
    f = await SupportModelFixture.create(
      scope: permissionScope(),
      grants: [
        SupportPermission.readSafeSettings,
        SupportPermission.modelSupportHistory,
        SupportPermission.modelAttachments,
      ],
    );
    await f.repo.createSession(
      const SupportSession(
        id: other,
        title: 'Synthetic other',
        createdAt: 3,
        updatedAt: 3,
      ),
    );
  });
  tearDown(() async {
    try {
      await f.close();
      expect(network.attempts, 0);
    } finally {
      HttpOverrides.global = previousHttp;
    }
  });
  Future<SupportContextBlock?> global() =>
      f.repo.getContextBlockById(codecGlobalId);
  Future<SupportPermissionPreferences> read(String session) async =>
      (await f.store.readForNative(session)).preferences!;
  Future<void> initialize() async {
    expect(
      await f.store.initializeGlobalFromNative(id, isCurrent: () => true),
      isNotNull,
    );
  }

  test(
    'legacy mutation refuses initialization overlap without obsolete commit',
    () async {
      final legacy = await f.repo.getContextBlockById(codec.idFor(id));
      final probe = _PauseMissingGlobalProbe();
      final pending = f.db.runWithInterceptor(
        () => f.store.setGrantFromNative(
          id,
          SupportPermission.readSafeSettings,
          false,
          isCurrent: () => true,
        ),
        interceptor: probe,
      );
      final refused = expectLater(
        pending,
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      try {
        await probe.entered.future;
        final otherStore = SupportPermissionStore(f.repo);
        await otherStore.initializeGlobalFromNative(id, isCurrent: () => true);
        probe.release.complete();
        await refused;
        expect(probe.observed, true);
        expect(await f.repo.getContextBlockById(codec.idFor(id)), legacy);
        expect(
          (await read(id)).allows(SupportPermission.readSafeSettings),
          true,
        );
      } finally {
        if (!probe.release.isCompleted) probe.release.complete();
        await refused;
      }
    },
  );

  test(
    'production opt-in copies current legacy profile once; global survives chat cascades and new store',
    () async {
      final legacy = await f.repo.getContextBlockById(codec.idFor(id));
      final otherPolicy = permissionPolicy(
        session: other,
        identity: 'newest-policy',
      );
      await f.repo.putContextBlock(codec.encode(otherPolicy, 4));
      // Legacy composition is still deliberate before explicit initialization.
      expect((await read(other)).grants, isEmpty);
      await initialize();
      expect(
        (await read(other)).isConfigured(SupportPermission.readSafeSettings),
        isTrue,
      );
      expect(
        (await read(other)).allows(SupportPermission.readSafeSettings),
        isTrue,
      );
      expect(await f.repo.getContextBlockById(codec.idFor(id)), legacy);
      expect(
        await f.repo.getContextBlockById(codec.idFor(other)),
        codec.encode(otherPolicy, 4),
      );
      final row = (await global())!;
      expect(row.sessionId, isEmpty);
      expect(row.isActive, isFalse);
      expect(row.startMessageId, isEmpty);
      expect(row.endMessageId, isEmpty);
      final encrypted = (await (f.db.select(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(codecGlobalId))).getSingle());
      expect(encrypted.summaryCiphertext, isNot(contains(codecGlobalId)));
      expect(
        encrypted.protectedFactsCiphertext,
        isNot(contains('modelSupportHistory')),
      );
      expect(encrypted.protectedFactsCiphertext, isNot(contains('support-1')));
      expect(await f.repo.getContextBlocksForSession(id), isNot(contains(row)));
      await f.repo.deleteSession(id);
      await f.repo.deleteSession(other);
      expect(await global(), row);
      await f.repo.createSession(
        const SupportSession(
          id: 'synthetic-new-chat',
          title: 'Synthetic new',
          createdAt: 5,
          updatedAt: 5,
        ),
      );
      final restarted = SupportPermissionStore(f.repo);
      final p = (await restarted.readForNative(
        'synthetic-new-chat',
      )).preferences!;
      expect(
        p.policyIdentity,
        codec.decodeGlobal('synthetic-new-chat', row).policyIdentity,
      );
      expect(p.allows(SupportPermission.readSafeSettings), isTrue);
      expect(p.scope!.supportHistory, isNull);
    },
  );

  test(
    'missing chosen policy selects newest existing legacy; truly missing initializes deny only',
    () async {
      await f.repo.putContextBlock(
        codec.encode(
          permissionPolicy(
            session: other,
            identity: 'newest-policy',
            grants: [SupportPermission.readDiagnostics],
          ),
          4,
        ),
      );
      await (f.db.delete(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).go();
      await initialize();
      expect((await read(id)).policyIdentity, 'newest-policy');
      expect(
        (await read(id)).allows(SupportPermission.readDiagnostics),
        isTrue,
      );
      // A separate explicit synthetic DB is needed for the genuinely missing case.
      final empty = await SupportModelFixture.create();
      try {
        await (empty.db.delete(
          empty.db.supportContextBlocks,
        )..where((t) => t.id.equals(codec.idFor(id)))).go();
        final p = (await empty.store.initializeGlobalFromNative(
          id,
          isCurrent: () => true,
        ))!;
        expect(p.grants, isEmpty);
        expect(p.scope, isNull);
        expect(p.recipient, isNull);
        expect(SupportPermission.values.every((r) => !p.allows(r)), isTrue);
      } finally {
        await empty.close();
      }
    },
  );

  test(
    'selected support IDs and private handles never rebind; explicit whole-current rule is separate',
    () async {
      await initialize();
      final own = await read(id), projected = await read(other);
      expect(own.allows(SupportPermission.modelSupportHistory), isTrue);
      expect(
        projected.isConfigured(SupportPermission.modelSupportHistory),
        isTrue,
      );
      expect(projected.allows(SupportPermission.modelSupportHistory), isFalse);
      expect(projected.scope!.supportHistory, isNull);
      expect(projected.scope!.selectedData, isEmpty);
      expect(
        projected.isConfigured(SupportPermission.modelAttachments),
        isTrue,
      );
      expect(projected.allows(SupportPermission.modelAttachments), isFalse);
      expect(
        SupportPermissionSource.supportHistory(
          other,
          own.scope!.supportHistory!,
        ).isSelectedBy(projected),
        isFalse,
      );
      expect(projected.scope!.gameSessionId, own.scope!.gameSessionId);
      expect(
        projected.scope!.gameHistory!.sameAs(own.scope!.gameHistory),
        isTrue,
      );
      // A grant-only edit in another chat must preserve the original canonical IDs.
      await f.store.setGrantFromNative(
        other,
        SupportPermission.readDiagnostics,
        true,
        isCurrent: () => true,
      );
      expect(
        (await read(
          id,
        )).scope!.supportHistory!.sameAs(own.scope!.supportHistory),
        isTrue,
      );
      expect((await read(id)).scope!.selectedData, own.scope!.selectedData);
      final categoryReview = await read(other);
      await f.store.changeReviewedFromNative(
        categoryReview,
        change: (p) => p.withNativeScope(
          SupportPermissionScope(
            selectionRevision: 2,
            gameSessionId: p.scope!.gameSessionId,
            gameHistory: p.scope!.gameHistory,
            safeCategories: const [SupportSafeCategory.theme],
          ),
        ),
        isCurrent: () => true,
      );
      // An unrelated native safe-category picker also keeps the hidden old owner.
      expect(
        (await read(
          id,
        )).scope!.supportHistory!.sameAs(own.scope!.supportHistory),
        isTrue,
      );
      expect((await read(other)).scope!.supportHistory, isNull);
      await f.store.selectScopeFromNative(
        id,
        SupportPermissionScope(
          selectionRevision: 3,
          gameSessionId: 'synthetic-game',
          gameHistoryExtent: SupportHistoryExtent.wholeSession,
          supportHistoryExtent: SupportHistoryExtent.wholeSession,
        ),
        isCurrent: () => true,
      );
      await f.store.setGrantFromNative(
        id,
        SupportPermission.modelSupportHistory,
        true,
        isCurrent: () => true,
      );
      final whole = await read(other);
      expect(whole.scope!.supportHistory, isNull);
      expect(
        whole.scope!.supportHistoryExtent,
        SupportHistoryExtent.wholeSession,
      );
      expect(
        SupportPermissionSource.supportSessionHistory(
          other,
        ).allowedFor(whole, SupportPermissionUse.modelContext),
        isTrue,
      );
      expect(whole.scope!.gameSessionId, 'synthetic-game');
      expect(
        SupportPermissionSource.gameSessionHistory(
          'another-game',
        ).isSelectedBy(whole),
        isFalse,
      );
    },
  );

  for (final invalid in ['corrupt', 'unknown', 'locked-row', 'locked-parent']) {
    test(
      '$invalid chosen legacy source denies without skipping healthy newest or writing defaults',
      () async {
        await f.repo.putContextBlock(
          codec.encode(permissionPolicy(session: other), 4),
        );
        if (invalid == 'corrupt' || invalid == 'unknown') {
          final old = (await f.repo.getContextBlockById(codec.idFor(id)))!;
          final m = jsonDecode(old.protectedFactsJson) as Map<String, dynamic>;
          m['version'] = 999;
          await f.repo.putContextBlock(
            old.copyWith(
              protectedFactsJson: invalid == 'unknown'
                  ? jsonEncode(m)
                  : 'synthetic-corrupt',
            ),
          );
        } else if (invalid == 'locked-row') {
          await (f.db.update(
            f.db.supportContextBlocks,
          )..where((t) => t.id.equals(codec.idFor(id)))).write(
            const SupportContextBlocksCompanion(
              protectedFactsCiphertext: Value('synthetic-locked'),
            ),
          );
        } else {
          await (f.db.update(
            f.db.supportSessions,
          )..where((t) => t.id.equals(id))).write(
            const SupportSessionsCompanion(
              titleCiphertext: Value('synthetic-locked'),
            ),
          );
        }
        final before = await f.db.select(f.db.supportContextBlocks).get();
        await expectLater(
          f.store.initializeGlobalFromNative(id, isCurrent: () => true),
          throwsA(isA<SupportPermissionsUnavailable>()),
        );
        expect(await global(), isNull);
        expect(await f.db.select(f.db.supportContextBlocks).get(), before);
        expect((await f.store.readForNative(other)).isAvailable, isFalse);
      },
    );
  }

  test(
    'global corruption cannot fall back to legacy; only confirmed deny recovery changes profile',
    () async {
      await initialize();
      final old = (await global())!;
      final legacy = await f.repo.getContextBlockById(codec.idFor(id));
      await f.repo.mutateAssistantPermissions(
        currentSessionId: id,
        mutate: (row) =>
            row.copyWith(protectedFactsJson: 'synthetic-readable-corrupt'),
        isCurrent: () => true,
      );
      expect(
        (await f.store.readForNative(other)).availability,
        SupportPermissionAvailability.corrupt,
      );
      await expectLater(
        f.store.setGrantFromNative(
          other,
          SupportPermission.confirmedSettingsChanges,
          true,
          isCurrent: () => true,
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      final recoveryStore = SupportPermissionStore(
        f.repo,
        newIdentity: () => 'synthetic-recovered-policy',
      );
      final recovered = (await recoveryStore.recoverToDenyFromNative(
        other,
        confirmed: true,
        isCurrent: () => true,
      ))!;
      expect(recovered.grants, isEmpty);
      expect(
        recovered.policyIdentity,
        isNot(codec.decodeGlobal(id, old).policyIdentity),
      );
      expect(await f.repo.getContextBlockById(codec.idFor(id)), legacy);
    },
  );

  test(
    'locked global profile denies every chat and cannot recover via healthy legacy ciphertext',
    () async {
      await initialize();
      await (f.db.update(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(codecGlobalId))).write(
        const SupportContextBlocksCompanion(
          protectedFactsCiphertext: Value('synthetic-locked'),
        ),
      );
      final before = await f.db.select(f.db.supportContextBlocks).get();
      expect(
        (await f.store.readForNative(id)).availability,
        SupportPermissionAvailability.locked,
      );
      expect(
        (await f.store.readForNative(other)).availability,
        SupportPermissionAvailability.locked,
      );
      await expectLater(
        f.store.recoverToDenyFromNative(
          other,
          confirmed: true,
          isCurrent: () => true,
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(await f.db.select(f.db.supportContextBlocks).get(), before);
    },
  );

  test(
    'retired global initialization after encryption leaves legacy and singleton absence intact',
    () async {
      final before = await f.db.select(f.db.supportContextBlocks).get();
      var current = true;
      f.primitive.afterEncrypt = (aad) async {
        if (aad.contains(codecGlobalId)) current = false;
      };
      await expectLater(
        f.store.initializeGlobalFromNative(id, isCurrent: () => current),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(await global(), isNull);
      expect(await f.db.select(f.db.supportContextBlocks).get(), before);
    },
  );

  test(
    'global change prerequisite is not blanket read/model/report permission',
    () async {
      await initialize();
      await f.store.selectScopeFromNative(id, null, isCurrent: () => true);
      await f.store.selectRecipientFromNative(id, null, isCurrent: () => true);
      await f.store.setGrantFromNative(
        other,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      final p = await read(other);
      expect(p.allows(SupportPermission.confirmedSettingsChanges), isTrue);
      for (final right in SupportPermission.values) {
        if (right != SupportPermission.confirmedSettingsChanges) {
          expect(p.allows(right), isFalse);
        }
      }
      // This row contains configuration, never a restored/native final approval.
      final payload =
          jsonDecode((await global())!.protectedFactsJson)
              as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'version', 'owner', 'policy'});
    },
  );

  test(
    'separate global stores merge latest-row toggles; retired encryption rolls back exact bytes',
    () async {
      await initialize();
      final b = SupportPermissionStore(f.repo);
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      f.primitive.afterEncrypt = (aad) async {
        if (!paused &&
            aad.contains(codecGlobalId) &&
            aad.endsWith('|summary_ciphertext')) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final first = f.store.setGrantFromNative(
        id,
        SupportPermission.readDiagnostics,
        true,
        isCurrent: () => true,
      );
      await entered.future;
      final second = b.setGrantFromNative(
        other,
        SupportPermission.confirmedSettingsChanges,
        true,
        isCurrent: () => true,
      );
      release.complete();
      await Future.wait([first, second]);
      expect(
        (await read(id)).allows(SupportPermission.readDiagnostics),
        isTrue,
      );
      expect(
        (await read(other)).allows(SupportPermission.confirmedSettingsChanges),
        isTrue,
      );
      final before = await f.db.select(f.db.supportContextBlocks).get();
      var current = true;
      f.primitive.afterEncrypt = (aad) async {
        if (aad.contains(codecGlobalId)) current = false;
      };
      await expectLater(
        b.setGrantFromNative(
          other,
          SupportPermission.readDiagnostics,
          false,
          isCurrent: () => current,
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(await f.db.select(f.db.supportContextBlocks).get(), before);
      f.primitive.afterEncrypt = null;
      current = true;
      f.sql.afterWrite = (statement) async {
        if (statement.contains('support_context_blocks')) current = false;
      };
      await expectLater(
        b.setGrantFromNative(
          other,
          SupportPermission.readDiagnostics,
          false,
          isCurrent: () => current,
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(await f.db.select(f.db.supportContextBlocks).get(), before);
      f.sql.afterWrite = null;
    },
  );

  test(
    'global original lease refuses revocation; scope and recipient ABA reject stale reviewed enabling',
    () async {
      await initialize();
      final reviewed = await read(other);
      final authorization = SupportAuthorizationService(
        readPolicy: f.store.readForNative,
        currentNativeContext: () => SupportNativePermissionContext(
          supportSessionId: other,
          epoch: 1,
          scope: reviewed.scope,
          recipient: reviewed.recipient,
        ),
      );
      final lease = (await authorization.prepare(
        supportSessionId: other,
        use: SupportPermissionUse.localRead,
        sources: [
          SupportPermissionSource.safeProjection(
            other,
            SupportSafeCategory.connections,
          ),
        ],
      ))!;
      await f.store.setGrantFromNative(
        id,
        SupportPermission.readSafeSettings,
        false,
        isCurrent: () => true,
      );
      var loads = 0;
      await expectLater(
        authorization.loadLocal(lease, () async {
          loads++;
          return 'Synthetic';
        }),
        throwsA(isA<SupportAuthorizationDenied>()),
      );
      expect(loads, 0);
      for (final rev in [2, 3]) {
        await f.store.selectScopeFromNative(
          id,
          permissionScope(revision: rev),
          isCurrent: () => true,
        );
      }
      expect(
        await f.store.changeReviewedFromNative(
          reviewed,
          change: (p) =>
              p.withNativeGrant(SupportPermission.readSafeSettings, true),
          isCurrent: () => true,
        ),
        isNull,
      );
      final recipientReview = await read(other);
      final original = recipientReview.recipient!;
      await f.store.selectRecipientFromNative(
        id,
        permissionRecipient(revision: 20),
        isCurrent: () => true,
      );
      await f.store.selectRecipientFromNative(
        id,
        SupportPermissionRecipient(
          connectionId: original.connectionId,
          modelId: original.modelId,
          protocol: original.protocol,
          nativeRoute: original.nativeRoute,
          configurationRevision: original.configurationRevision + 1,
        ),
        isCurrent: () => true,
      );
      expect(
        await f.store.changeReviewedFromNative(
          recipientReview,
          change: (p) =>
              p.withNativeGrant(SupportPermission.modelSupportHistory, true),
          isCurrent: () => true,
        ),
        isNull,
      );
    },
  );

  test(
    'global envelope retains strict inner schema and cannot turn unknown/unscoped grants into authority',
    () async {
      await initialize();
      final row = (await global())!;
      final outer = jsonDecode(row.protectedFactsJson) as Map<String, dynamic>;
      final inner =
          jsonDecode(outer['policy'] as String) as Map<String, dynamic>;
      inner['scope'] = null;
      outer['policy'] = jsonEncode(inner);
      expect(
        () => codec.decodeGlobal(
          other,
          row.copyWith(protectedFactsJson: jsonEncode(outer)),
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
      expect(
        () => codec.decodeGlobal(
          other,
          row.copyWith(
            protectedFactsJson: row.protectedFactsJson.replaceFirst(
              '"version":1',
              '"version":999,"version":1',
            ),
          ),
        ),
        throwsA(isA<SupportPermissionsUnavailable>()),
      );
    },
  );
}

const codecGlobalId = SupportPermissionCodec.globalId;

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Synthetic HTTP tripwire');
  }
}
