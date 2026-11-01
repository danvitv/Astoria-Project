import 'dart:async';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_game_source_observer.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'support_memory_catalog_send_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  memoryCatalogSendTest(
    'normal FILE Send rebuilds local abstracts with exact consumed native custody; no later POST/action',
    (f) async {
      final books = f.raw('memory_book_rows'), chats = f.raw('chat_sessions');
      final embeddings = f.raw('embeddings'),
          entities = f.raw('memory_entity_rows');
      final other = await f.catalog.getBySessionId(
        MemoryCatalogSendFixture.other,
      );
      var decisions = 0;
      f.confirmation.beforeDecision = (request) async {
        decisions++;
        expect(request.action, 'astoria_memory_catalog_rebuild');
        expect(request.preview['status'], 'local_catalog_only');
        expect(request.context.sourceAccess, isNotNull);
        expect(
          request.context.sourceAccess,
          isNot(same(request.context.sourceToolAccess)),
        );
        // Exact confirmation alone is not consumed native effect/source custody.
        expect(
          await request.context.sourceAccess!.acquire(
            domain: 'memory_book',
            sourceId: 'memorybook_${MemoryCatalogSendFixture.target}',
            observation: request.observation,
            context: request.context,
          ),
          isNull,
        );
      };
      f.afterCatalog = () {
        final context = f.confirmation.last!.context;
        expect(context.cancelToken.isCancelled, true);
        expect(context.current, false);
        expect(
          context.nativeDomainCustody?.operation,
          SupportAppDomainOperation.memoryCatalog,
        );
        expect(
          context.domainEffectMatches(
            MemoryCatalogSendFixture.target,
            f.confirmation.last!.observation,
          ),
          true,
        );
        expect(
          f.mutations.isSessionPending(MemoryCatalogSendFixture.target),
          true,
        );
        // The separate real selected-source observer case proves that ONLY the
        // consumed effect's actual own-source retirement can be exempted.
      };
      final result = await f.send(extraCall: true);
      expect(result.saved, true);
      expect(result.message!.status, 'stopped');
      expect(result.message!.text, contains('изменение сохранено'));
      expect(f.model.wire, hasLength(1));
      expect(decisions, 1);
      expect(f.rebuilds, 1);
      final rows = await f.catalog.getBySessionId(
        MemoryCatalogSendFixture.target,
      );
      expect(
        rows.single.abstractText,
        '${MemoryCatalogSendFixture.body} second paragraph',
      );
      expect(
        rows.single.memoryEntryId,
        '${MemoryCatalogSendFixture.target}-entry',
      );
      expect(
        await f.catalog.getBySessionId(MemoryCatalogSendFixture.other),
        other,
      );
      expect(f.raw('memory_book_rows'), books);
      expect(f.raw('chat_sessions'), chats);
      expect(f.raw('embeddings'), embeddings);
      expect(f.raw('memory_entity_rows'), entities);
      expect(f.refreshed, 1);
      final original = f.confirmation.last!.context;
      expect(original.nativeDomainCustody, isNull);
      expect(original.domainEffectCurrent, false);
      expect(
        f.mutations.isSessionPending(MemoryCatalogSendFixture.target),
        false,
      );
      expect(
        await original.sourceAccess!.acquire(
          domain: 'memory_book',
          sourceId: 'memorybook_${MemoryCatalogSendFixture.target}',
          observation: f.confirmation.last!.observation,
          context: original,
        ),
        isNull,
      );
      f.noEgress(result.message!.text);
    },
  );

  memoryCatalogSendTest(
    'selected game-source observer pending retires only the requester, not its own native catalog lease',
    (f) async {
      final native = f.model.native;
      await native.permissions.selectScopeFromNative(
        native.session,
        SupportPermissionScope(
          selectionRevision: 1,
          gameSessionId: MemoryCatalogSendFixture.target,
          gameHistoryExtent: SupportHistoryExtent.wholeSession,
        ),
        isCurrent: () => native.rootCurrent,
      );
      await native.runtime.refresh(resolve: true);
      final observer = SupportGameSourceObserver(
        registry: f.mutations,
        runtime: native.runtime,
        invalidateGameSource: f.model.service.invalidateGameSource,
      );
      try {
        f.afterCatalog = () {
          expect(native.runtime.pending, 1);
          expect(observer.isStable, false);
          expect(f.confirmation.last!.context.current, false);
          expect(f.confirmation.last!.context.domainEffectCurrent, true);
        };
        final result = await f.send();
        expect(result.message!.text, contains('изменение сохранено'));
        expect(f.rebuilds, 1);
        expect(native.runtime.pending, 0);
        expect(observer.isStable, true);
        expect(f.model.wire, hasLength(1));
      } finally {
        observer.dispose();
      }
    },
  );

  memoryCatalogSendTest(
    'reentrant independent TARGET mutation cannot be adopted as the catalog own fence',
    (f) async {
      final native = f.model.native;
      await native.permissions.selectScopeFromNative(
        native.session,
        SupportPermissionScope(
          selectionRevision: 1,
          gameSessionId: MemoryCatalogSendFixture.target,
          gameHistoryExtent: SupportHistoryExtent.wholeSession,
        ),
        isCurrent: () => native.rootCurrent,
      );
      await native.runtime.refresh(resolve: true);
      final observer = SupportGameSourceObserver(
        registry: f.mutations,
        runtime: native.runtime,
        invalidateGameSource: f.model.service.invalidateGameSource,
      );
      var nested = false;
      final unsubscribe = f.mutations.subscribe((change) {
        if (nested ||
            change.phase != ChatSourceMutationPhase.began ||
            change.sessionId != MemoryCatalogSendFixture.target)
          return;
        nested = true;
        f.mutations.beginMutation(sessionId: MemoryCatalogSendFixture.target)();
      });
      final before = f.raw('memory_catalog_rows');
      try {
        final result = await f.send();
        expect(nested, true);
        expect(f.rebuilds, 0);
        expect(f.raw('memory_catalog_rows'), before);
        expect(result.message!.text, isNot(contains('изменение сохранено')));
        expect(f.model.wire, hasLength(1));
        expect(
          f.mutations.isSessionPending(MemoryCatalogSendFixture.target),
          false,
        );
      } finally {
        unsubscribe();
        observer.dispose();
      }
    },
  );

  memoryCatalogSendTest(
    'global read consent absent: catalog remains unavailable, never relabelled as success',
    (f) async {
      final before = f.raw('memory_catalog_rows');
      final chatReads = f.chats.preparations, bookReads = f.books.observations;
      final result = await f.send();
      expect(f.chats.preparations, chatReads);
      expect(f.books.observations, bookReads);
      expect(f.confirmation.last, isNull);
      expect(f.model.result('catalog-call')['code'], 'unavailable');
      expect(f.rebuilds, 0);
      expect(f.raw('memory_catalog_rows'), before);
      expect(result.message!.text, isNot(contains('изменение сохранено')));
    },
    grant: false,
  );

  memoryCatalogSendTest(
    'selected OTHER source retirement during catalog replacement rolls back even after settlement',
    (f) async {
      final native = f.model.native;
      await native.permissions.selectScopeFromNative(
        native.session,
        SupportPermissionScope(
          selectionRevision: 1,
          gameSessionId: MemoryCatalogSendFixture.other,
          gameHistoryExtent: SupportHistoryExtent.wholeSession,
        ),
        isCurrent: () => native.rootCurrent,
      );
      await native.runtime.refresh(resolve: true);
      final observer = SupportGameSourceObserver(
        registry: f.mutations,
        runtime: native.runtime,
        invalidateGameSource: f.model.service.invalidateGameSource,
      );
      final before = f.raw('memory_catalog_rows');
      try {
        f.afterCatalog = () {
          final external = f.mutations.beginMutation(
            sessionId: MemoryCatalogSendFixture.other,
          );
          expect(native.runtime.pending, 1);
          external();
          expect(native.runtime.pending, 0);
        };
        final result = await f.send();
        expect(f.rebuilds, 1);
        expect(f.raw('memory_catalog_rows'), before);
        expect(result.message!.text, isNot(contains('изменение сохранено')));
        expect(f.model.wire, hasLength(1));
      } finally {
        observer.dispose();
      }
    },
  );

  memoryCatalogSendTest(
    'queued native permission change during acquisition denies catalog before its durable policy write',
    (f) async {
      final native = f.model.native;
      final controller = SupportNativeConsentController(
        runtime: native.runtime,
        readMessages: (_, _, _) => throw StateError('No picker'),
      );
      final review = await controller.prepareReview(resolveRecipient: false);
      expect(review, isNotNull);
      final release = Completer<void>();
      Future<bool>? queued;
      native.primitive.afterEncrypt = (aad) async {
        if (aad.contains('workspace-permissions-global-v1'))
          await release.future;
      };
      native.primitive.beforeDecrypt = (_) async {
        if (queued != null ||
            f.confirmation.last?.context.nativeDomainCustody == null)
          return;
        queued = controller.setGrant(
          review!,
          SupportPermission.confirmedConnectionTests,
          true,
        );
        expect(native.runtime.pending, 1);
      };
      final before = f.raw('memory_catalog_rows');
      try {
        final result = await f.send();
        expect(queued, isNotNull);
        expect(f.rebuilds, 0);
        expect(f.raw('memory_catalog_rows'), before);
        expect(result.message!.text, isNot(contains('изменение сохранено')));
        expect(f.model.wire, hasLength(1));
      } finally {
        native.primitive.beforeDecrypt = null;
        release.complete();
        if (queued != null) await queued!.timeout(const Duration(seconds: 20));
        native.primitive.afterEncrypt = null;
      }
    },
  );

  memoryCatalogSendTest(
    'declined exact confirmation does not obtain a local read/effect lease',
    (f) async {
      f.confirmation.accept = false;
      final before = f.raw('memory_catalog_rows');
      final result = await f.send();
      expect(f.model.result('catalog-call')['code'], 'denied');
      expect(f.rebuilds, 0);
      expect(f.raw('memory_catalog_rows'), before);
      expect(f.confirmation.last!.context.nativeDomainCustody, isNull);
      f.noEgress(result.message!.text);
    },
  );

  memoryCatalogSendTest(
    'pending source blocks preparation before native confirmation',
    (f) async {
      final finish = f.mutations.beginMutation(
        sessionId: MemoryCatalogSendFixture.target,
      );
      try {
        final before = f.raw('memory_catalog_rows');
        await f.send();
        expect(f.confirmation.last, isNull);
        expect(f.rebuilds, 0);
        expect(f.raw('memory_catalog_rows'), before);
      } finally {
        finish();
      }
    },
  );

  memoryCatalogSendTest(
    'changed exact MemoryBook row CAS cannot rebuild the confirmed old book',
    (f) async {
      final before = f.raw('memory_catalog_rows');
      f.confirmation.beforeDecision = (_) async {
        final latest = (await f.books.observeForControl(
          MemoryCatalogSendFixture.target,
        ))!;
        expect(
          await f.books.patchSettingsForControl(
            expected: latest,
            fields: {'enabled': true},
            isCurrent: () => true,
          ),
          true,
        );
      };
      final result = await f.send();
      expect(f.rebuilds, 0);
      expect(f.raw('memory_catalog_rows'), before);
      expect(
        (await f.books.getBySessionId(
          MemoryCatalogSendFixture.target,
        ))!.settings.enabled,
        true,
      );
      expect(result.message!.text, isNot(contains('изменение сохранено')));
      expect(f.model.wire, hasLength(1));
    },
  );

  for (final reason in ['Stop', 'read OFF']) {
    memoryCatalogSendTest(
      '$reason before effect admission cannot consume native catalog custody',
      (f) async {
        final before = f.raw('memory_catalog_rows');
        f.confirmation.beforeDecision = (_) async {
          if (reason == 'Stop') {
            f.model.service.stop();
          } else {
            f.model.native.permissions.latchApplicationDataRevocation();
          }
        };
        final result = await f.send();
        expect(f.rebuilds, 0);
        expect(f.raw('memory_catalog_rows'), before);
        expect(f.confirmation.last!.context.nativeDomainCustody, isNull);
        expect(result.message!.text, isNot(contains('изменение сохранено')));
        expect(f.model.wire, hasLength(1));
      },
    );
  }

  for (final reason in [
    'read OFF in another store',
    'OFF then fresh ON',
    'native owner removed',
    'external source mutation',
    'configuration changed',
  ]) {
    memoryCatalogSendTest(
      '$reason during derived replacement rolls back before commit',
      (f) async {
        final before = f.raw('memory_catalog_rows');
        f.afterCatalog = () {
          if (reason.startsWith('read') || reason.startsWith('OFF')) {
            final other = SupportPermissionStore(f.model.native.repo);
            final revoked = other.latchApplicationDataRevocation();
            if (reason.startsWith('OFF')) {
              expect(other.confirmApplicationDataConsent(revoked), true);
            }
          } else if (reason == 'native owner removed') {
            f.unregister();
          } else if (reason == 'configuration changed') {
            f.model.native.runtime.invalidateConfiguration();
          } else {
            f.mutations.beginMutation(
              sessionId: MemoryCatalogSendFixture.target,
            )();
          }
        };
        final result = await f.send();
        expect(
          f.rebuilds,
          1,
          reason: 'Real nested replacement must run before rollback proof.',
        );
        expect(f.raw('memory_catalog_rows'), before);
        expect(result.message!.text, isNot(contains('изменение сохранено')));
        expect(f.model.wire, hasLength(1));
      },
    );
  }

  memoryCatalogSendTest(
    'read OFF during native policy decryption refuses acquisition before catalog work',
    (f) async {
      final before = f.raw('memory_catalog_rows');
      var revoked = false;
      f.model.native.primitive.beforeDecrypt = (_) async {
        if (!revoked &&
            f.confirmation.last?.context.nativeDomainCustody != null) {
          revoked = true;
          f.model.native.permissions.latchApplicationDataRevocation();
        }
      };
      final result = await f.send();
      expect(revoked, true);
      expect(f.rebuilds, 0);
      expect(f.raw('memory_catalog_rows'), before);
      expect(result.message!.text, isNot(contains('изменение сохранено')));
      expect(f.model.wire, hasLength(1));
    },
  );

  memoryCatalogSendTest(
    'explicit original database-owner withdrawal rolls back and cannot publish a replacement reply',
    (f) async {
      final before = f.raw('memory_catalog_rows');
      f.afterCatalog = f.model.service.revokeSettlementOwner;
      final result = await f.send();
      expect(f.rebuilds, 1);
      expect(f.raw('memory_catalog_rows'), before);
      expect(result.saved, false);
      expect(result.message, isNull);
      expect(f.model.wire, hasLength(1));
    },
  );

  memoryCatalogSendTest(
    'foreign context/observation cannot obtain the original catalog source lease',
    (f) async {
      f.confirmation.beforeDecision = (request) async {
        final original = request.context;
        final foreign = SupportAppActionContext(
          runId: original.runId,
          sessionId: original.sessionId,
          cancelToken: CancelToken(),
          isCurrent: () => true,
          allowReversibleChanges: true,
          domainRoot: original.domainRoot,
          sourceAccess: original.sourceAccess,
        );
        final observed = (await f.books.observeForControl(
          MemoryCatalogSendFixture.target,
        ))!;
        expect(
          await original.sourceAccess!.acquire(
            domain: 'memory_book',
            sourceId: observed.book.id,
            observation: request.observation,
            context: foreign,
          ),
          isNull,
        );
        expect(
          await original.sourceAccess!.acquire(
            domain: 'memory_book',
            sourceId: observed.book.id,
            observation: observed,
            context: original,
          ),
          isNull,
        );
        expect(
          await original.sourceAccess!.acquire(
            domain: 'game',
            sourceId: observed.book.id,
            observation: request.observation,
            context: original,
          ),
          isNull,
        );
      };
      final result = await f.send();
      expect(f.rebuilds, 1);
      expect(result.message!.text, contains('изменение сохранено'));
    },
  );

  memoryCatalogSendTest(
    'invalid source manifest keeps existing catalog and canonical book intact',
    (f) async {
      final book = (await f.books.getBySessionId(
        MemoryCatalogSendFixture.target,
      ))!;
      await f.books.put(
        book.copyWith(
          entries: [
            book.entries.single.copyWith(
              sourceManifest: book.entries.single.sourceManifest!.invalidate(),
            ),
          ],
        ),
      );
      final before = f.raw('memory_catalog_rows'),
          canonical = f.raw('memory_book_rows');
      final result = await f.send();
      expect(f.rebuilds, 0);
      expect(f.raw('memory_catalog_rows'), before);
      expect(f.raw('memory_book_rows'), canonical);
      expect(result.message!.text, isNot(contains('изменение сохранено')));
    },
  );

  for (final retry in [false, true]) {
    memoryCatalogSendTest(
      'read-only ${retry ? 'retry' : 'regeneration'} has no catalog effect graph',
      (f) async {
        final prior = await f.send();
        final before = f.raw('memory_catalog_rows');
        final decisions = f.confirmation.last;
        if (retry) {
          final appended = await f.model.native.repo.appendCurrentUser(
            message: SupportMessage(
              id: 'catalog-retry-user',
              sessionId: f.model.native.session,
              runId: 'catalog-retry-input',
              role: 'user',
              body: 'Existing unanswered input',
              // Valid for BOTH native input and source-history timestamp
              // contracts; the latter rejects values above 8,640,000,000,000.
              createdAt: prior.message!.createdAt + 1,
            ),
            isCurrent: () => true,
          );
          expect(
            appended,
            isNotNull,
            reason: 'actual native unanswered input must be admitted',
          );
        }
        final rows = await f.model.native.repo.getMessagesForSession(
          f.model.native.session,
        );
        final visible = [
          for (final row in rows)
            SupportModelConversationMessage(
              id: row.id,
              role: row.role,
              text: row.body,
            ),
        ];
        f.model.script = (_) => AutomaticSourcesFixture.calls([
          (
            'forged-rebuild',
            'astoria_memory_catalog_rebuild',
            {'sessionId': MemoryCatalogSendFixture.target},
          ),
        ]);
        final selected = rows.last;
        if (retry) {
          expect(selected.role, 'user');
          expect(
            await f.model.native.repo.readUnansweredUser(
              expectedUser: selected,
              isCurrent: () => f.model.native.rootCurrent,
            ),
            isNotNull,
            reason: 'native stored tail must be genuinely unanswered',
          );
        }
        final submission = retry
            ? f.model.service.beginRetry(
                controller: Object(),
                uiLifetime: Object(),
                isEmitterCurrent: () => true,
                selectedUser: SupportModelMessage(
                  id: selected.id,
                  sessionId: selected.sessionId,
                  runId: selected.runId!,
                  role: selected.role,
                  status: selected.status,
                  createdAt: selected.createdAt,
                  text: selected.body,
                ),
                visibleConversation: visible,
                toolUi: SupportModelToolUiPorts(confirmation: f.confirmation),
              )
            : f.model.service.beginRegeneration(
                controller: Object(),
                uiLifetime: Object(),
                isEmitterCurrent: () => true,
                selectedReply: prior.message!,
                visibleConversation: visible,
                toolUi: SupportModelToolUiPorts(confirmation: f.confirmation),
              );
        final result = await submission.finished.timeout(
          const Duration(seconds: 20),
        );
        expect(result.accepted, true, reason: result.reason.name);
        expect(f.model.wire, hasLength(2));
        final definitions = f.model.wire.last['tools'] as List;
        expect(definitions, hasLength(4));
        expect(
          definitions.every(
            (tool) =>
                ((tool as Map)['function'] as Map)['name']
                    .toString()
                    .startsWith('astoria_source') ||
                ((tool['function'] as Map)['name'] == 'astoria_sources_list'),
          ),
          true,
        );
        expect(f.confirmation.last, same(decisions));
        expect(f.rebuilds, 1);
        expect(f.raw('memory_catalog_rows'), before);
      },
    );
  }
}
