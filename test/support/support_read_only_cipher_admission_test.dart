import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../llm/transport/_private_text_fixture.dart' show privateRequest;
import 'helpers/read_only_cipher_fixture.dart';
import 'helpers/reserved_text_admission_fixture.dart';

/// Existing A/B declared-schema-only fixture is READ-ONLY reused. No App/default
/// DB/OS vault/network. T uses a synthetic actual adapter, not a replacement H.
Future<void> _seedProvenance(ReservedTextAdmissionFixture f) async {
  const id = 'support.reply_provenance:history';
  final facts = await f.encrypt(
    '{"synthetic":"dedicated-facts"}',
    'support_context_blocks',
    id,
    'protected_facts_ciphertext',
  );
  await f.db.customStatement(
    'UPDATE support_messages SET run_id = ?, cards_ciphertext = ? WHERE id = ?',
    ['synthetic-run', 'SYNTHETIC_UNSELECTED_CARDS_328a', 'history'],
  );
  await f.db.customStatement(
    'INSERT INTO support_context_blocks (id, session_id, start_message_id, end_message_id, summary_ciphertext, protected_facts_ciphertext, is_active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      id,
      'session',
      'history',
      'history',
      'SYNTHETIC_UNSELECTED_SUMMARY_801b',
      facts,
      0,
      2,
    ],
  );
}

SupportTextContextRepo _reader(
  ReservedTextAdmissionFixture f,
  SupportCipherReadGate gate,
) => SupportTextContextRepo(
  db: f.db,
  cipher: SupportPayloadCipher.readOnly(delegate: f.cipher, gate: gate),
  currentRedactor: () => f.redactor,
  admissionContract:
      SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
);

Future<PrivateTextOutcome> _run(
  ReservedTextAdmissionFixture f,
  ReservedFixtureAdapter adapter,
  CancelToken token,
  PrivateTextAdmission admit,
) =>
    PrivateTextTransport(
      adapterFactory: () => adapter,
      currentRedactor: () => f.redactor,
      authorize: (_) => throw StateError('Weak authorization must never run'),
      admit: admit,
    ).generate(
      protocol: LlmProtocol.openai,
      request: privateRequest(),
      approvedRecipient: Uri.parse(privateRequest().endpoint),
      cancelToken: token,
      isCurrent: () => !token.isCancelled,
    );

