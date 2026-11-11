import '../../models/character_knowledge_fact.dart';
import '../tokenizer.dart';

/// Renders scoped, committed character deltas as a separate prompt layer.
///
/// This deliberately does not merge facts into a character card: a fact about
/// Lucy's relationship with Danvi must not silently become a global personality
/// rewrite. The model gets the card normally, then this bounded higher-priority
/// delta for the relevant relationship/subject only.
///
/// Fact selection has two tiers:
///   - Tier A (canon-critical): `persistent_condition`, `commitment`,
///     `identity_development`. These are considered first, but still obey the
///     token budget. This prevents an accumulated commitment history from
///     bypassing the effective-canon ceiling.
///   - Tier B (priority): `relationship`. Bypasses the relevance filter (a
///     durable relationship truth must persist even when the subject is not
///     named literally in the latest turn).
///   - Relevance-caught: `knowledge`, `behavior_change`, `goal`. Included only
///     when their subject/entities/topics appear in the latest user+assistant
///     text, sorted by importance then recency.
///
/// [maxFacts] is retained as an optional compatibility/testing bound. The
/// production bound is [maxTokens], including this block's wrapper and header.
String? compileCharacterKnowledgeProjection(
  List<CharacterKnowledgeFact> facts, {
  String latestUserText = '',
  String latestAssistantText = '',
  int? maxFacts,
  int maxTokens = 1200,
  int Function(String) tokenCounter = estimateTokens,
}) {
  if (facts.isEmpty || (maxFacts != null && maxFacts <= 0) || maxTokens <= 0) {
    return null;
  }

  final context = '$latestUserText\n$latestAssistantText'.toLowerCase();
  bool relevant(CharacterKnowledgeFact fact) {
    if (context.trim().isEmpty) return true;
    final terms =
        <String>{
              fact.subjectName,
              ...fact.entities.where(
                (entity) =>
                    entity.toLowerCase() != fact.knowerName.toLowerCase(),
              ),
              ...fact.topics,
            }
            .map((term) => term.trim().toLowerCase())
            .where((term) => term.length >= 3);
    return terms.any(context.contains);
  }

  final tierA = facts.where(_isCanonCriticalFact).toList()
    ..sort((left, right) => right.importance.compareTo(left.importance));
  final tierBAndRelevance =
      <CharacterKnowledgeFact>{
          ...facts.where(_isRelationshipFact),
          ...facts.where(relevant),
        }.where((fact) => !_isCanonCriticalFact(fact)).toList()
        ..sort((left, right) {
          final leftPriority = _isRelationshipFact(left);
          final rightPriority = _isRelationshipFact(right);
          if (leftPriority != rightPriority) return rightPriority ? 1 : -1;
          final importance = right.importance.compareTo(left.importance);
          return importance != 0
              ? importance
              : right.updatedAt.compareTo(left.updatedAt);
        });

  final ordered = [...tierA, ...tierBAndRelevance];
  final candidates = maxFacts == null
      ? ordered
      : ordered.take(maxFacts).toList(growable: false);
  final lines = <String>[];
  for (final fact in candidates) {
    final scope = fact.scopeKey.isNotEmpty
        ? fact.scopeKey
        : '${fact.factClass.wireName}:${fact.subjectKey}';
    final subject = fact.subjectName.isNotEmpty
        ? fact.subjectName
        : fact.subjectKey;
    final knower = fact.knowerName.isNotEmpty
        ? fact.knowerName
        : fact.knowerKey;
    final line =
        '- [$scope] $knower ${fact.predicate} $subject: ${fact.object} '
        '(${fact.epistemicState.wireName}).';
    final candidate = _render(lines.followedBy([line]));
    if (tokenCounter(candidate) <= maxTokens) lines.add(line);
  }
  return lines.isEmpty ? null : _render(lines);
}

String _render(Iterable<String> lines) =>
    '''<current_character_state>
These are committed current character truths. They override conflicting base-card traits within their stated scope. Episodic MemoryBook and recalled-message evidence may explain them but cannot override them. Omitted facts remain unresolved, not false or unknown. Do not generalize them or mention this block.
${lines.join('\n')}
</current_character_state>''';

bool _isCanonCriticalFact(CharacterKnowledgeFact fact) =>
    fact.factClass == CharacterKnowledgeFactClass.persistentCondition ||
    fact.factClass == CharacterKnowledgeFactClass.commitment ||
    fact.factClass == CharacterKnowledgeFactClass.identityDevelopment;

bool _isRelationshipFact(CharacterKnowledgeFact fact) =>
    fact.factClass == CharacterKnowledgeFactClass.relationship;
