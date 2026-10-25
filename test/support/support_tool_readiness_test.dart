import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'support_provider_model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'broken native registry refuses before wire instead of claiming text-only',
    () async {
      final f = await SupportProviderModelFixture.create();
      f.service.dispose();
      final native = f.native;
      final service = SupportModelService(
        db: f.db,
        writeCipher: f.cipher,
        apiRepo: f.apiRepo,
        revisions: f.revisions,
        redaction: f.redaction,
        runtime: f.runtime,
        adapterFactory: f.adapter,
        isOwnerCurrent: () => f.rootCurrent && native.isCurrent,
        writes: f.queue,
        nativeSources: native.sources,
        nativeMetadata: native.credentialReader,
        admissionContract: SupportTextAdmissionContract
            .auditedRootSingleConnectionNoBusyHandler,
        toolTransport: NativeToolTransport(
          credentials: native.credentials,
          authIssuer: native.auth,
          mutations: native.mutations,
          routes: native.routes,
          currentRedactor: () => f.redaction.redactor,
          adapterFactory: f.adapter,
        ),
        // Its presence is required by saved native-source preparation, but no
        // transport may be constructed after the actual registry fails.
        nativeDispatcher: (_) => throw StateError('Unexpected text fallback'),
        appActionsFactory: () => throw StateError('SYNTHETIC_REGISTRY_CAUSE'),
      );
      try {
        final emission = await service.emitInput(
          controller: f.controller,
          uiLifetime: f.uiLifetime,
          draftRevision: 1,
          text: 'Смени тему.',
          isEmitterCurrent: () => true,
          isDraftCurrent: () => true,
          directConversation: true,
          visibleConversation: const [],
        );
        expect(emission.intent, isNotNull);
        final submission = service.beginSend(emission.intent!);
        final result = await submission.finished;
        expect(await submission.accepted, true);
        expect(result.reason, SupportModelRefusal.toolsUnavailable);
        expect(result.reason.label, contains('Запрос не отправлен'));
        expect(
          result.reason.label,
          isNot(contains('SYNTHETIC_REGISTRY_CAUSE')),
        );
        expect(f.adapters, isEmpty);
      } finally {
        service.dispose();
      await f.close();
      }
    },
  );
}
