import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/chub_session.dart';

void main() {
  group('captureChubSessionProbe ownership', () {
    for (final retired in [
      'manual round-trip',
      'controller',
      'notifier build',
      'native auth',
      'lifetime',
    ]) {
      test('a late probe cannot admit auth after $retired changes', () async {
        final response = Completer<Object?>();
        var manualEpoch = 0, build = 0, auth = 0;
        var mounted = true;
        Object controller = Object();
        final originalController = controller;
        final probe = captureChubSessionProbe(
          evaluate: () => response.future,
          isCurrent: () =>
              mounted &&
              manualEpoch == 0 &&
              build == 0 &&
              auth == 0 &&
              identical(controller, originalController),
        );
        switch (retired) {
          case 'manual round-trip':
            manualEpoch +=
                2; // Manual then back is still a different mode epoch.
            break;
          case 'controller':
            controller = Object();
            break;
          case 'notifier build':
            build++;
            break;
          case 'native auth':
            auth++;
            break;
          case 'lifetime':
            mounted = false;
            break;
        }
        response.complete({'token': 'SYNTHETIC_OLD_PROBE', 'user': 'OLD_NAME'});
        expect(await probe, isNull);
      });
    }

    test(
      'current probe can admit its session; retired probe never evaluates',
      () async {
        var evaluations = 0;
        Future<Object?> evaluate() async {
          evaluations++;
          return {'token': 'SYNTHETIC_CURRENT_PROBE'};
        }

        expect(
          await captureChubSessionProbe(
            evaluate: evaluate,
            isCurrent: () => false,
          ),
          isNull,
        );
        expect(evaluations, 0);
        final result = await captureChubSessionProbe(
          evaluate: evaluate,
          isCurrent: () => true,
        );
        expect(result?.token, 'SYNTHETIC_CURRENT_PROBE');
        expect(evaluations, 1);
      },
    );
  });

  group('parseChubSessionProbe', () {
    test('reads a decoded map', () {
      final session = parseChubSessionProbe({'token': 't', 'user': 'neo'});
      expect(session?.token, 't');
      expect(session?.userName, 'neo');
    });

    test('reads the JSON string the probe returns', () {
      final session = parseChubSessionProbe(
        jsonEncode({'token': 't', 'user': 'neo'}),
      );
      expect(session?.token, 't');
      expect(session?.userName, 'neo');
    });

    test('unwraps Android double-quoting', () {
      final session = parseChubSessionProbe(
        jsonEncode(jsonEncode({'token': 't', 'user': null})),
      );
      expect(session?.token, 't');
      expect(session?.userName, isNull);
    });

    test('a missing or blank token is not a session', () {
      expect(parseChubSessionProbe(null), isNull);
      expect(parseChubSessionProbe(''), isNull);
      expect(parseChubSessionProbe('null'), isNull);
      expect(parseChubSessionProbe({'token': ''}), isNull);
      expect(parseChubSessionProbe({'user': 'neo'}), isNull);
    });

    test('garbage is not a session', () {
      expect(parseChubSessionProbe('not json'), isNull);
      expect(parseChubSessionProbe(42), isNull);
      expect(parseChubSessionProbe(['t']), isNull);
      expect(parseChubSessionProbe({'token': 7}), isNull);
    });
  });
}
