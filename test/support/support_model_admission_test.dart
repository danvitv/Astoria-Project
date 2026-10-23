import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/reserved_text_admission_fixture.dart';
import 'helpers/support_model_fixture.dart';
import 'support_model_service_test.dart' show isolated, confirm;

void main() {
  isolated(
    'actual feature capsule fetch fences independent B, releases before HTTP/write queue',
    () async {
      final native = await ReservedTextAdmissionFixture.create(
        populated: false,
      );
      final f = await SupportModelFixture.create(native: native);
      try {
        f.observeBusy = true;
        f.quiet = true;
        f.responseBody = () => chatDelta('Verified prefix');
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        final result = f.service.dispatch(f.service.approve(preview)!);
        await f.activity.future;
        expect(
          f.fetchWriterBusy,
          isTrue,
        ); // Recorded OUTSIDE swallowed callbacks.
        expect(f.fetchInQueue, isFalse);
        expect(native.otherWriterBusy(), isFalse);
        await native.ownWrite(); // While actual quiet SSE remains active.
        native.otherWrite();
        expect(f.queue.active, isFalse);
        f.service.stop();
        final finished = await result;
        expect(finished.accepted, isTrue);
        expect(
          finished.saved,
          isTrue,
        ); // Source stamp is NOT settlement authority.
        expect(finished.message!.status, 'stopped');
        expect(finished.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(f.adapters.single.calls, 1);
        expect(native.otherWriterBusy(), isFalse);
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'B commit at actual adapter factory invalidates feature preview before fetch',
    () async {
      final native = await ReservedTextAdmissionFixture.create(
        populated: false,
      );
      final f = await SupportModelFixture.create(native: native);
      try {
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        f.onFactory = native.otherWrite;
        final result = await f.service.dispatch(f.service.approve(preview)!);
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
        expect(f.adapters.single.calls, 0);
        expect(native.otherWriterBusy(), isFalse);
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'redactor replacement inside real ROOT denies before synchronous capsule fetch',
    () async {
      final native = await ReservedTextAdmissionFixture.create(
        populated: false,
      );
      final f = await SupportModelFixture.create(native: native);
      try {
        final submission = await f.submit();
        final preparation = await submission.prepared;
        expect(preparation.reason, SupportModelRefusal.none);
        final preview = preparation.preview!;
        native.spy.afterReserve = () async {
          f.redaction.registerSecret('Native question');
        };
        final result = await f.service.dispatch(f.service.approve(preview)!);
        expect(result.accepted, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
        expect(f.adapters.single.calls, 0);
        await native.db.customSelect('SELECT 1').getSingle();
        expect(native.otherWriterBusy(), isFalse);
        expect(result.message?.text, isNot(contains('Native question')));
      } finally {
        native.spy.afterReserve = null;
        await f.close();
      }
    },
  );

  for (final staleRetry in [false, true]) {
    isolated(
      '408 real feature read-only admission repeated; stale second=$staleRetry',
      () async {
        final native = await ReservedTextAdmissionFixture.create(
          populated: false,
        );
        final f = await SupportModelFixture.create(native: native);
        try {
          f.status = 408;
          f.onFetch = () {
            f.status = 200;
          };
          if (staleRetry) {
            f.onFactory = () {
              if (f.adapters.isNotEmpty) native.otherWrite();
            };
          }
          final result = await confirm(f, await f.submit());
          expect(f.adapters.length, 2);
          expect(f.adapters.first.calls, 1);
          expect(f.adapters.last.calls, staleRetry ? 0 : 1);
          expect(result.accepted, isTrue);
          expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
          expect(
            result.outcome!.status,
            staleRetry ? PrivateTextStatus.error : PrivateTextStatus.complete,
          );
          expect(f.adapters.first.delegate.responseListens, 0);
          expect(native.otherWriterBusy(), isFalse);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final lateError in [false, true]) {
    isolated(
      'pure vault root read Stop, late error=$lateError; no late SQL',
      () async {
        final native = await ReservedTextAdmissionFixture.create(
          populated: false,
        );
        final f = await SupportModelFixture.create(
          native: native,
          manualTimers: true,
        );
        final entered = Completer<void>(), release = Completer<void>();
        try {
          final submission = await f.submit();
          final preview = (await submission.prepared).preview!;
          var armed = false;
          native.spy.afterReserve = () async {
            native.storage.beforeRead = () async {
              if (armed) return;
              armed = true;
              entered.complete();
              await release.future;
              if (lateError) throw const UnprintableAdmissionError();
            };
          };
          final result = f.service.dispatch(f.service.approve(preview)!);
          await entered.future;
          expect(native.otherWriterBusy(), isTrue);
          // Revoke ORIGINAL data owner explicitly to isolate H cleanup from the
          // deliberately unchanged write-cipher S wait. Other tests establish S.
          f.service.revokeSettlementOwner();
          final finished = await result;
          expect(finished.accepted, isTrue);
          expect(finished.saved, isFalse);
          expect(finished.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
          // A real ordinary query queues behind H and proves actual ROOT release,
          // not merely T's cancel race returning before admission completes.
          await native.db.customSelect('SELECT 1').getSingle();
          expect(native.otherWriterBusy(), isFalse);
          native.otherWrite();
          await native.ownWrite();
          final events = List.of(native.spy.events);
          expect(f.adapters.single.calls, 0);
          release.complete();
          native.storage.beforeRead = null;
          native.spy.afterReserve = null;
          // Drain the same original key/vault owner using PURE work, no SQL.
          await native.cipher.decrypt(
            envelopeText: native.originalEnvelope,
            table: 'support_messages',
            rowId: 'history',
            sessionId: 'session',
            field: 'body_ciphertext',
          );
          expect(native.spy.events, events);
          expect(f.adapters.single.calls, 0);
        } finally {
          if (!release.isCompleted) release.complete();
          native.storage.beforeRead = null;
          native.spy.afterReserve = null;
          await f.close();
        }
      },
    );
  }

  isolated(
    'real read deadline unwinds ROOT normally while original vault future stays paused',
    () async {
      final native = await ReservedTextAdmissionFixture.create(
        populated: false,
      );
      final f = await SupportModelFixture.create(
        native: native,
        manualTimers: true,
      );
      final entered = Completer<void>(), release = Completer<void>();
      try {
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        var armed = false;
        native.spy.afterReserve = () async {
          native.storage.beforeRead = () async {
            if (armed) return;
            armed = true;
            entered.complete();
            await release.future;
          };
        };
        final result = f.service.dispatch(f.service.approve(preview)!);
        await entered.future;
        f.timers
            .where(
              (t) => t.isActive && t.duration == const Duration(seconds: 5),
            )
            .single
            .fire();
        f.service
            .revokeSettlementOwner(); // Isolate H release from ordinary S/FIFO wait.
        final finished = await result;
        await native.db.customSelect('SELECT 1').getSingle();
        expect(native.otherWriterBusy(), isFalse);
        expect(f.adapters.single.calls, 0);
        expect(finished.accepted, isTrue);
        expect(finished.saved, isFalse);
        // Original pure work still paused at proven ROOT release. No SQL-owning
        // callback was timed out. S custody was explicitly revoked, not forged.
        native.storage.beforeRead = null;
        release.complete();
        native.spy.afterReserve = null;
        await native.cipher.decrypt(
          envelopeText: native.originalEnvelope,
          table: 'support_messages',
          rowId: 'history',
          sessionId: 'session',
          field: 'body_ciphertext',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        native.storage.beforeRead = null;
        native.spy.afterReserve = null;
        await f.close();
      }
    },
  );

  isolated(
    'overall native deadline cancels quiet real adapter and settles exactly once',
    () async {
      final f = await SupportModelFixture.create(manualTimers: true);
      try {
        f.quiet = true;
        f.responseBody = () => chatDelta('Before deadline');
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        final result = f.service.dispatch(f.service.approve(preview)!);
        await f.activity.future;
        f.timers
            .where(
              (t) => t.isActive && t.duration == PrivateTextLimits.deadline,
            )
            .first
            .fire();
        final finished = await result;
        expect(finished.reason, SupportModelRefusal.deadline);
        expect(finished.accepted, isTrue);
        expect(finished.saved, isTrue);
        expect(finished.message!.status, 'stopped');
        await f.adapters.single.delegate.cancelObserved.future;
        expect(f.adapters.single.calls, 1);
      } finally {
        await f.close();
      }
    },
  );
}
