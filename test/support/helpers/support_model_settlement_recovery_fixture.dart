import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'support_model_fixture.dart';

typedef SettlementRecoverySnapshot = ({
  SupportMessage reply,
  SupportContextBlock provenance,
  String rows,
});

/// Existing declared-memory DB/fake vault/real AEAD owner, with a terminal FIFO
/// barrier and a socket-free response. No provider or private transport fixtures
/// are inspected or modified; only the public native service seams are composed.
final class SupportModelSettlementRecoveryFixture {
  SupportModelSettlementRecoveryFixture._(this.base) {
    base.service.dispose(); // No input was emitted by the initial service.
    queue = SettlementRecoveryQueue(base.queue);
    base.service = SupportModelService(
      db: base.db,
      writeCipher: base.cipher,
      apiRepo: base.apiRepo,
      revisions: base.revisions,
      redaction: base.redaction,
      runtime: base.runtime,
      isOwnerCurrent: () => base.owner,
      writes: queue,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
      newId: () => 'recovery-${++serial}',
      now: () => 20,
      scheduleTimer: (duration, callback) {
        final timer = ModelManualTimer(duration, callback);
        base.timers.add(timer);
        return timer;
      },
      onMessage: base.published.add,
      onPhase: (phase) {
        base.phases.add(phase);
        if (phase == SupportModelPhase.settling && holdTerminal) {
          queue.holdNext = true;
        }
      },
      adapterFactory: () {
        factories++;
        return adapter;
      },
    );
  }

  final SupportModelFixture base;
  late final SettlementRecoveryQueue queue;
  final adapter = SettlementRecoveryAdapter();
  int serial = 0, factories = 0;
  bool holdTerminal = false;
  SupportModelSubmission? submission;
  late SupportModelPreview preview;

  SupportModelService get service => base.service;
  String get replyId => preview.replyMessageId;
  String get provenanceId => 'support.reply_provenance:$replyId';
  String get bodyAad =>
      'astoria.support.v1|support_messages|$replyId|${preview.sessionId}|body_ciphertext';

  static Future<SupportModelSettlementRecoveryFixture> create() async =>
      SupportModelSettlementRecoveryFixture._(
        await SupportModelFixture.create(manualTimers: true),
      );

  Future<void> prepare() async {
    submission = await base.submit('Synthetic recovery question');
    final prepared = await submission!.prepared;
    if (prepared.preview == null) {
      throw StateError('Synthetic recovery preview refused');
    }
    preview = prepared.preview!;
  }

  Future<SupportModelRunResult> dispatch() {
    final approval = service.approve(preview);
    if (approval == null) {
      throw StateError('Synthetic recovery approval refused');
    }
    return service.dispatch(approval);
  }

  Future<SettlementRecoverySnapshot> snapshot() async {
    final reply = await base.repo.getMessageById(replyId);
    final provenance = await base.repo.getContextBlockById(provenanceId);
    if (reply == null || provenance == null) {
      throw StateError('Synthetic recovery reservation missing');
    }
    final rows = <String, Object?>{};
    for (final table in const [
      'support_sessions',
      'support_messages',
      'support_context_blocks',
    ]) {
      rows[table] =
          (await base.db
                  .customSelect('SELECT * FROM "$table" ORDER BY id')
                  .get())
              .map((row) => row.data)
              .toList();
    }
    return (reply: reply, provenance: provenance, rows: jsonEncode(rows));
  }

  void clearHooks() {
    base.primitive.afterEncrypt = null;
    base.primitive.beforeDecrypt = null;
    base.sql.afterSelect = null;
    base.sql.afterWrite = null;
    base.storage.beforeRead = null;
    base.storage.beforeWrite = null;
  }

  Future<void> close() async {
    clearHooks();
    queue.release();
    service.stop();
    await submission?.finished;
    await base.close();
  }
}

/// Hold exactly the already-enqueued terminal callback before executing it, not
/// SQL, H, fetch or a read. Normal FIFO ordering and the original callback stay
/// intact. queued proves terminal enqueue, not a transport phase guess.
final class SettlementRecoveryQueue implements SupportModelWriteScheduler {
  SettlementRecoveryQueue(this.delegate);
  final SupportModelWriteScheduler delegate;
  final queued = Completer<void>(), _release = Completer<void>();
  bool holdNext = false;

  @override
  Future<T> enqueue<T>(Future<T> Function() write) {
    if (!holdNext) return delegate.enqueue(write);
    holdNext = false;
    final result = delegate.enqueue(() async {
      await _release.future;
      return write();
    });
    queued.complete();
    return result;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

/// One ordinary complete Chat Completions SSE response through actual fetch.
/// Captures no credential/request data and never creates a network client.
final class SettlementRecoveryAdapter implements HttpClientAdapter {
  String text = 'Synthetic recovery answer';
  int calls = 0;
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    await requestStream?.drain<void>();
    final event = jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
          'finish_reason': 'stop',
        },
      ],
    });
    return ResponseBody(
      Stream.value(
        Uint8List.fromList(utf8.encode('data: $event\n\ndata: [DONE]\n\n')),
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}
