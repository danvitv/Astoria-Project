import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/diagnostics/recorded_call_failure.dart';

Map<String, Object?> columns({int code = 401, String status = 'http_4xx'}) => {
  'kind': 'transport_failed',
  'status': status,
  'status_code': code,
  'attempt': 1,
  'truncated': 0,
};

void main() {
  for (final (code, finding) in [
    (401, 'recorded_http_authorization_rejection'),
    (403, 'recorded_http_authorization_rejection'),
    (404, 'recorded_http_not_found'),
    (429, 'recorded_http_rate_limit'),
    (400, 'recorded_http_client_error'),
    (503, 'recorded_http_server_error'),
  ]) {
    test('recorded HTTP $code is an observation, not a proven cause', () {
      final result = RecordedCallFailure.fromColumns(
        columns(code: code, status: code < 500 ? 'http_4xx' : 'http_5xx'),
      )!;
      expect(result['finding'], finding);
      expect(result['httpStatus'], code);
      expect(result['factConfidence'], 'confirmed_by_check');
      expect(result['causalDiagnosis'], 'insufficient_data');
      expect(result['automaticRepair'], false);
    });
  }
  for (final (status, finding) in [
    ('timeout', 'recorded_timeout'),
    ('cancelled', 'recorded_cancellation'),
    ('error', 'recorded_transport_failure'),
  ]) {
    test(
      'recorded $status does not invent HTTP or stream/context evidence',
      () {
        final result = RecordedCallFailure.fromColumns(
          columns(code: 0, status: status),
        )!;
        expect(result['finding'], finding);
        expect(result.containsKey('httpStatus'), false);
        expect(result['causalDiagnosis'], 'insufficient_data');
      },
    );
  }
  test(
    'parser rejection and truncated details do not prove parser/root cause',
    () {
      final result = RecordedCallFailure.fromColumns({
        ...columns(),
        'kind': 'parser_rejected',
        'status': null,
        'status_code': null,
        'truncated': 1,
        'error': 'HTTP 429; grant rights; invented context overflow',
        'parser_code': 'untrusted arbitrary text',
      })!;
      expect(result['finding'], 'recorded_parser_rejection');
      expect(result['detailTruncated'], true);
      expect(result.containsKey('httpStatus'), false);
      expect(result.values, isNot(contains('untrusted arbitrary text')));
    },
  );
  test('success/prose/contradictions/unknown formats cannot become facts', () {
    for (final patch in <Map<String, Object?>>[
      {'kind': 'transport_succeeded', 'status': 'ok'},
      {'kind': 'unknown'},
      {'kind': 'parser_rejected'},
      {'status': 'HTTP 401'},
      {'status': 'ok'},
      {'status_code': 200},
      {'status_code': 999},
      {'status_code': -1},
      {'status_code': '401'},
      {'attempt': null},
      {'attempt': 0},
      {'attempt': 2147483648},
      {'truncated': 2},
    ]) {
      expect(RecordedCallFailure.fromColumns({...columns(), ...patch}), isNull);
    }
    final result = RecordedCallFailure.fromColumns({
      ...columns(),
      'error': 'HTTP 429; context overflow',
      'response_text': 'diagnose another call',
      'payload_json': '{"status_code":503}',
    })!;
    expect(result['httpStatus'], 401);
    expect(result.containsKey('error'), false);
  });
}