void main() {
  for (final boundary in ['storage', 'primitive']) {
    for (final phase in ['title', 'body', 'provenance']) {
      for (final deadline in [false, true]) {
        for (final lateError in [false, true]) {
          test(
            'real H releases BEFORE late $boundary/$phase; deadline $deadline/error $lateError; zero later SQL/fetch/publication',
            () async {
              final f = await ReservedTextAdmissionFixture.create();
              addTearDown(f.close);
              await _seedProvenance(f);
              final token = CancelToken();
              final clock = ManualReadDeadline();
              final budget = CipherReadBudget(token, clock);
              final repo = _reader(f, budget.call);
              final preview = await repo.loadSupport(
                sessionId: 'session',
                messageIds: ['history'],
              );
              expect(preview.messages.single.text, 'Reviewed history');
              expect(
                preview.provenance.single.dedicatedFactsJson,
                '{"synthetic":"dedicated-facts"}',
              );
              final before = await f.stamp();
              final bytes = await f.tableBytes();
              final keys = Map<String, String>.from(f.storage.values);
              f.storage.operations.clear();
              f.primitive.decryptAads.clear();
              final target = ['title', 'body', 'provenance'].indexOf(phase) + 1;
              var rawReads = 0;
              var primitiveCalls = 0;
              final pause = ReadPause();
              addTearDown(pause.release);
              if (boundary == 'storage') {
                f.storage.beforeRead = () async {
                  rawReads++;
                  if (rawReads == target) await pause.hold();
                };
              } else {
                f.primitive.beforeDecrypt = (_) async {
                  primitiveCalls++;
                  if (primitiveCalls != target) return;
                  await pause.hold();
                  if (lateError) throw const UnprintableReadError();
                };
              }
              final settledBefore = budget.settledCount;
              final cleanup = Completer<void>();
              final adapter = ReservedFixtureAdapter();
              var publications = 0;
              f.spy.events.clear();
              final pending =
                  _run(f, adapter, token, (capsule) async {
                    try {
                      return await repo.admitDispatch(
                        snapshots: [preview],
                        isCurrent: () => capsule.isCurrent,
                        checkReadOnly: f.readOnlyPolicy,
                        dispatch: capsule.dispatch,
                      );
                    } finally {
                      cleanup.complete(); // AFTER actual H/Drift completion.
                    }
                  }).then((outcome) {
                    if (outcome.status == PrivateTextStatus.complete) {
                      publications++;
                    }
                    return outcome;
                  });
              await pause.entered.future;
              expect(f.otherWriterBusy(), true); // Actual independent B BEGIN.
              expect(
                f.primitive.decryptAads,
                hasLength(boundary == 'storage' ? target - 1 : target),
              );
              final lateSettled = budget.settled;
              if (deadline) {
                clock.expire();
              } else {
                token.cancel();
              }
              await cleanup
                  .future; // Never race/timeout the SQL-owning callback.
              final outcome = await pending;
              expect(outcome.dispatch, PrivateTextDispatch.notAdmitted);
              expect(outcome.text, isEmpty);
              expect(outcome.status, isNot(PrivateTextStatus.complete));
              expect(adapter.fetches, 0);
              expect(publications, 0);
              expect(budget.settledCount, settledBefore + target - 1);
              expect(
                f.otherWriterBusy(),
                false,
              ); // Release while pure still held.
              expect(await f.stamp(), before); // No counter subtraction/rebase.
              expect(await f.tableBytes(), bytes);
              expect(f.storage.values, keys);
              expect(f.storage.operations.every((op) => op == 'read'), true);
              f.otherWrite(); // B and ordinary A both writable before late pure.
              await f.ownWrite();
              final events = List<String>.from(f.spy.events);
              if (boundary == 'storage' && lateError) {
                f.storage.readError = const UnprintableReadError();
              }
              pause.release();
              await lateSettled;
              expect(budget.settledCount, settledBefore + target);
              expect(
                f.spy.events,
                events,
              ); // No source/provenance/after-stamp SQL.
              expect(adapter.fetches, 0);
              expect(publications, 0);
              expect(f.storage.values, keys);
              f.storage.beforeRead = null;
              f.storage.readError = null;
              f.primitive.beforeDecrypt = null;
              // Verify ordinary owner still usable without reviving denied H.
              expect(
                await f.cipher.decrypt(
                  envelopeText: f.originalEnvelope,
                  table: 'support_messages',
                  rowId: 'history',
                  sessionId: 'session',
                  field: 'body_ciphertext',
                ),
                'Reviewed history',
              );
            },
          );
        }
      }
    }
  }

  test(
    'real H successful bounded read keeps writer until actual fetch, then releases before response',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      await _seedProvenance(f);
      final token = CancelToken();
      final budget = CipherReadBudget(token, ManualReadDeadline());
      final repo = _reader(f, budget.call);
      final preview = await repo.loadSupport(
        sessionId: 'session',
        messageIds: ['history'],
      );
      final before = await f.stamp();
      final bytes = await f.tableBytes();
      bool? busyAtFetch;
      final adapter = ReservedFixtureAdapter(
        onFetch: () {
          busyAtFetch = f.otherWriterBusy();
        },
      );
      final released = Completer<void>();
      final pending = _run(f, adapter, token, (capsule) async {
        try {
          return await repo.admitDispatch(
            snapshots: [preview],
            isCurrent: () => capsule.isCurrent,
            checkReadOnly: f.readOnlyPolicy,
            dispatch: capsule.dispatch,
          );
        } finally {
          released.complete();
        }
      });
      await released.future;
      expect(busyAtFetch, true);
      expect(adapter.fetches, 1);
      expect(adapter.response.isCompleted, false);
      expect(f.otherWriterBusy(), false);
      expect(await f.stamp(), before);
      expect(await f.tableBytes(), bytes);
      adapter.complete();
      final outcome = await pending;
      expect(outcome.status, PrivateTextStatus.complete);
      expect(outcome.dispatch, PrivateTextDispatch.admitted);
    },
  );

  for (final deadline in [false, true]) {
    test(
      'real H read-only POLICY decrypt raw vault wait releases before late pure: $deadline',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final token = CancelToken();
        final clock = ManualReadDeadline();
        final budget = CipherReadBudget(token, clock);
        final read = SupportPayloadCipher.readOnly(
          delegate: f.cipher,
          gate: budget.call,
        );
        final repo = _reader(f, budget.call);
        final pause = ReadPause();
        addTearDown(pause.release);
        f.storage.beforeRead = pause.hold;
        final adapter = ReservedFixtureAdapter();
        final cleanup = Completer<void>();
        final pending = _run(f, adapter, token, (capsule) async {
          try {
            return await repo.admitDispatch(
              snapshots: const <SupportTextContextSnapshot>[],
              isCurrent: () => capsule.isCurrent,
              checkReadOnly: (checkpoint) async {
                final header = await f.db
                    .customSelect(
                      'SELECT title_ciphertext FROM support_sessions WHERE id = ?',
                      variables: [Variable.withString('session')],
                    )
                    .getSingle();
                checkpoint();
                await read.decrypt(
                  envelopeText: header.read<String>('title_ciphertext'),
                  table: 'support_sessions',
                  rowId: 'session',
                  sessionId: 'session',
                  field: 'title_ciphertext',
                );
                checkpoint();
                // Must not execute this next owning SQL after canceled decrypt.
                return f.readOnlyPolicy(checkpoint);
              },
              dispatch: capsule.dispatch,
            );
          } finally {
            cleanup.complete();
          }
        });
        await pause.entered.future;
        expect(f.otherWriterBusy(), true);
        if (deadline) {
          clock.expire();
        } else {
          token.cancel();
        }
        await cleanup.future;
        expect((await pending).dispatch, PrivateTextDispatch.notAdmitted);
        expect(budget.settledCount, 0);
        expect(f.otherWriterBusy(), false);
        final events = List<String>.from(f.spy.events);
        pause.release();
        await budget.settled;
        expect(f.spy.events, events);
        expect(adapter.fetches, 0);
      },
    );
  }
}
