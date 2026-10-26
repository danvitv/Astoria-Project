import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'support_tool_loop_fixture.dart';
import '../llm/transport/_private_text_fixture.dart' show chatDelta;

Future<SupportMessage> _unanswered(ToolLoopFixture f) async =>
    (await f.native.repo.appendCurrentUser(
      message: SupportMessage(
        id: 'original-unanswered-input',
        sessionId: f.native.session,
        role: 'user',
        body: 'ORIGINAL_UNANSWERED_WORDING',
        runId: 'original-user-run',
        createdAt: 3,
      ),
      isCurrent: () => f.native.owner,
    ))!;

SupportModelMessage _selected(SupportMessage user) => SupportModelMessage(
  id: user.id,
  sessionId: user.sessionId,
  role: user.role,
  text: user.body,
  runId: user.runId!,
  status: user.status,
  createdAt: user.createdAt,
);

Future<List<SupportModelConversationMessage>> _visible(
  ToolLoopFixture f,
) async => [
  for (final m in await f.native.repo.getMessagesForSession(f.native.session))
    SupportModelConversationMessage(id: m.id, role: m.role, text: m.body),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  toolLoopTest(
    'native unanswered retry uses current global profile and original own prefix once; no registry/effects/automatic compact',
    (f) async {
      final n = f.native;
      final user = await _unanswered(f);
      n.api = n.api.copyWith(contextSize: 128);
      await n.apiRepo.put(n.api);
      final profile = n.settings.copyWith(
        temperature: 0.73,
        maxTokens: 123,
        dcpCompressionEnabled: true,
      );
      await n.workspace.changeSettings(n.session, (_) => profile);
      await n.runtime.refresh(resolve: true);
      final originalRows = await n.db.select(n.db.supportMessages).get();
      final contexts = await n.db.select(n.db.supportContextBlocks).get();
      final prefs = f.prefs
          .getKeys()
          .map((k) => '$k=${f.prefs.get(k)}')
          .toList();
      final themeWrites = f.backing.checkedWrites;
      n.primitive.decryptAads.clear();
      var registryWarmups = 0;
      final service = SupportModelService(
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
          registryWarmups++;
          throw StateError('Retry must not construct executable tools.');
        },
        admissionContract: SupportTextAdmissionContract
            .auditedRootSingleConnectionNoBusyHandler,
      );
      try {
        final visible = await _visible(f);
        final submission = service.beginRetry(
          controller: n.controller,
          uiLifetime: n.uiLifetime,
          isEmitterCurrent: () => n.emitter,
          selectedUser: _selected(user),
          visibleConversation: visible,
        );
        final duplicate = service.beginRetry(
          controller: n.controller,
          uiLifetime: n.uiLifetime,
          isEmitterCurrent: () => n.emitter,
          selectedUser: _selected(user),
          visibleConversation: visible,
        );
        expect((await duplicate.finished).reason, SupportModelRefusal.busy);
        final result = await submission.finished;
        expect(await submission.accepted, true);
        expect(result.saved, true);
        expect(result.compacted, false);
        expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(result.message!.id, isNot(user.id));
        expect(result.message!.runId, isNot(user.runId));
        expect(n.adapters, hasLength(1));
        expect(n.fetchInQueue, false);
        final wire = n.adapters.single.delegate.upload!;
        final json = jsonDecode(wire) as Map<String, dynamic>;
        expect(json['model'], profile.modelId);
        expect(json['temperature'], 0.73);
        expect(json['max_tokens'], 123);
        for (final text in [
          'ALL_PREVIOUS_USER',
          'ALL_PREVIOUS_ASSISTANT',
          user.body,
        ]) {
          expect(text.allMatches(wire), hasLength(1));
        }
        expect(wire, contains('Only THIS regeneration'));
        expect(wire, isNot(contains('"tools"')));
        expect(wire, isNot(contains('SYNTHETIC_EXCLUDED_BODY')));
        expect(registryWarmups, 0);
        expect(f.wire, isEmpty);
        expect(f.backing.checkedWrites, themeWrites);
        expect(f.prefs.getKeys().map((k) => '$k=${f.prefs.get(k)}'), prefs);
        final after = await n.db.select(n.db.supportMessages).get();
        expect(after, hasLength(originalRows.length + 1));
        for (final original in originalRows) {
          expect(after.singleWhere((row) => row.id == original.id), original);
        }
        expect(
          await n.db.select(n.db.supportContextBlocks).get(),
          hasLength(contexts.length + 1),
        );
        expect(
          n.primitive.decryptAads.where((aad) => aad.contains('hidden-body')),
          isEmpty,
        );
      } finally {
        service.dispose();
      }
    },
  );

  for (final pause in ['selected user read', 'assistant encryption']) {
    toolLoopTest(
      'Stop during unanswered retry $pause joins original futures and leaves only the same user',
      (f) async {
        final n = f.native;
        final user = await _unanswered(f);
        final visible = await _visible(f);
        final before = await n.rawMessages();
        final contexts = await n.db.select(n.db.supportContextBlocks).get();
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        Future<void> hold(String aad) async {
          if (entered.isCompleted || !aad.contains('support_messages')) return;
          if (pause == 'selected user read' && !aad.contains(user.id)) return;
          entered.complete();
          await release.future;
        }

        if (pause == 'selected user read') {
          n.primitive.beforeDecrypt = hold;
        } else {
          n.primitive.afterEncrypt = hold;
        }
        final service = n.newService();
        try {
          final submission = service.beginRetry(
            controller: n.controller,
            uiLifetime: n.uiLifetime,
            isEmitterCurrent: () => n.emitter,
            selectedUser: _selected(user),
            visibleConversation: visible,
          );
          await entered.future;
          service.stop();
          release.complete();
          final result = await submission.finished;
          expect(await submission.accepted, false);
          expect((await submission.prepared).preview, isNull);
          expect(result.accepted, false);
          expect(result.saved, false);
          expect(result.reason, SupportModelRefusal.cancelled);
          n.primitive.beforeDecrypt = null;
          n.primitive.afterEncrypt = null;
          expect(await n.rawMessages(), before);
          expect(await n.db.select(n.db.supportContextBlocks).get(), contexts);
          expect(n.adapters, isEmpty);
        } finally {
          n.primitive.beforeDecrypt = null;
          n.primitive.afterEncrypt = null;
          service.dispose();
        }
      },
    );
  }

  toolLoopTest(
    'Stop after unanswered retry admission settles only its new assistant and preserves original user',
    (f) async {
      final n = f.native;
      final user = await _unanswered(f);
      final original = (await n.db.select(n.db.supportMessages).get())
          .singleWhere((m) => m.id == user.id);
      n.quiet = true;
      n.response = chatDelta('Partial retry answer');
      final service = n.newService();
      try {
        final submission = service.beginRetry(
          controller: n.controller,
          uiLifetime: n.uiLifetime,
          isEmitterCurrent: () => n.emitter,
          selectedUser: _selected(user),
          visibleConversation: await _visible(f),
        );
        expect(await submission.accepted, true);
        await n.activity.future;
        service.stop();
        service.stop();
        final result = await submission.finished;
        expect(result.saved, true);
        expect(result.message!.role, 'assistant');
        expect(result.message!.status, 'stopped');
        expect(result.message!.id, isNot(user.id));
        expect(
          (await n.db.select(n.db.supportMessages).get()).singleWhere(
            (m) => m.id == user.id,
          ),
          original,
        );
        expect(n.adapters.single.delegate.cancelObserved.isCompleted, true);
        expect(n.adapters.single.calls, 1);
      } finally {
        service.dispose();
      }
    },
  );

  toolLoopTest(
    'retry refuses unknown native prefix provenance rather than inventing a clean origin',
    (f) async {
      final n = f.native;
      final old = (await n.repo.getMessageById('old-native-assistant'))!;
      await n.repo.putMessage(old.copyWith(runId: 'unknown-native-run'));
      final user = await _unanswered(f);
      final before = await n.rawMessages();
      final service = n.newService();
      try {
        final result = await service
            .beginRetry(
              controller: n.controller,
              uiLifetime: n.uiLifetime,
              isEmitterCurrent: () => n.emitter,
              selectedUser: _selected(user),
              visibleConversation: await _visible(f),
            )
            .finished;
        expect(result.reason, SupportModelRefusal.lineageUnavailable);
        expect(result.accepted, false);
        expect(await n.rawMessages(), before);
        expect(n.adapters, isEmpty);
      } finally {
        service.dispose();
      }
    },
  );

  toolLoopTest(
    'original native emitter retry has synchronous double-callback exclusion and immutable original futures',
    (f) async {
      final user = await _unanswered(f);
      f.replies.add(f.answer('Actual retry answer'));
      final emitter = f.bridge.bindEmitter(
        controller: f.native.controller,
        uiLifetime: f.native.uiLifetime,
        isEmitterCurrent: () => f.emitterCurrent,
        visibleConversation: await _visible(f),
      );
      final original = emitter.retry(_selected(user));
      final duplicate = emitter.retry(_selected(user));
      final future = original.finished;
      expect(original.finished, same(future));
      expect((await duplicate.finished).reason, SupportModelRefusal.busy);
      final result = await future;
      expect(await original.finished, same(result));
      expect(result.saved, true);
      expect(f.wire, hasLength(1));
      expect(f.wire.single, isNot(contains('tools')));
      expect(
        (await f.native.repo.getMessagesForSession(
          user.sessionId,
        )).where((m) => m.id == user.id),
        hasLength(1),
      );
      expect(
        f.displayed.whereType<SupportMessageItem>().where(
          (m) => m.role == SupportMessageRole.user,
        ),
        isEmpty,
      );
      expect(f.bridge.view.busy, false);
    },
  );
}
