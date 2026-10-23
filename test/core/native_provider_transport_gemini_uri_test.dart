import 'package:flutter_test/flutter_test.dart';

import 'native_provider_transport_fixture.dart';

void main() {
  for (final savedStream in [true, false]) {
    for (final stream in [true, false]) {
      test(
        'Gemini saved stream=$savedStream dispatch stream=$stream reaches final factory with exact keyless URI',
        () async {
          final h = NativeTransportHarness(
            'gemini',
            row: nativeTransportRow('gemini', stream: savedStream),
          );
          await h.store();
          var factories = 0;
          h.onFactory = () => factories++;
          if (!stream) {
            h.response = nativeTransportJson('gemini');
            h.contentType = 'application/json';
          }
          await h.run(input: h.request(stream: stream));

          // No held gate: failure during URI construction must fail promptly,
          // rather than waiting for a factory checkpoint that cannot be reached.
          expect(factories, 1);
          expect(h.errors, isEmpty);
          expect(h.legacy.requests, isEmpty);
          expect(h.wires, hasLength(1));
          final wire = h.wires.single;
          final route = Uri.parse(
            nativeTransportRow('gemini', stream: stream).endpoint,
          );
          expect(wire.uri, stream ? route.replace(query: 'alt=sse') : route);
          expect(
            wire.uri.queryParametersAll,
            stream
                ? {
                    'alt': ['sse'],
                  }
                : isEmpty,
          );
          expect(wire.uri.toString(), isNot(contains(nativeCanary)));
          expect(wire.headers['x-goog-api-key'], nativeCanary);
          expect(h.completions, hasLength(1));
          expect(h.completions.single.$1, 'Visible text ');
          expect(h.completions.single.$2, 'Reasoning text ');
          expect(h.adapters.single.closed, isTrue);
        },
      );
    }
  }
}
