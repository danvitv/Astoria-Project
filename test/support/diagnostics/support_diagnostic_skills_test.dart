import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/diagnostics/support_diagnostic_skills.dart';

void main() {
  for (final (question, name) in [
    ('Диагностика подключения: ошибка HTTP 401', 'connection_diagnostics'),
    ('Почему ошибка генерации и обрыв стрима?', 'generation_diagnostics'),
    ('Check Studio tracker failure', 'studio_diagnostics'),
    ('Проверь обычный пресет', 'preset_validation'),
    ('Проверь целостность памяти и канона', 'data_integrity_and_fix'),
  ]) {
    test('current user question selects $name', () {
      expect(
        SupportDiagnosticSkills.select(question).map((s) => s.name),
        contains(name),
      );
    });
  }
  test(
    'neutral/setup/oversized questions do not activate diagnostic advice',
    () {
      for (final question in [
        'Привет',
        'Настрой Memory Books',
        'Смени тему',
        'x' * 65537,
      ]) {
        expect(SupportDiagnosticSkills.select(question), isEmpty);
      }
    },
  );
  test('selection is bounded, immutable and does not retain user content', () {
    const private = 'USER_PRIVATE_CANARY';
    final skills = SupportDiagnosticSkills.select(
      'Проверь API generation Studio preset memory $private',
    );
    expect(skills, hasLength(2));
    expect(() => skills.clear(), throwsUnsupportedError);
    final instruction = SupportDiagnosticSkills.instruction(skills, [
      'astoria_connection_read',
      'imaginary_shell',
    ]);
    expect(instruction, contains('astoria_connection_read'));
    expect(instruction, isNot(contains('imaginary_shell')));
    expect(instruction, isNot(contains(private)));
    expect(instruction, contains('never additional authority'));
    expect(instruction, contains('insufficient_data'));
  });
  test('text-only workflow cannot advertise disconnected capabilities', () {
    final instruction = SupportDiagnosticSkills.instruction(
      SupportDiagnosticSkills.builtIn,
      const [],
    );
    expect(instruction, isNot(contains('astoria_sources_list')));
    expect(instruction, isNot(contains('astoria_connection_read')));
    expect(instruction, contains('No automatic repairs or report export'));
  });
}
