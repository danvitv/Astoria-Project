import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';

import '../llm/transport/_private_text_fixture.dart' show privateRequest;
import 'helpers/reserved_text_admission_fixture.dart';

Future<PrivateTextOutcome> _run(
  ReservedTextAdmissionFixture f,
  ReservedFixtureAdapter adapter,
  PrivateTextAdmission admit, {
  CancelToken? token,
  bool Function()? current,
  HttpClientAdapter Function()? factory,
  Timer Function(Duration, void Function()) scheduleDeadline = Timer.new,
}) =>
    PrivateTextTransport(
      adapterFactory: factory ?? () => adapter,
      currentRedactor: () => f.redactor,
      authorize: (_) =>
          throw StateError('Strong path must NEVER call weak authorize'),
      admit: admit,
      scheduleDeadline: scheduleDeadline,
    ).generate(
      protocol: LlmProtocol.openai,
      request: privateRequest(),
      approvedRecipient: Uri.parse(privateRequest().endpoint),
      cancelToken: token ?? CancelToken(),
      isCurrent: current ?? () => true,
    );

PrivateTextAdmission _admit(
  ReservedTextAdmissionFixture f,
  List<SupportTextContextSnapshot> snapshots, {
  SupportTextAdmissionCheck? policy,
  void Function()? released,
  SupportTextContextRepo? repo,
}) => (capsule) async {
  final granted = await (repo ?? f.repo).admitDispatch(
    snapshots: snapshots,
    isCurrent: () => capsule.isCurrent,
    checkReadOnly: policy ?? f.readOnlyPolicy,
    dispatch: capsule.dispatch,
  );
  released?.call();
  return granted;
};

