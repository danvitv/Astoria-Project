import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart'
    show PrivateTextFailure;
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import 'private_text_response_cancel_fixture.dart';

void _expectFailure(
  PrivateTextResponseCancelFixture f,
  PrivateTextOutcome result,
) {
  expect(result.dispatch, PrivateTextDispatch.admittedFailed);
  expect(result.reason, PrivateTextReason.admittedFailed);
  expect(result.status, PrivateTextStatus.error);
  expect(result.text, isEmpty);
  expect(result.httpStatus, isNull);
  expect(result.toString(), isNot(contains('RAW_PROVIDER_CANARY')));
  expect(f.factoryCalls, 1);
  expect(f.http.fetches, 1);
  expect(f.http.actual.closed, true);
  expect(f.token.isCancelled, true);
  expect(f.http.rawError.formats, 0);
}

void main() {
  test(
    'successful return with pending headers: Stop, then late raw rejection',
    () async {
      final f = PrivateTextResponseCancelFixture();
      addTearDown(f.close);
      final pending = f.run();
      await f.http.prepared.future;
      await f.afterSuccessfulReturn();
      expect(f.granted, true);
      expect(f.admissionThrew, false);
      expect(f.http.headers.isCompleted, false);
      expect(f.http.fetches, 1);
      expect(f.http.actual.responseListens, 0);
      expect(f.capsule!.isCurrent, false);
      expect(() => f.capsule!.dispatch(), throwsA(isA<PrivateTextFailure>()));
      f.token.cancel();
      final result = await pending;
      expect(result.status, PrivateTextStatus.stopped);
      expect(result.reason, PrivateTextReason.cancelled);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.text, isEmpty);
      await f.http.actual.cancelObserved.future;
      await f.http.actual.forceClosed.future;
      expect(f.http.actual.options!.cancelToken, same(f.token));
      // The unchanged carrier handler must consume this rejection after Stop.
      // flutter_test also fails this schedule on any unhandled asynchronous error.
      f.http.reject();
      await drainMicrotasks();
      expect(f.http.rawError.formats, 0);
      expect(result.toString(), isNot(contains('RAW_PROVIDER_CANARY')));
      expect(() => f.capsule!.dispatch(), throwsA(isA<PrivateTextFailure>()));
      expect(f.factoryCalls, 1);
      expect(f.http.fetches, 1);
      expect(f.http.actual.responseListens, 0);
    },
  );

  for (final synchronous in [false, true]) {
    test(
      'actual fetch failure with successful return: sync=$synchronous',
      () async {
        final f = PrivateTextResponseCancelFixture(syncThrow: synchronous);
        addTearDown(f.close);
        final pending = f.run();
        await f.http.prepared.future;
        await f.afterSuccessfulReturn();
        expect(f.granted, true);
        expect(f.admissionThrew, false);
        if (!synchronous) f.http.reject();
        _expectFailure(f, await pending);
        await f.http.actual.cancelObserved.future;
        expect(f.http.actual.responseListens, 0);
      },
    );
  }

  for (final throws in [false, true]) {
    test(
      'post-dispatch callback failure survives cleanup cancel: throw=$throws',
      () async {
        final fault = PrivateTextResponseCancelRawError();
        final f = PrivateTextResponseCancelFixture(
          admission: (capsule) async {
            capsule.dispatch();
            if (throws) throw fault;
            return false;
          },
        );
        addTearDown(f.close);
        final pending = f.run();
        await f.http.prepared.future;
        _expectFailure(f, await pending);
        expect(f.admissionThrew, throws);
        expect(f.granted, throws ? isNull : false);
        expect(fault.formats, 0);
        // Callback result alone does NOT prove physical release failed/succeeded.
        expect(f.http.headers.isCompleted, false);
        f.http.complete();
        await drainMicrotasks();
        expect(f.http.actual.responseListens, 0);
      },
    );
  }

  test(
    'started but unresolved admission: Stop remains conservative error',
    () async {
      final release = Completer<bool>();
      final f = PrivateTextResponseCancelFixture(
        admission: (capsule) {
          capsule.dispatch();
          return release.future;
        },
      );
      addTearDown(f.close);
      final pending = f.run();
      await f.http.prepared.future;
      expect(f.admissionReturned.isCompleted, false);
      expect(f.http.fetches, 1);
      f.token.cancel();
      _expectFailure(f, await pending);
      expect(f.admissionReturned.isCompleted, false);
      expect(f.capsule!.isCurrent, false);
      expect(() => f.capsule!.dispatch(), throwsA(isA<PrivateTextFailure>()));
      release.complete(true);
      f.http.complete();
      await drainMicrotasks();
      expect(
        f.granted,
        true,
      ); // Late true cannot repair the earlier uncertainty.
      expect(f.http.fetches, 1);
      expect(f.http.actual.responseListens, 0);
    },
  );

  test(
    'Stop before dispatch: zero fetch and no late capsule revival',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final f = PrivateTextResponseCancelFixture(
        admission: (capsule) async {
          entered.complete();
          await resume.future;
          capsule.dispatch();
          return true;
        },
      );
      addTearDown(f.close);
      final pending = f.run();
      await entered.future;
      f.token.cancel();
      final result = await pending;
      expect(result.status, PrivateTextStatus.stopped);
      expect(result.reason, PrivateTextReason.cancelled);
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(result.text, isEmpty);
      expect(f.http.fetches, 0);
      resume.complete();
      await drainMicrotasks();
      expect(f.admissionThrew, true);
      expect(f.capsule!.isCurrent, false);
      expect(() => f.capsule!.dispatch(), throwsA(isA<PrivateTextFailure>()));
      expect(f.http.fetches, 0);
      expect(f.http.actual.options, isNull);
    },
  );

  test(
    'successful return and response retain the noncancel happy path',
    () async {
      final f = PrivateTextResponseCancelFixture();
      addTearDown(f.close);
      final pending = f.run();
      await f.http.prepared.future;
      await f.afterSuccessfulReturn();
      expect(f.granted, true);
      f.http.complete();
      final result = await pending;
      expect(result.status, PrivateTextStatus.complete);
      expect(result.reason, PrivateTextReason.none);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.text, 'Safe reply');
      expect(result.httpStatus, isNull);
      expect(f.token.isCancelled, false);
      expect(f.factoryCalls, 1);
      expect(f.http.fetches, 1);
      expect(f.http.actual.responseListens, 1);
      expect(f.http.actual.upload, isNot(contains('fixture-credential')));
      expect(() => f.capsule!.dispatch(), throwsA(isA<PrivateTextFailure>()));
      expect(f.http.fetches, 1);
    },
  );

  for (final cancelFirst in [false, true]) {
    test(
      'same-turn carrier failure and cancel preserve error: cancelFirst=$cancelFirst',
      () async {
        final f = PrivateTextResponseCancelFixture();
        addTearDown(f.close);
        final pending = f.startDirect();
        final observed = expectLater(
          pending,
          throwsA(
            isA<PrivateTextFailure>().having(
              (failure) => failure.reason,
              'fixed reason',
              PrivateTextReason.admittedFailed,
            ),
          ),
        );
        await f.http.prepared.future;
        await f.afterSuccessfulReturn();
        expect(f.granted, true);
        expect(f.http.headers.isCompleted, false);
        if (cancelFirst) {
          f.token.cancel();
          f.http.reject();
        } else {
          f.http.reject();
          f.token.cancel();
        }
        await observed;
        expect(f.direct!.admittedFailed, true);
        expect(f.direct!.reason, PrivateTextReason.admittedFailed);
        expect(f.direct!.dispatchCount, 1);
        expect(f.token.isCancelled, true);
        expect(f.http.actual.closed, true);
        expect(f.http.actual.responseListens, 0);
        expect(f.http.rawError.formats, 0);
        expect(f.factoryCalls, 1);
        expect(f.http.fetches, 1);
      },
    );
  }
}
