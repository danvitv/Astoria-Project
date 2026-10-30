part of 'character_repo.dart';

enum CharacterControlText {
  name,
  displayName,
  description,
  personality,
  scenario,
  firstMes,
  mesExample,
  systemPrompt,
  postHistoryInstructions,
  creatorNotes,
  depthPrompt,
  world,
}

extension CharacterAppControl on CharacterRepo {
  /// ID-only projection: never decodes a card, avatar, title or prompt.
  Future<({List<String> ids, int count})> controlIds(int offset) async {
    final count = _db.characters.charId.count();
    final total = await (_db.selectOnly(
      _db.characters,
    )..addColumns([count])).getSingle();
    final rows =
        await (_db.selectOnly(_db.characters)
              ..addColumns([_db.characters.charId])
              ..orderBy([OrderingTerm.asc(_db.characters.charId)])
              ..limit(32, offset: offset))
            .get();
    return (
      ids: rows.map((r) => r.read(_db.characters.charId)!).toList(),
      count: total.read(count) ?? 0,
    );
  }

  Future<bool> controlCreate(Character value, bool Function() current) =>
      _db.transaction(() async {
        if (!current()) return false;
        if (await getById(value.id) != null || !current()) return false;
        await _db
            .into(_db.characters)
            .insert(
              _toCompanion(
                value.copyWith(tokenCount: estimateCharacterTokens(value)),
              ),
            );
        return true;
      });

  /// Reads the latest row inside its owner transaction; a card fork is not a
  /// standalone editor target. Only the selected column/extension and cached
  /// token count change. Session index, gallery and unrelated source stay put.
  Future<bool> controlText({
    required Character expected,
    required CharacterControlText field,
    required String value,
    required bool Function() current,
  }) => _db.transaction(() async {
    if (!current()) return false;
    final latest = await getById(expected.id);
    if (!current() ||
        latest != expected ||
        latest == null ||
        latest.variantOrder != 0) {
      return false;
    }
    final next = switch (field) {
      CharacterControlText.name => latest.copyWith(name: value),
      CharacterControlText.displayName => latest.copyWith(displayName: value),
      CharacterControlText.description => latest.copyWith(description: value),
      CharacterControlText.personality => latest.copyWith(personality: value),
      CharacterControlText.scenario => latest.copyWith(scenario: value),
      CharacterControlText.firstMes => latest.copyWith(firstMes: value),
      CharacterControlText.mesExample => latest.copyWith(mesExample: value),
      CharacterControlText.systemPrompt => latest.copyWith(systemPrompt: value),
      CharacterControlText.postHistoryInstructions => latest.copyWith(
        postHistoryInstructions: value,
      ),
      CharacterControlText.creatorNotes => latest.copyWith(creatorNotes: value),
      CharacterControlText.depthPrompt => latest.copyWith(
        depthPrompt: value,
        extensions: value.isEmpty
            ? ({...latest.extensions}..remove('depth_prompt'))
            : {
                ...latest.extensions,
                'depth_prompt': {
                  if (latest.extensions['depth_prompt'] is Map)
                    ...Map<String, dynamic>.from(
                      latest.extensions['depth_prompt'] as Map,
                    ),
                  'prompt': value,
                  'depth': latest.depthPromptDepth,
                  'role': latest.depthPromptRole,
                },
              },
      ),
      CharacterControlText.world => latest.copyWith(
        world: value.isEmpty ? null : value,
        extensions: {...latest.extensions}..remove('world'),
      ),
    };
    final tokens = Value(estimateCharacterTokens(next));
    final text = Value(value);
    final update = switch (field) {
      CharacterControlText.name => CharactersCompanion(
        name: text,
        tokenCount: tokens,
      ),
      CharacterControlText.description => CharactersCompanion(
        description: text,
        tokenCount: tokens,
      ),
      CharacterControlText.personality => CharactersCompanion(
        personality: text,
        tokenCount: tokens,
      ),
      CharacterControlText.scenario => CharactersCompanion(
        scenario: text,
        tokenCount: tokens,
      ),
      CharacterControlText.firstMes => CharactersCompanion(
        firstMes: text,
        tokenCount: tokens,
      ),
      CharacterControlText.mesExample => CharactersCompanion(
        mesExample: text,
        tokenCount: tokens,
      ),
      CharacterControlText.systemPrompt => CharactersCompanion(
        systemPrompt: text,
        tokenCount: tokens,
      ),
      CharacterControlText.postHistoryInstructions => CharactersCompanion(
        postHistoryInstructions: text,
        tokenCount: tokens,
      ),
      CharacterControlText.creatorNotes => CharactersCompanion(
        creatorNotes: text,
        tokenCount: tokens,
      ),
      _ => CharactersCompanion(
        extensionsJson: Value(_encodeCharacterExtensions(next)),
        tokenCount: tokens,
      ),
    };
    if (!current()) return false;
    await (_db.update(
      _db.characters,
    )..where((t) => t.charId.equals(latest.id))).write(update);
    return true;
  });

  Future<bool> controlGroupFlags({
    required List<Character> expected,
    bool? favorite,
    bool? hidden,
    required bool Function() current,
  }) => _db.transaction(() async {
    if (expected.isEmpty || !current()) return false;
    final group = expected.first.variantGroupId;
    final latest = await getVariants(group);
    if (!current() ||
        latest.length != expected.length ||
        !latest.every((c) => expected.contains(c))) {
      return false;
    }
    await (_db.update(
      _db.characters,
    )..where((t) => _groupPredicate(t, group))).write(
      CharactersCompanion(
        fav: favorite == null ? const Value.absent() : Value(favorite),
        hidden: hidden == null ? const Value.absent() : Value(hidden),
      ),
    );
    return true;
  });
}
