import 'package:flutter_test/flutter_test.dart';

import 'support_theme_provider_fixture.dart' show checkThemeProviderSql;

Never _block(String boundary) => throw StateError(boundary);

void main() {
  // No ThemeProviderFixture, ProviderContainer, binding, or database is created.
  for (final statement in [
    'SELECT 1',
    'SELECT name FROM sqlite_master WHERE type = ?',
    'SELECT name FROM sqlite_schema',
    'SELECT * FROM support_messages WHERE session_id = ?',
    'SELECT * FROM support_context_blocks WHERE session_id = ?',
    'SELECT * FROM support_reports ORDER BY created_at',
    'SELECT * FROM support_sessions JOIN support_messages ON support_sessions.id = support_messages.session_id',
    'INSERT INTO "support_sessions" (id, title_ciphertext) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET id = ?, title_ciphertext = ?',
    ' insert into `SUPPORT_SESSIONS` (id) values (?) on conflict(id) do update set id = excluded.id; ',
    'UPDATE "support_mutation_journal" SET status = ? WHERE id = ?',
    'DELETE FROM support_sessions WHERE id = ?',
    'CREATE TABLE declared_fixture_table (id TEXT)',
    'PRAGMA user_version = 136',
  ]) {
    test('SQL guard accepts declared shape: $statement', () {
      expect(() => checkThemeProviderSql(statement, _block), returnsNormally);
    });
  }

  for (final table in ['api_configs', 'lorebooks', 'characters', 'set']) {
    for (final statement in [
      'SELECT * FROM "$table"',
      'SELECT * FROM support_sessions JOIN `$table` ON 1 = 1',
      'UPDATE "$table" SET id = ?',
      'INSERT INTO `$table` (id) VALUES (?) ON CONFLICT(id) DO UPDATE SET id = ?',
      'DELETE FROM $table WHERE id = ?',
      'INSERT INTO support_sessions (id) VALUES (?) ON CONFLICT(id) DO UPDATE SET id = (SELECT id FROM "$table")',
      'UPDATE support_sessions SET id = (SELECT id FROM $table)',
    ]) {
      test('SQL guard denies foreign target: $statement', () {
        expect(
          () => checkThemeProviderSql(statement, _block),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'boundary',
              'API/body/world SQL',
            ),
          ),
        );
      });
    }
  }

  for (final statement in [
    'ATTACH DATABASE ? AS external',
    'WITH local AS (SELECT 1) UPDATE api_configs SET id = ?',
    'SELECT load_extension(?)',
    'SELECT * FROM support_sessions; UPDATE api_configs SET id = ?',
    'SELECT * FROM support_sessions, api_configs',
    'SELECT * FROM support_sessions , api_configs',
    'SELECT * FROM support_sessions AS s, api_configs',
    'SELECT * FROM support_sessions.api_configs',
    'SELECT * FROM "support_sessions".api_configs',
    'SELECT * FROM support_sessions . api_configs',
    'UPDATE support_sessions . api_configs SET id = ?',
    'INSERT INTO support_sessions . api_configs (id) VALUES (?)',
    'DELETE FROM support_sessions . api_configs WHERE id = ?',
    'SELECT * FROM [api_configs]',
    "SELECT * FROM 'api_configs'",
    'SELECT * FROM (SELECT * FROM api_configs)',
    'SELECT * FROM support_sessions(?)',
    'SELECT * FROM support_sessions_hidden',
    'SELECT * FROM support_sessions2',
    'UPDATE OR IGNORE api_configs SET id = ?',
    'UPDATE/* hidden target */api_configs SET id = ?',
    'SELECT * FROM support_sessions -- hidden second statement',
    'DO UPDATE SET id = ?',
  ]) {
    test('SQL guard fails closed on unsupported shape: $statement', () {
      expect(() => checkThemeProviderSql(statement, _block), throwsStateError);
    });
  }
}
