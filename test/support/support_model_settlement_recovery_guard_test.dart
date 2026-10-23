import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'helpers/support_model_settlement_recovery_fixture.dart';

void main() {
  test(
    'policy replacement during terminal AEAD rolls back to pending',
    () async {
      final f = await SupportModelSettlementRecoveryFixture.create();
      addTearDown(f.close);
      await f.prepare();
      final before = await f.snapshot();
      expect(before.reply.status, 'pending');
      expect(before.reply.body, isEmpty);
      final published = f.base.published.length;
      const canary = 'SYNTHETIC_AEAD_POLICY_CANARY_827';
      f.adapter.text = 'Safe $canary';
      final reached = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      f.base.primitive.afterEncrypt = (aad) async {
        if (aad != f.bodyAad || reached.isCompleted) return;
        reached.complete();
        await release.future;
      };
      final result = f.dispatch();
      await reached.future;
      final captured = f.base.redaction.redactor;
      f.base.redaction.registerSecret(canary);
      expect(identical(captured, f.base.redaction.redactor), isFalse);
      release.complete();
      final finished = await result;
      f.clearHooks();
      expect(finished.accepted, isTrue);
      expect(finished.saved, isFalse);
      expect(finished.reason, SupportModelRefusal.settlementFailed);
      expect(finished.message, isNull);
      expect(finished.outcome!.text, 'Safe ${SecretRedactor.removed}');
      expect((await f.snapshot()).rows, before.rows);
      expect(f.base.published.length, published);
      expect(f.adapter.calls, 1);
    },
  );

  test(
    'policy replacement during mapped return rolls back provisional update',
    () async {
      final f = await SupportModelSettlementRecoveryFixture.create();
      addTearDown(f.close);
      await f.prepare();
      final before = await f.snapshot();
      expect(before.reply.status, 'pending');
      expect(before.reply.body, isEmpty);
      final published = f.base.published.length;
      const canary = 'SYNTHETIC_MAPPED_POLICY_CANARY_619';
      f.adapter.text = 'Safe $canary';
      final reached = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var provisionalUpdate = false;
      f.base.sql.afterWrite = (statement) async {
        if (statement.startsWith('UPDATE "support_messages"')) {
          provisionalUpdate = true;
        }
      };
      f.base.primitive.beforeDecrypt = (aad) async {
        if (aad != f.bodyAad || !provisionalUpdate || reached.isCompleted) {
          return;
        }
        reached.complete();
        await release.future;
      };
      final result = f.dispatch();
      await reached.future;
      expect(provisionalUpdate, isTrue);
      // The actual selected row already carried terminal status inside the open
      // transaction; this is mapped-return rollback, not pre-write refusal.
      expect(
        f.base.sql.observations.any(
          (observation) => observation.rows.any(
            (row) => row['id'] == f.replyId && row['status'] == 'complete',
          ),
        ),
        isTrue,
      );
      final captured = f.base.redaction.redactor;
      f.base.redaction.registerSecret(canary);
      expect(identical(captured, f.base.redaction.redactor), isFalse);
      release.complete();
      final finished = await result;
      f.clearHooks();
      expect(finished.accepted, isTrue);
      expect(finished.saved, isFalse);
      expect(finished.reason, SupportModelRefusal.settlementFailed);
      expect(finished.message, isNull);
      expect(finished.outcome!.text, 'Safe ${SecretRedactor.removed}');
      expect((await f.snapshot()).rows, before.rows);
      expect(f.base.published.length, published);
      expect(f.adapter.calls, 1);
    },
  );
}
