part of 'persona_repo.dart';

enum PersonaControlText { name, displayName, prompt }

extension PersonaAppControl on PersonaRepo {
  Future<({List<String> ids, int count})> controlIds(int offset) async {
    final count = _db.personas.personaId.count();
    final total = await (_db.selectOnly(
      _db.personas,
    )..addColumns([count])).getSingle();
    final rows =
        await (_db.selectOnly(_db.personas)
              ..addColumns([_db.personas.personaId])
              ..orderBy([OrderingTerm.asc(_db.personas.personaId)])
              ..limit(32, offset: offset))
            .get();
    return (
      ids: rows.map((r) => r.read(_db.personas.personaId)!).toList(),
      count: total.read(count) ?? 0,
    );
  }

  Future<bool> controlCreate(Persona value, bool Function() current) =>
      _db.transaction(() async {
        if (!current()) return false;
        await _ensureDisplayNameColumn();
        if (!current() || await getById(value.id) != null || !current())
          return false;
        await _db.customStatement(
          '''
        INSERT INTO personas (persona_id, name, display_name, prompt, created_at)
        VALUES (?, ?, ?, ?, ?)
        ''',
          [
            value.id,
            value.name,
            value.displayName,
            value.prompt,
            value.createdAt,
          ],
        );
        return true;
      });

  Future<bool> controlText({
    required Persona expected,
    required PersonaControlText field,
    required String value,
    required bool Function() current,
  }) => _db.transaction(() async {
    if (!current()) return false;
    final latest = await getById(expected.id);
    if (!current() || latest == null || latest != expected) return false;
    // The column comes from a native enum, never SQL supplied by a caller.
    final column = switch (field) {
      PersonaControlText.name => 'name',
      PersonaControlText.displayName => 'display_name',
      PersonaControlText.prompt => 'prompt',
    };
    await _db.customStatement(
      'UPDATE personas SET $column = ? WHERE persona_id = ?',
      [value, latest.id],
    );
    return true;
  });
}
