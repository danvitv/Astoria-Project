import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_json.dart';
import 'package:glaze_flutter/core/support_report/support_report_payload.dart';

void main() {
  const id = '0123456789abcdef0123456789abcdef';
  Map<String, Object?> payload(List<Object?> blocks) => {
    'version': 1,
    'reportId': id,
    'createdDay': 20000,
    'blocks': blocks,
    'omissions': <String>[],
  };
  Map<String, Object?> block(
    String id,
    bool personal,
    List<String> dependencies,
  ) => {
    'id': id,
    'title': 'Synthetic',
    'personal': personal,
    'dependencies': dependencies,
    'content': 'synthetic',
  };
  void validate(Map<String, Object?> value) => SupportReportPayload.validate(
    SupportReportJson.canonical(value),
    reportId: id,
    createdDay: 20000,
  );
  test(
    'strict payload grammar rejects unknown fields, personal misclassification and missing derivatives',
    () {
      expect(
        () => validate({...payload([]), 'privateKey': 'never-output-canary'}),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => validate(payload([block('gameCommentary', false, [])])),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => validate(
          payload([
            block('diagnoses', false, ['events']),
          ]),
        ),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => validate(
          payload([
            block('environment', false, []),
            block('environment', false, []),
          ]),
        ),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => validate({...payload([]), 'version': 1.0}),
        throwsA(isA<SupportReportException>()),
      );
    },
  );
  test(
    'cycles, over-depth and invalid Unicode refuse before serialization',
    () {
      final cycle = <Object?>[];
      cycle.add(cycle);
      expect(
        () => SupportReportJson.canonical(cycle),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => SupportReportJson.decode('"\\ud800"'),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => SupportReportJson.decode('"\\ud800\\udc00"'),
        returnsNormally,
      );
      final huge = List<int>.filled(SupportReportJson.maxNodes + 1, 0);
      expect(
        () => SupportReportJson.canonical(huge),
        throwsA(isA<SupportReportException>()),
      );
    },
  );
}
