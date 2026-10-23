import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_outcome.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'helpers/support_model_fixture.dart';
import 'helpers/support_model_settlement_recovery_fixture.dart';

void main() {
  test('queued terminal body uses newly registered current policy', () async {
    final f = await SupportModelSettlementRecoveryFixture.create();
    addTearDown(f.close);
    await f.prepare();
    final before = await f.snapshot();
    final published = f.base.published.length;
    const canary = 'SYNTHETIC_QUEUED_TERMINAL_CANARY_591';
    f.adapter.text = 'Safe $canary ${SupportModelFixture.rowKey}';
    f.holdTerminal = true;
    final result = f.dispatch();
    await f.queue.queued.future;
    expect(f.adapter.calls, 1);
    expect((await f.snapshot()).rows, before.rows);
    final oldPolicy = f.base.redaction.redactor;
    expect(oldPolicy.redactText(canary), canary);
    f.base.redaction.registerSecret(canary);
    expect(identical(oldPolicy, f.base.redaction.redactor), isFalse);
    f.queue.release();

    final finished = await result;
    final after = await f.snapshot();
    expect(finished.accepted, isTrue);
    expect(finished.saved, isTrue);
    expect(finished.message!.text, 'Safe [REDACTED] [REDACTED]');
    expect(finished.outcome!.text, finished.message!.text);
    expect(finished.outcome!.status, PrivateTextStatus.complete);
    expect(
      after.reply,
      before.reply.copyWith(body: finished.message!.text, status: 'complete'),
    );
    expect(after.provenance, before.provenance);
    // Policy replacement retires display/network authority, not original DB
    // custody. The safe durable DTO returns without repainting a stale owner.
    expect(f.base.published.length, published);
    expect(after.reply.body, isNot(contains(canary)));
    expect(after.reply.body, isNot(contains(SupportModelFixture.rowKey)));
    expect(after.reply.body, contains(SecretRedactor.removed));
    expect(f.adapter.calls, 1);
  });

  test('synchronous API key mutation settles original preview once', () async {
    final f = await SupportModelSettlementRecoveryFixture.create();
    addTearDown(f.close);
    await f.prepare();
    final before = await f.snapshot();
    final approval = f.service.approve(f.preview)!;
    final entries = f.base.queue.entries;
    f.base.api = f.base.api.copyWith(apiKey: SupportModelFixture.newRowKey);
    await f.base.apiRepo.put(f.base.api);
    final finished = await f.submission!.finished;
    final after = await f.snapshot();
    expect(finished.accepted, isTrue);
    expect(finished.saved, isTrue);
    expect(finished.reason, SupportModelRefusal.stale);
    expect(after.reply, before.reply.copyWith(body: '', status: 'stopped'));
    expect(after.provenance, before.provenance);
    expect(f.preview.isCurrent, isFalse);
    expect(finished.message!.id, before.reply.id);
    expect(finished.message!.runId, before.reply.runId);
    expect(finished.message!.status, 'stopped');
    expect(f.base.queue.entries, entries + 1);
    expect(identical(await f.service.dispatch(approval), finished), isTrue);
    expect(f.base.queue.entries, entries + 1);
    expect(f.factories, 0);
    expect(f.adapter.calls, 0);
  });

  test('ordinary repeated Stop retains exact original reservation', () async {
    final f = await SupportModelSettlementRecoveryFixture.create();
    addTearDown(f.close);
    await f.prepare();
    final before = await f.snapshot();
    final entries = f.base.queue.entries;
    final published = f.base.published.length;
    f.holdTerminal = true;
    f.service.stop();
    await f.queue.queued.future;
    f.service.stop();
    f.service.cancelPreview(f.preview);
    expect((await f.snapshot()).rows, before.rows);
    f.queue.release();
    final finished = await f.submission!.finished;
    final after = await f.snapshot();
    expect(finished.accepted, isTrue);
    expect(finished.saved, isTrue);
    expect(finished.reason, SupportModelRefusal.cancelled);
    expect(finished.outcome, isNull);
    expect(after.reply, before.reply.copyWith(body: '', status: 'stopped'));
    expect(after.provenance, before.provenance);
    expect(finished.message!.sessionId, before.reply.sessionId);
    expect(finished.message!.createdAt, before.reply.createdAt);
    expect(f.base.queue.entries, entries + 1);
    expect(f.base.published.length, published + 1);
    f.service.stop();
    expect((await f.snapshot()).rows, after.rows);
    expect(f.base.queue.entries, entries + 1);
    expect(f.factories, 0);
  });

  test(
    'removed target is not recreated by queued terminal settlement',
    () async {
      final f = await SupportModelSettlementRecoveryFixture.create();
      addTearDown(f.close);
      await f.prepare();
      final before = await f.snapshot();
      final published = f.base.published.length;
      f.holdTerminal = true;
      f.service.stop();
      await f.queue.queued.future;
      // Repository absence must refuse even without an explicit service notice.
      await f.base.repo.deleteMessage(f.replyId);
      f.queue.release();
      final finished = await f.submission!.finished;
      expect(finished.accepted, isTrue);
      expect(finished.saved, isFalse);
      expect(finished.reason, SupportModelRefusal.settlementFailed);
      expect(finished.message, isNull);
      expect(await f.base.repo.getMessageById(f.replyId), isNull);
      expect(
        await f.base.repo.getContextBlockById(f.provenanceId),
        before.provenance,
      );
      expect(f.base.published.length, published);
      expect(f.factories, 0);
    },
  );

  test(
    'actual settlement custody revocation stays refused with fresh policy',
    () async {
      final f = await SupportModelSettlementRecoveryFixture.create();
      addTearDown(f.close);
      await f.prepare();
      final before = await f.snapshot();
      final published = f.base.published.length;
      f.holdTerminal = true;
      f.service.stop();
      await f.queue.queued.future;
      f.service.revokeSettlementOwner();
      f.base.redaction.registerSecret('SYNTHETIC_CUSTODY_REPLACEMENT_483');
      f.queue.release();
      final finished = await f.submission!.finished;
      expect(finished.accepted, isTrue);
      expect(finished.saved, isFalse);
      expect(finished.reason, SupportModelRefusal.settlementFailed);
      expect(finished.message, isNull);
      expect((await f.snapshot()).rows, before.rows);
      expect(f.base.published.length, published);
      expect(f.factories, 0);
    },
  );
}
