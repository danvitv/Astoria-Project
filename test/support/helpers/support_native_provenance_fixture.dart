import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_native_provenance_validator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'support_text_context_fixture.dart';

/// Tripwire spans fixture creation, body and cleanup, not only adapter dispatch.
void isolatedProvenance(String name, Future<void> Function() body) {
  test(name, () async {
    var clients = 0;
    await HttpOverrides.runZoned(
      body,
      createHttpClient: (_) {
        clients++;
        throw StateError('Synthetic provenance fixture forbids native HTTP');
      },
    );
    expect(clients, 0);
  });
}

SupportModelProvenance nativeRecipe() => SupportModelProvenance(
  supportSessionId: SupportTextContextFixture.supportId,
  replyMessageId: 'support-b',
  runId: 'synthetic-run',
  currentUserMessageId: 'support-a',
  originalRanges: [
    SupportModelSourceRange(
      domain: SupportModelSourceDomain.game,
      sessionId: 'synthetic-game',
      orderedMessageIds: ['game-a', 'game-b'],
    ),
  ],
  directReplies: [
    SupportModelReplyReference(
      sessionId: SupportTextContextFixture.supportId,
      messageId: 'ancestor',
      runId: 'ancestor-run',
    ),
  ],
);

Map<String, dynamic> nativeRecipeObject() =>
    jsonDecode(
          SupportModelProvenanceCodec.encodeForEncryptedStorage(nativeRecipe()),
        )
        as Map<String, dynamic>;

/// Reuses ONLY declared-memory/real-AEAD/FakeStorage source affordances. No
/// fabricated snapshot or relaxed codec/policy. ROOT uses the initialized SAME
/// memory connection, not the separate file-backed A/B helper.
final class NativeProvenanceFixture {
  final source = SupportTextContextFixture();
  Future<void> seed([String? facts]) async {
    await source.seed();
    await source.db.customStatement('PRAGMA busy_timeout = 0');
    await (source.db.update(source.db.supportMessages)
          ..where((t) => t.id.equals('support-b')))
        .write(const SupportMessagesCompanion(runId: Value('synthetic-run')));
    await source.provenance(
      'support-b',
      facts ??
          SupportModelProvenanceCodec.encodeForEncryptedStorage(nativeRecipe()),
      time: 3,
    );
  }

  SupportTextContextRepo reader({
    SupportNativeProvenanceValidator? validator =
        SupportModelNativeProvenanceValidator.validate,
  }) => SupportTextContextRepo(
    db: source.db,
    cipher: source.cipher,
    currentRedactor: () => source.redactor,
    admissionContract:
        SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
    nativeProvenanceValidator: validator,
  );

  Future<SupportTextContextSnapshot> load(SupportTextContextRepo reader) =>
      reader.loadSupport(
        sessionId: SupportTextContextFixture.supportId,
        messageIds: ['support-a', 'support-b'],
      );

  Future<bool> root(
    SupportTextContextRepo reader,
    SupportTextContextSnapshot snapshot,
    void Function() dispatch, {
    Future<bool> Function(void Function())? check,
  }) => reader.admitDispatch(
    snapshots: [snapshot],
    isCurrent: () => true,
    checkReadOnly:
        check ??
        (checkpoint) async {
          checkpoint();
          return true;
        },
    dispatch: dispatch,
  );

  Future<void> replaceFacts(
    String facts, {
    String? row,
    String? session,
    String? field,
  }) async {
    final envelope = await source.encrypt(
      facts,
      'support_context_blocks',
      row ?? 'support.reply_provenance:support-b',
      session ?? SupportTextContextFixture.supportId,
      field ?? 'protected_facts_ciphertext',
    );
    await (source.db.update(
      source.db.supportContextBlocks,
    )..where((t) => t.id.equals('support.reply_provenance:support-b'))).write(
      SupportContextBlocksCompanion(protectedFactsCiphertext: Value(envelope)),
    );
  }

  Future<void> close() => source.close();
}