void main() {
  for (final populated in [false, true]) {
    test(
      'fixed first DELETE, exact counters/all bytes/trigger, actual B BUSY: $populated',
      () async {
        final f = await ReservedTextAdmissionFixture.create(
          populated: populated,
        );
        addTearDown(f.close);
        // Record loaded binary identity ONLY from this owned synthetic database.
        expect(f.sqliteVersion, isNotEmpty);
        expect(f.sqliteSourceId, isNotEmpty);
        // Synthetic binary provenance required for parent native evidence.
        // ignore: avoid_print
        print('Synthetic SQLite ${f.sqliteVersion}; ${f.sqliteSourceId}');
        final snapshots = populated
            ? [await f.preview()]
            : <SupportTextContextSnapshot>[];
        final before = await f.stamp();
        final bytes = await f.tableBytes();
        final reserved = Completer<void>();
        final continuePolicy = Completer<void>();
        final released = Completer<void>();
        f.spy.afterReserve = () async {
          reserved.complete();
          await continuePolicy.future;
        };
        final adapter = ReservedFixtureAdapter(
          onFetch: () {
            expect(
              f.otherWriterBusy(),
              true,
            ); // SYNCHRONOUS actual fetch boundary.
          },
        );
        f.spy.events.clear();
        final pending = _run(
          f,
          adapter,
          _admit(f, snapshots, released: released.complete),
        );
        await reserved.future;
        expect(f.spy.events, ['timeout', 'reserve']); // NO prior main SELECT.
        expect(f.otherWriterBusy(), true);
        continuePolicy.complete();
        await released.future;
        expect(adapter.fetches, 1);
        expect(adapter.response.isCompleted, false);
        expect(await f.stamp(), before); // No subtraction/rebase/allowance.
        expect(await f.tableBytes(), bytes);
        final changes = await f.db
            .customSelect('SELECT changes() AS c')
            .getSingle();
        expect(changes.read<int>('c'), 0);
        expect(f.otherWriterBusy(), false);
        // Both independent B writer and ordinary A write finish while HTTP paused.
        f.otherWrite();
        await f.ownWrite();
        expect(adapter.response.isCompleted, false);
        adapter.complete();
        final result = await pending;
        expect(result.status, PrivateTextStatus.complete);
        expect(result.dispatch, PrivateTextDispatch.admitted);
      },
    );
  }

  for (final mutation in [
    'body',
    'unrelated',
    'edit-restore',
    'delete-recreate',
  ]) {
    test(
      'B committed BEFORE reservation permanently invalidates preview: $mutation',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final preview = await f.preview();
        final before = await f.stamp();
        switch (mutation) {
          case 'body':
            f.other.execute(
              'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
              [f.changedEnvelope, 'history'],
            );
          case 'unrelated':
            f.otherWrite();
          case 'edit-restore':
            f.other.execute(
              'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
              [f.changedEnvelope, 'history'],
            );
            f.other.execute(
              'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
              [f.originalEnvelope, 'history'],
            );
          case 'delete-recreate':
            f.other.execute('DELETE FROM support_messages WHERE id = ?', [
              'history',
            ]);
            f.other.execute(
              'INSERT INTO support_messages (id, session_id, role, body_ciphertext, created_at) VALUES (?, ?, ?, ?, ?)',
              ['history', 'session', 'user', f.originalEnvelope, 2],
            );
        }
        expect((await f.stamp()).$2, isNot(before.$2));
        final adapter = ReservedFixtureAdapter();
        final result = await _run(f, adapter, _admit(f, [preview]));
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
        expect(adapter.fetches, 0);
        expect(await f.repo.revalidate(preview), false);
        expect(f.otherWriterBusy(), false);
      },
    );
  }

  test(
    'support and roleplay owning nested H reads share the main reservation',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      await f.seedRoleplay();
      final support = await f.preview();
      final roleplay = await f.repo.loadRoleplay(
        sessionId: 'synthetic-game',
        messageIds: ['game-history'],
      );
      final before = await f.stamp();
      final released = Completer<void>();
      final adapter = ReservedFixtureAdapter(
        onFetch: () => expect(f.otherWriterBusy(), true),
      );
      final pending = _run(
        f,
        adapter,
        _admit(f, [support, roleplay], released: released.complete),
      );
      await released.future;
      expect(adapter.fetches, 1);
      expect(await f.stamp(), before);
      expect(f.otherWriterBusy(), false);
      adapter.complete();
      expect((await pending).status, PrivateTextStatus.complete);
    },
  );

  test(
    'bare DEFERRED final reader permits B commit and retains stale WAL view',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final read = Completer<void>();
      final committed = Completer<void>();
      final control = f.db.transaction(() async {
        final old = await f.db
            .customSelect(
              'SELECT body_ciphertext AS b FROM support_messages WHERE id = ?',
              variables: [Variable.withString('history')],
            )
            .getSingle();
        read.complete();
        await committed.future;
        final stale = await f.db
            .customSelect(
              'SELECT body_ciphertext AS b FROM support_messages WHERE id = ?',
              variables: [Variable.withString('history')],
            )
            .getSingle();
        expect(stale.read<String>('b'), old.read<String>('b'));
        expect(stale.read<String>('b'), f.originalEnvelope);
      });
      await read.future;
      expect(f.otherWriterBusy(), false);
      f.other.execute(
        'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
        [f.changedEnvelope, 'history'],
      );
      committed.complete();
      await control;
      final durable = await f.db
          .customSelect(
            'SELECT body_ciphertext AS b FROM support_messages WHERE id = ?',
            variables: [Variable.withString('history')],
          )
          .getSingle();
      expect(durable.read<String>('b'), f.changedEnvelope);
    },
  );

  test(
    'held bounded policy and actual nested H reader retain B writer exclusion',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      final policyEntered = Completer<void>();
      final policyContinue = Completer<void>();
      final decryptEntered = Completer<void>();
      final decryptContinue = Completer<void>();
      final released = Completer<void>();
      var paused = false;
      f.primitive.beforeDecrypt = (_) async {
        if (!paused) {
          paused = true;
          decryptEntered.complete();
          await decryptContinue.future;
        }
      };
      final adapter = ReservedFixtureAdapter(
        onFetch: () => expect(f.otherWriterBusy(), true),
      );
      final pending = _run(
        f,
        adapter,
        _admit(
          f,
          [preview],
          policy: (check) async {
            policyEntered.complete();
            await policyContinue.future;
            check();
            return f.readOnlyPolicy(check);
          },
          released: released.complete,
        ),
      );
      await policyEntered.future;
      expect(f.otherWriterBusy(), true);
      policyContinue.complete();
      await decryptEntered.future;
      expect(f.otherWriterBusy(), true);
      decryptContinue.complete();
      await released.future;
      expect(f.otherWriterBusy(), false);
      expect(adapter.fetches, 1);
      adapter.complete();
      expect((await pending).status, PrivateTextStatus.complete);
    },
  );

  test(
    'existing B writer makes acquisition fail-fast with zero actual fetches',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      f.other.execute('BEGIN IMMEDIATE');
      try {
        final adapter = ReservedFixtureAdapter();
        f.spy.events.clear();
        final result = await _run(f, adapter, _admit(f, [preview]));
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
        expect(adapter.fetches, 0);
        expect(f.spy.events, ['timeout', 'reserve']); // No policy/source read.
        await f.db.customSelect('SELECT 1').getSingle(); // A's queue released.
      } finally {
        f.other.execute('ROLLBACK');
      }
      await f.ownWrite();
    },
  );

  for (final deadline in [false, true]) {
    test(
      'queued Stop/deadline revokes native wait; late entry has zero reads/DELETE/fetch: $deadline',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final preview = await f.preview();
        final predecessorEntered = Completer<void>();
        final predecessorRelease = Completer<void>();
        final queued = Completer<void>();
        final cleanup = Completer<void>();
        final predecessor = f.db.transaction(() async {
          await f.db.customSelect('SELECT 1').getSingle();
          predecessorEntered.complete();
          await predecessorRelease.future;
        });
        await predecessorEntered.future;
        final token = CancelToken();
        final clock = _ManualDeadline();
        final adapter = ReservedFixtureAdapter();
        f.spy.events.clear();
        final pending = _run(
          f,
          adapter,
          (capsule) async {
            queued.complete();
            try {
              return await _admit(f, [preview])(capsule);
            } finally {
              cleanup.complete();
            }
          },
          token: token,
          scheduleDeadline: clock.schedule,
        );
        await queued.future;
        if (deadline) {
          clock.expire();
        } else {
          token.cancel();
        }
        final result = await pending;
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
        expect(
          result.reason,
          deadline ? PrivateTextReason.deadline : PrivateTextReason.cancelled,
        );
        expect(
          cleanup.isCompleted,
          false,
        ); // NOT claiming physical queue removal.
        expect(f.spy.events, isEmpty);
        expect(adapter.fetches, 0);
        predecessorRelease.complete();
        await predecessor;
        await cleanup.future;
        expect(f.spy.events, isEmpty);
        expect(adapter.fetches, 0);
        f.otherWrite();
        await f.ownWrite();
      },
    );
  }

  for (final pause in ['policy', 'decrypt']) {
    test(
      'Stop in bounded held $pause revokes immediately and late continuation does no further SQL',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final preview = await f.preview();
        final entered = Completer<void>();
        final resume = Completer<void>();
        final cleanup = Completer<void>();
        if (pause == 'decrypt') {
          f.primitive.beforeDecrypt = (_) async {
            entered.complete();
            await resume.future;
          };
        }
        final token = CancelToken();
        final adapter = ReservedFixtureAdapter();
        final pending = _run(f, adapter, (capsule) async {
          try {
            return await _admit(
              f,
              [preview],
              policy: pause == 'policy'
                  ? (check) async {
                      entered.complete();
                      await resume.future;
                      check();
                      return f.readOnlyPolicy(check);
                    }
                  : null,
            )(capsule);
          } finally {
            cleanup.complete();
          }
        }, token: token);
        await entered.future;
        expect(f.otherWriterBusy(), true);
        token.cancel();
        expect((await pending).dispatch, PrivateTextDispatch.notAdmitted);
        expect(cleanup.isCompleted, false);
        final events = List<String>.of(f.spy.events);
        resume.complete();
        await cleanup.future;
        expect(f.spy.events, events);
        expect(adapter.fetches, 0);
        expect(f.otherWriterBusy(), false);
        f.otherWrite();
        await f.ownWrite();
      },
    );
  }

  test(
    'prepared factory mutation happens BEFORE final H reads and is refused',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      final adapter = ReservedFixtureAdapter();
      final result = await _run(
        f,
        adapter,
        _admit(f, [preview]),
        factory: () {
          f.otherWrite();
          return adapter;
        },
      );
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(adapter.fetches, 0);
      expect(await f.repo.revalidate(preview), false);
    },
  );

  for (final mutation in ['counted', 'rollback', 'status', 'provenance']) {
    test(
      'own $mutation write invalidates exact preview without rebase',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final preview = await f.preview();
        final before = await f.stamp();
        switch (mutation) {
          case 'counted':
            await f.ownWrite();
          case 'rollback':
            try {
              await f.db.transaction(() async {
                await f.ownWrite();
                throw const UnprintableAdmissionError();
              });
            } catch (_) {
              /* Intentionally completed counted DML before rollback. */
            }
          case 'status':
            await f.db.customStatement(
              'UPDATE support_messages SET status = ? WHERE id = ?',
              ['pending', 'history'],
            );
          case 'provenance':
            await f.db.customStatement(
              'INSERT INTO support_context_blocks (id, session_id, start_message_id, end_message_id, summary_ciphertext, created_at) VALUES (?, ?, ?, ?, ?, ?)',
              [
                'support.reply_provenance:history',
                'session',
                'history',
                'history',
                '',
                2,
              ],
            );
        }
        expect((await f.stamp()).$1, greaterThan(before.$1));
        final adapter = ReservedFixtureAdapter();
        expect(
          (await _run(f, adapter, _admit(f, [preview]))).dispatch,
          PrivateTextDispatch.notAdmitted,
        );
        expect(adapter.fetches, 0);
        expect(await f.repo.revalidate(preview), false);
      },
    );
  }

  test(
    'counted mutation inside claimed read-only callback cannot dispatch',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      final adapter = ReservedFixtureAdapter();
      final result = await _run(
        f,
        adapter,
        _admit(
          f,
          [preview],
          policy: (check) async {
            await f
                .ownWrite(); // Deliberate contract violation, counter catches it.
            check();
            return true;
          },
        ),
      );
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(adapter.fetches, 0);
    },
  );

  for (final kind in [
    'unknown',
    'foreign-repo',
    'revoked',
    'reconnect',
    'nonzero-timeout',
    'forged',
  ]) {
    test(
      'unknown/unsupported lifetime/backend/source fails closed: $kind',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final originalRepo = f.repo;
        SupportTextContextSnapshot preview = await f.preview();
        SupportTextContextRepo owner = f.repo;
        switch (kind) {
          case 'unknown':
            owner = f.newRepo(contract: null);
          case 'foreign-repo':
            owner = f.newRepo();
          case 'revoked':
            owner.revokeAdmissionOwner();
          case 'reconnect':
            await f.reconnect();
            owner = f.repo;
          case 'nonzero-timeout':
            await f.db.customStatement('PRAGMA busy_timeout = 1000');
          case 'forged':
            preview = _ForgedSnapshot(preview);
        }
        final adapter = ReservedFixtureAdapter();
        f.spy.events.clear();
        final result = await _run(
          f,
          adapter,
          _admit(f, [preview], repo: owner),
        );
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
        expect(adapter.fetches, 0);
        expect(f.spy.events, kind == 'nonzero-timeout' ? ['timeout'] : isEmpty);
        if (kind == 'revoked') {
          expect(await owner.revalidate(preview), false);
        }
        if (kind == 'reconnect') {
          // Revoked old owner cannot dispatch on newly opened numerical counters.
          expect(
            await originalRepo.admitDispatch(
              snapshots: [],
              isCurrent: () => true,
              checkReadOnly: (_) async => true,
              dispatch: () => fail('revoked dispatch'),
            ),
            false,
          );
        }
      },
    );
  }

  for (final failure in ['sync-throw', 'fast-reject', 'release-fault']) {
    test(
      'truthful ADMITTED-FAILED, fixed-safe errors, exactly one fetch/no retry: $failure',
      () async {
        final f = await ReservedTextAdmissionFixture.create();
        addTearDown(f.close);
        final preview = await f.preview();
        final releaseToken = CancelToken();
        var releaseFaultArmed = false;
        var releaseFaultInjected = false;
        var releaseCallbacks = 0;
        bool? writerBusyAtFetch;
        bool? writerBusyAfterRelease;
        final adapter = ReservedFixtureAdapter(
          syncThrow: failure == 'sync-throw',
          fastReject: failure == 'fast-reject',
          onFetch: () {
            if (failure == 'release-fault') {
              writerBusyAtFetch = f.otherWriterBusy();
              releaseFaultArmed = true;
            }
          },
        );
        if (failure == 'release-fault') adapter.complete();
        final result = await _run(
          f,
          adapter,
          _admit(
            f,
            [preview],
            released: failure == 'release-fault'
                ? () {
                    // Native post-release callback failure, NOT a physical
                    // COMMIT failure. _admit already awaited actual H release.
                    // Record facts here; assert outside the handled callback.
                    releaseCallbacks++;
                    writerBusyAfterRelease = f.otherWriterBusy();
                    if (releaseFaultArmed) {
                      releaseFaultArmed = false;
                      releaseFaultInjected = true;
                      throw const UnprintableAdmissionError();
                    }
                  }
                : null,
          ),
          token: failure == 'release-fault' ? releaseToken : null,
        );
        expect(result.dispatch, PrivateTextDispatch.admittedFailed);
        expect(result.reason, PrivateTextReason.admittedFailed);
        expect(result.status, PrivateTextStatus.error);
        expect(result.text, isEmpty);
        expect(adapter.fetches, 1);
        expect(adapter.closed, true);
        if (failure == 'release-fault') {
          expect(writerBusyAtFetch, true);
          expect(writerBusyAfterRelease, false);
          expect(releaseCallbacks, 1);
          expect(releaseFaultArmed, false);
          expect(releaseFaultInjected, true);
          expect(releaseToken.isCancelled, true);
          expect(await f.repo.revalidate(preview), true);
        }
        expect(f.otherWriterBusy(), false);
        await f.ownWrite();
      },
    );
  }

  test(
    'double and escaped late capsule cannot dispatch an additional request',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      late PrivateTextDispatchCapsule escaped;
      final adapter = ReservedFixtureAdapter();
      final result = await _run(f, adapter, (capsule) async {
        escaped = capsule;
        return f.repo.admitDispatch(
          snapshots: [preview],
          isCurrent: () => capsule.isCurrent,
          checkReadOnly: f.readOnlyPolicy,
          dispatch: () {
            capsule.dispatch();
            capsule
                .dispatch(); // Deliberate trusted-callback misuse after first.
          },
        );
      });
      expect(result.dispatch, PrivateTextDispatch.admittedFailed);
      expect(adapter.fetches, 1);
      expect(escaped.isCurrent, false);
      expect(escaped.toString(), 'PrivateTextDispatchCapsule');
      expect(() => escaped.dispatch(), throwsA(isA<Exception>()));
      expect(adapter.fetches, 1);
    },
  );

  test(
    'denied escaped capsule cannot be dispatched after callback completion',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      late PrivateTextDispatchCapsule escaped;
      final adapter = ReservedFixtureAdapter();
      final result = await _run(f, adapter, (capsule) async {
        escaped = capsule;
        return false;
      });
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(() => escaped.dispatch(), throwsA(isA<Exception>()));
      expect(adapter.fetches, 0);
    },
  );

  test(
    '408 retry creates new capsule and repeats H admission for each attempt',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      final first = ReservedFixtureAdapter()..complete(status: 408);
      final second = ReservedFixtureAdapter()..complete();
      final attempts = <int>[];
      final capsules = <PrivateTextDispatchCapsule>[];
      var factoryCalls = 0;
      final result = await _run(f, first, (capsule) async {
        attempts.add(capsule.handoff.attempt);
        capsules.add(capsule);
        return _admit(f, [preview])(capsule);
      }, factory: () => factoryCalls++ == 0 ? first : second);
      expect(result.status, PrivateTextStatus.complete);
      expect(attempts, [1, 2]);
      expect(identical(capsules[0], capsules[1]), false);
      expect(first.fetches, 1);
      expect(second.fetches, 1);
      expect(capsules.every((c) => !c.isCurrent), true);
    },
  );

  test(
    '408 source mutation before second admission refuses retry dispatch',
    () async {
      final f = await ReservedTextAdmissionFixture.create();
      addTearDown(f.close);
      final preview = await f.preview();
      final first = ReservedFixtureAdapter()..complete(status: 408);
      final second = ReservedFixtureAdapter();
      final attempts = <int>[];
      var created = 0;
      final result = await _run(
        f,
        first,
        (capsule) async {
          attempts.add(capsule.handoff.attempt);
          return _admit(f, [preview])(capsule);
        },
        factory: () {
          if (created++ == 0) return first;
          f.otherWrite();
          return second;
        },
      );
      expect(attempts, [1, 2]);
      expect(first.fetches, 1);
      expect(second.fetches, 0);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.status, PrivateTextStatus.error);
      expect(result.reason, PrivateTextReason.denied);
      expect(await f.repo.revalidate(preview), false);
    },
  );
}

final class _ManualDeadline implements Timer {
  void Function()? _expire;
  bool _active = true;
  Timer schedule(Duration _, void Function() expire) {
    _expire = expire;
    return this;
  }

  void expire() {
    if (_active) {
      _active = false;
      _expire!();
    }
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

final class _ForgedSnapshot implements SupportTextContextSnapshot {
  _ForgedSnapshot(this.delegate);
  final SupportTextContextSnapshot delegate;
  @override
  SupportTextContextSource get source => delegate.source;
  @override
  String get sessionId => delegate.sessionId;
  @override
  List<String> get messageIds => delegate.messageIds;
  @override
  List<SupportTextContextMessage> get messages => delegate.messages;
  @override
  List<SupportTextContextProvenance> get provenance => delegate.provenance;
  @override
  bool get isWholeSession => delegate.isWholeSession;
  @override
  SupportSessionHistoryBoundary? get currentInput => delegate.currentInput;
}
