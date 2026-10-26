import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'support_tool_loop_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  toolLoopTest(
    'regeneration rejects a non-visible same-session origin before decrypting its body',
    (f) async {
      final n = f.native;
      final service = n.newService();
      try {
        Future<SupportModelRunResult> send(
          String question,
          int revision,
        ) async {
          final input = await service.emitInput(
            controller: n.controller,
            uiLifetime: n.uiLifetime,
            draftRevision: revision,
            text: question,
            isEmitterCurrent: () => true,
            isDraftCurrent: () => true,
            directConversation: true,
            visibleConversation: [
              for (final m in await n.repo.getMessagesForSession(n.session))
                SupportModelConversationMessage(
                  id: m.id,
                  role: m.role,
                  text: m.body,
                ),
            ],
          );
          return service.beginSend(input.intent!).finished;
        }

        final first = await send('OTHER_HISTORICAL_NATIVE_QUESTION', 1);
        expect(first.saved, true);
        final older = (await n.repo.getMessagesForSession(
          n.session,
        )).singleWhere((m) => m.body == 'OTHER_HISTORICAL_NATIVE_QUESTION');
        final target = await send('Actual displayed latest question', 2);
        expect(target.saved, true);
        final block = (await n.repo.getContextBlockById(
          'support.reply_provenance:${target.message!.id}',
        ))!;
        final forged = SupportModelProvenance(
          supportSessionId: n.session,
          replyMessageId: target.message!.id,
          runId: target.message!.runId,
          currentUserMessageId: older.id,
          originalRanges: const [],
          directReplies: const [],
          currentConversationMessageIds: const [],
        );
        await n.repo.putContextBlock(
          block.copyWith(
            protectedFactsJson:
                SupportModelProvenanceCodec.encodeForEncryptedStorage(forged),
          ),
        );
        final before = await n.db.select(n.db.supportMessages).get();
        final visible = [
          for (final m in await n.repo.getMessagesForSession(n.session))
            SupportModelConversationMessage(
              id: m.id,
              role: m.role,
              text: m.body,
            ),
        ];
        var otherBodyDecrypts = 0;
        n.primitive.beforeDecrypt = (aad) async {
          if (aad.contains(older.id) && aad.contains('body_ciphertext')) {
            otherBodyDecrypts++;
          }
        };
        final rejected = await service
            .beginRegeneration(
              controller: n.controller,
              uiLifetime: n.uiLifetime,
              isEmitterCurrent: () => true,
              selectedReply: target.message!,
              visibleConversation: visible,
            )
            .finished;
        expect(rejected.reason, SupportModelRefusal.stale);
        expect(rejected.accepted, false);
        expect(otherBodyDecrypts, 0);
        expect(n.adapters, hasLength(2));
        expect(await n.db.select(n.db.supportMessages).get(), before);
      } finally {
        n.primitive.beforeDecrypt = null;
        service.dispose();
      }
    },
  );
  toolLoopTest(
    'native regeneration has no tool registry warmup, tools or effects; next Send accepts lineage',
    (f) async {
      final n = f.native;
      final initial = n.newService();
      final visible = [
        for (final m in await n.repo.getMessagesForSession(n.session))
          if (m.sessionId == n.session)
            SupportModelConversationMessage(
              id: m.id,
              role: m.role,
              text: m.body,
            ),
      ];
      final input = await initial.emitInput(
        controller: n.controller,
        uiLifetime: n.uiLifetime,
        draftRevision: 1,
        text: 'Existing original input',
        isEmitterCurrent: () => true,
        isDraftCurrent: () => true,
        directConversation: true,
        visibleConversation: visible,
      );
      final original = await initial.beginSend(input.intent!).finished;
      expect(original.saved, isTrue);
      initial.dispose();
      final userRows = await n.db.select(n.db.supportMessages).get();
      var warmups = 0;
      final regen = SupportModelService(
        db: n.db,
        writeCipher: n.cipher,
        apiRepo: n.apiRepo,
        revisions: n.revisions,
        redaction: n.redaction,
        runtime: n.runtime,
        adapterFactory: n.adapter,
        writes: n.queue,
        isOwnerCurrent: () => n.owner,
        nativeSources: n.native.sources,
        nativeMetadata: n.native.credentialReader,
        nativeDispatcher: (inner) => NativeProviderPrivateTextDispatcher(
          credentials: n.native.credentials,
          authIssuer: n.native.auth,
          mutations: n.native.mutations,
          routes: n.native.routes,
          privateTextTransport: inner,
        ),
        toolTransport: NativeToolTransport(
          credentials: n.native.credentials,
          authIssuer: n.native.auth,
          mutations: n.native.mutations,
          routes: n.native.routes,
          currentRedactor: () => n.redaction.redactor,
          adapterFactory: n.adapter,
        ),
        appActionsFactory: () {
          warmups++;
          throw StateError('No regeneration tool registry');
        },
        admissionContract: SupportTextAdmissionContract
            .auditedRootSingleConnectionNoBusyHandler,
      );
      final conversation = [
        for (final m in await n.repo.getMessagesForSession(n.session))
          SupportModelConversationMessage(id: m.id, role: m.role, text: m.body),
      ];
      final prefs = f.prefs
          .getKeys()
          .map((k) => '$k=${f.prefs.get(k)}')
          .toList();
      final submission = regen.beginRegeneration(
        controller: n.controller,
        uiLifetime: n.uiLifetime,
        isEmitterCurrent: () => true,
        selectedReply: original.message!,
        visibleConversation: conversation,
      );
      final duplicate = regen.beginRegeneration(
        controller: n.controller,
        uiLifetime: n.uiLifetime,
        isEmitterCurrent: () => true,
        selectedReply: original.message!,
        visibleConversation: conversation,
      );
      expect((await duplicate.finished).reason, SupportModelRefusal.busy);
      final result = await submission.finished;
      expect(result.saved, isTrue);
      expect(result.message!.id, original.message!.id);
      expect(result.message!.createdAt, original.message!.createdAt);
      expect(result.message!.runId, isNot(original.message!.runId));
      expect(warmups, 0);
      expect(n.adapters, hasLength(2));
      final wire = n.adapters.last.delegate.upload!;
      expect(wire, isNot(contains('"tools"')));
      expect(wire, isNot(contains('Synthetic native reply')));
      expect('Existing original input'.allMatches(wire), hasLength(1));
      expect(wire, contains('Only THIS regeneration'));
      expect(wire, isNot(contains('You have no tools or actions')));
      expect(f.prefs.getKeys().map((k) => '$k=${f.prefs.get(k)}'), prefs);
      expect(f.wire, isEmpty);
      final after = await n.db.select(n.db.supportMessages).get();
      for (final row in userRows.where((r) => r.role == 'user')) {
        expect(after.singleWhere((r) => r.id == row.id), row);
      }
      regen.dispose();
      final next = n.newService();
      final nextInput = await next.emitInput(
        controller: n.controller,
        uiLifetime: n.uiLifetime,
        draftRevision: 2,
        text: 'Next real Send',
        isEmitterCurrent: () => true,
        isDraftCurrent: () => true,
        directConversation: true,
        visibleConversation: [
          for (final m in await n.repo.getMessagesForSession(n.session))
            SupportModelConversationMessage(
              id: m.id,
              role: m.role,
              text: m.body,
            ),
        ],
      );
      expect((await next.beginSend(nextInput.intent!).finished).saved, isTrue);
      next.dispose();
    },
  );
}
