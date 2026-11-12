import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../models/character_knowledge_fact.dart';
import '../../models/tracker.dart';
import '../tokenizer.dart';
import 'effective_canon_prompt_formatter.dart';

typedef CanonTokenCounter = int Function(String text);

enum CanonItemTier { mandatory, roster, spotlight, relevant, archive }

enum CanonPackingReason { selected, budgetDeferred, deduped }

final class EffectiveCanonTokenBudget {
  static const defaultNominalTokens = 13000;
  static const defaultHardCeilingTokens = 15000;
  static const currentSceneLaneTokens = 8000;
  static const durableKnowledgeFloorTokens = 5000;

  EffectiveCanonTokenBudget({
    required this.nominalTokens,
    required this.hardCeilingTokens,
    required this.mandatoryReserveTokens,
  }) {
    if (nominalTokens < 0 ||
        hardCeilingTokens < 0 ||
        mandatoryReserveTokens < 0 ||
        nominalTokens > hardCeilingTokens) {
      throw ArgumentError(
        'Effective canon budgets must be non-negative and nominal must not '
        'exceed the hard ceiling.',
      );
    }
  }

  factory EffectiveCanonTokenBudget.forResponder({
    required int contextSize,
    required int outputTokens,
    int reservedPromptTokens = 0,
    int presentEntityCount = 0,
  }) {
    final available = math.max(
      0,
      contextSize - outputTokens - reservedPromptTokens,
    );
    final reserve = math.min(available, math.max(192, presentEntityCount * 48));
    final nominal = math.min(
      available,
      math.max(reserve, defaultNominalTokens),
    );
    final hard = math.min(
      available,
      math.max(nominal, defaultHardCeilingTokens),
    );
    return EffectiveCanonTokenBudget(
      nominalTokens: nominal,
      hardCeilingTokens: hard,
      mandatoryReserveTokens: reserve,
    );
  }

  final int nominalTokens;
  final int hardCeilingTokens;
  final int mandatoryReserveTokens;
}

final class EffectiveCanonOverflowAllocation {
  const EffectiveCanonOverflowAllocation({
    required this.recallBudgetTokens,
    required this.memoryBudgetTokens,
    required this.reclaimedRecallTokens,
    required this.reclaimedMemoryTokens,
    required this.unfundedOverflowTokens,
  });

  factory EffectiveCanonOverflowAllocation.allocate({
    required int requiredOverflowTokens,
    required int recallBudgetTokens,
    int? memoryBudgetTokens,
  }) {
    final overflow = math.max(0, requiredOverflowTokens);
    final recall = math.max(0, recallBudgetTokens);
    final memory = memoryBudgetTokens == null
        ? null
        : math.max(0, memoryBudgetTokens);
    final reclaimedRecall = math.min(overflow, recall);
    final afterRecall = overflow - reclaimedRecall;
    final reclaimedMemory = memory == null ? 0 : math.min(afterRecall, memory);
    return EffectiveCanonOverflowAllocation(
      recallBudgetTokens: recall - reclaimedRecall,
      memoryBudgetTokens: memory == null ? null : memory - reclaimedMemory,
      reclaimedRecallTokens: reclaimedRecall,
      reclaimedMemoryTokens: reclaimedMemory,
      unfundedOverflowTokens: afterRecall - reclaimedMemory,
    );
  }

  final int recallBudgetTokens;
  final int? memoryBudgetTokens;
  final int reclaimedRecallTokens;
  final int reclaimedMemoryTokens;
  final int unfundedOverflowTokens;
}

final class CanonPromptItem {
  const CanonPromptItem({
    required this.stableId,
    required this.tier,
    required this.renderedText,
    required this.channel,
    this.entityKeys = const <String>{},
    this.semanticGroupId = '',
    this.hardConstraint = false,
    this.rank = 0,
  });

  final String stableId;
  final CanonItemTier tier;
  final String renderedText;
  final String channel;
  final Set<String> entityKeys;
  final String semanticGroupId;
  final bool hardConstraint;
  final int rank;
}

final class CanonPackingDecision {
  const CanonPackingDecision({
    required this.itemId,
    required this.channel,
    required this.reason,
    required this.tokenCost,
  });

  final String itemId;
  final String channel;
  final CanonPackingReason reason;
  final int tokenCost;
}

final class EffectiveCanonPackingDiagnostics {
  const EffectiveCanonPackingDiagnostics({
    required this.nominalTokens,
    required this.hardCeilingTokens,
    required this.mandatoryReserveTokens,
    required this.usedTokens,
    required this.channelTokens,
    required this.presentEntityCount,
    required this.spotlightEntityIds,
    required this.decisions,
    required this.requiredOverflowTokens,
    required this.tokenizerMode,
    required this.selectionIdentity,
  });

  final int nominalTokens;
  final int hardCeilingTokens;
  final int mandatoryReserveTokens;
  final int usedTokens;
  final Map<String, int> channelTokens;
  final int presentEntityCount;
  final List<String> spotlightEntityIds;
  final List<CanonPackingDecision> decisions;
  final int requiredOverflowTokens;
  final String tokenizerMode;
  final String selectionIdentity;
}

final class EffectiveCanonPackedContent {
  const EffectiveCanonPackedContent({
    required this.characterKnowledge,
    required this.sessionState,
    required this.arcContent,
    required this.diagnostics,
  });

  final String? characterKnowledge;
  final String? sessionState;
  final String? arcContent;
  final EffectiveCanonPackingDiagnostics diagnostics;
}

final class EffectiveCanonBudgetExceeded implements Exception {
  const EffectiveCanonBudgetExceeded({
    required this.requiredTokens,
    required this.hardCeilingTokens,
  });

  final int requiredTokens;
  final int hardCeilingTokens;

  @override
  String toString() =>
      'Mandatory effective canon requires $requiredTokens tokens, above the '
      '$hardCeilingTokens token hard ceiling.';
}

abstract final class EffectiveCanonTokenPacker {
  static EffectiveCanonPackedContent pack(
    EffectiveCanonPromptProjection projection, {
    required EffectiveCanonTokenBudget budget,
    required String latestUserText,
    required String latestAssistantText,
    String focalUserName = '',
    @Deprecated('Raw arc text is not accepted by semantic token packing.')
    String? arcContent,
    CanonTokenCounter tokenCounter = estimateTokens,
    String? tokenizerMode,
  }) {
    final context = '$latestUserText\n$latestAssistantText'.toLowerCase();
    final trackers = _resolvedTrackers(projection.trackers);
    final present = _presentEntities(trackers);
    final spotlight = _spotlightEntities(
      trackers,
      present: present,
      context: context,
    );
    final items = _items(
      projection,
      trackers: trackers,
      present: present,
      spotlight: spotlight,
      context: context,
      focalUserName: focalUserName,
    );
    final selected = <CanonPromptItem>[];
    final decisions = <CanonPackingDecision>[];
    final seen = <String>{};
    final itemCosts = <CanonPromptItem, int>{};

    int cost(CanonPromptItem item) =>
        itemCosts.putIfAbsent(item, () => tokenCounter(item.renderedText));
    bool addUnique(CanonPromptItem item) {
      final normalized = item.renderedText
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (!seen.add(normalized)) {
        decisions.add(
          CanonPackingDecision(
            itemId: item.stableId,
            channel: item.channel,
            reason: CanonPackingReason.deduped,
            tokenCost: cost(item),
          ),
        );
        return false;
      }
      selected.add(item);
      return true;
    }

    final ordered = [...items]..sort(_compareItems);
    for (final item in ordered.where((item) => item.hardConstraint)) {
      if (!addUnique(item)) continue;
      decisions.add(
        CanonPackingDecision(
          itemId: item.stableId,
          channel: item.channel,
          reason: CanonPackingReason.selected,
          tokenCost: cost(item),
        ),
      );
    }

    final mandatoryRendered = _render(selected);
    final mandatoryTokens = tokenCounter(mandatoryRendered.combined);
    if (mandatoryTokens > budget.hardCeilingTokens) {
      throw EffectiveCanonBudgetExceeded(
        requiredTokens: mandatoryTokens,
        hardCeilingTokens: budget.hardCeilingTokens,
      );
    }
    final usesDefaultLanes =
        budget.nominalTokens >= EffectiveCanonTokenBudget.defaultNominalTokens;
    final sceneLaneLimit = usesDefaultLanes
        ? math.min(
            EffectiveCanonTokenBudget.currentSceneLaneTokens,
            budget.nominalTokens,
          )
        : budget.nominalTokens;
    int sceneTokens(Iterable<CanonPromptItem> source) => tokenCounter(
      _render(
        source.where((item) => item.channel != 'knowledge').toList(),
      ).combined,
    );
    final mandatorySceneTokens = sceneTokens(selected);
    final sceneOverflow = math.max(0, mandatorySceneTokens - sceneLaneLimit);
    final laneAwareNominal = math.min(
      budget.hardCeilingTokens,
      budget.nominalTokens + sceneOverflow,
    );
    final overflow = math.max(0, mandatoryTokens - budget.nominalTokens);
    final softLimit = math.max(mandatoryTokens, laneAwareNominal);
    var estimatedUsedTokens = mandatoryTokens;
    final selectedChannels = selected.map((item) => item.channel).toSet();
    final selectedSceneChannels = selected
        .where((item) => item.channel != 'knowledge')
        .map((item) => item.channel)
        .toSet();
    var estimatedSceneTokens = mandatorySceneTokens;
    final optionalOutcomes = <CanonPromptItem, CanonPackingReason>{};
    final selectedOptional = <CanonPromptItem>[];
    final selectedOptionalScene = <CanonPromptItem>[];
    final useAdditiveSelection = _tokenCounterScalesWithInput(tokenCounter);
    final optional = ordered.where((item) => !item.hardConstraint).toList();
    final laneOrdered = [
      ...optional.where((item) => item.channel != 'knowledge'),
      ...optional.where((item) => item.channel == 'knowledge'),
    ];
    final effectiveSceneLimit = math.max(sceneLaneLimit, mandatorySceneTokens);
    for (final item in laneOrdered) {
      final normalized = item.renderedText
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (seen.contains(normalized)) {
        optionalOutcomes[item] = CanonPackingReason.deduped;
        continue;
      }
      final itemTokenCost = cost(item);
      if (!useAdditiveSelection) {
        if (item.channel != 'knowledge' &&
            sceneTokens([...selected, item]) > effectiveSceneLimit) {
          optionalOutcomes[item] = CanonPackingReason.budgetDeferred;
          continue;
        }
        final candidateUsedTokens = tokenCounter(
          _render([...selected, item]).combined,
        );
        if (candidateUsedTokens > softLimit) {
          optionalOutcomes[item] = CanonPackingReason.budgetDeferred;
          continue;
        }
        addUnique(item);
        selectedOptional.add(item);
        if (item.channel != 'knowledge') selectedOptionalScene.add(item);
        selectedChannels.add(item.channel);
        if (item.channel != 'knowledge') {
          selectedSceneChannels.add(item.channel);
          estimatedSceneTokens = sceneTokens(selected);
        }
        estimatedUsedTokens = candidateUsedTokens;
        optionalOutcomes[item] = CanonPackingReason.selected;
        continue;
      }
      // Item costs are additive enough for the cheap selection pass, but XML
      // channel wrappers and line boundaries must also be reserved. The exact
      // complete prompt is validated below, once, rather than re-tokenizing the
      // growing prompt for every selected fact.
      var incrementalCost = itemTokenCost + 1;
      if (!selectedChannels.contains(item.channel)) {
        incrementalCost += math.max(
          0,
          tokenCounter(_render([item]).combined) - itemTokenCost,
        );
      }
      var incrementalSceneCost = 0;
      if (item.channel != 'knowledge') {
        incrementalSceneCost = itemTokenCost + 1;
        if (!selectedSceneChannels.contains(item.channel)) {
          incrementalSceneCost += math.max(
            0,
            tokenCounter(_render([item]).combined) - itemTokenCost,
          );
        }
        if (estimatedSceneTokens + incrementalSceneCost > effectiveSceneLimit) {
          optionalOutcomes[item] = CanonPackingReason.budgetDeferred;
          continue;
        }
      }
      if (estimatedUsedTokens + incrementalCost > softLimit) {
        optionalOutcomes[item] = CanonPackingReason.budgetDeferred;
        continue;
      }
      addUnique(item);
      selectedOptional.add(item);
      if (item.channel != 'knowledge') selectedOptionalScene.add(item);
      selectedChannels.add(item.channel);
      if (item.channel != 'knowledge') {
        selectedSceneChannels.add(item.channel);
        estimatedSceneTokens += incrementalSceneCost;
      }
      estimatedUsedTokens += incrementalCost;
      optionalOutcomes[item] = CanonPackingReason.selected;
    }

    // BPE token counts are not strictly additive across text boundaries. Keep
    // the selection pass cheap, then enforce the exact complete-prompt limit.
    // The +1 line reserve above normally makes this a single tokenization; the
    // loop is only a bounded repair for an unusual boundary expansion.
    var exactSceneTokens = sceneTokens(selected);
    while (exactSceneTokens > effectiveSceneLimit &&
        selectedOptionalScene.isNotEmpty) {
      final removed = selectedOptionalScene.removeLast();
      selectedOptional.remove(removed);
      selected.remove(removed);
      optionalOutcomes[removed] = CanonPackingReason.budgetDeferred;
      exactSceneTokens = sceneTokens(selected);
    }
    var exactRendered = _render(selected);
    var exactUsedTokens = tokenCounter(exactRendered.combined);
    while (exactUsedTokens > softLimit && selectedOptional.isNotEmpty) {
      final removed = selectedOptional.removeLast();
      selected.remove(removed);
      optionalOutcomes[removed] = CanonPackingReason.budgetDeferred;
      exactRendered = _render(selected);
      exactUsedTokens = tokenCounter(exactRendered.combined);
    }
    for (final item in ordered.where((item) => !item.hardConstraint)) {
      final reason = optionalOutcomes[item];
      if (reason == null) continue;
      decisions.add(
        CanonPackingDecision(
          itemId: item.stableId,
          channel: item.channel,
          reason: reason,
          tokenCost: cost(item),
        ),
      );
    }

    // [arcContent] is intentionally ignored. Arc tracker rows are grouped into
    // semantic items by [_items], so guards cannot disappear with an optional
    // pre-rendered blob and no raw text can bypass this budget.
    final rendered = exactRendered;
    final channelTokens = <String, int>{
      if (rendered.knowledge != null)
        'knowledge': tokenCounter(rendered.knowledge!),
      if (rendered.state != null) 'state': tokenCounter(rendered.state!),
      if (rendered.transitions != null)
        'transition': tokenCounter(rendered.transitions!),
      if (rendered.arc != null) 'arc': tokenCounter(rendered.arc!),
    };
    final used = tokenCounter(rendered.combined);
    return EffectiveCanonPackedContent(
      characterKnowledge: rendered.knowledge,
      sessionState:
          [
            rendered.state,
            rendered.transitions,
          ].whereType<String>().join('\n\n').trim().isEmpty
          ? null
          : [
              rendered.state,
              rendered.transitions,
            ].whereType<String>().join('\n\n'),
      arcContent: rendered.arc,
      diagnostics: EffectiveCanonPackingDiagnostics(
        nominalTokens: budget.nominalTokens,
        hardCeilingTokens: budget.hardCeilingTokens,
        mandatoryReserveTokens: budget.mandatoryReserveTokens,
        usedTokens: used,
        channelTokens: Map.unmodifiable(channelTokens),
        presentEntityCount: present.length,
        spotlightEntityIds: List.unmodifiable(
          spotlight.map(
            (entity) => _opaqueId(projection.cacheIdentity, 'entity:$entity'),
          ),
        ),
        decisions: List.unmodifiable(
          decisions.map(
            (decision) => CanonPackingDecision(
              itemId: _opaqueId(projection.cacheIdentity, decision.itemId),
              channel: decision.channel,
              reason: decision.reason,
              tokenCost: decision.tokenCost,
            ),
          ),
        ),
        requiredOverflowTokens: overflow,
        tokenizerMode:
            tokenizerMode ?? (o200kBaseLoaded ? 'o200k' : 'fallback'),
        selectionIdentity: _selectionIdentity(
          projection: projection,
          budget: budget,
          tokenizerMode:
              tokenizerMode ?? (o200kBaseLoaded ? 'o200k' : 'fallback'),
          selected: selected,
        ),
      ),
    );
  }
}

bool _tokenCounterScalesWithInput(CanonTokenCounter tokenCounter) {
  // Real tokenizers and the documented character fallback scale with ordinary
  // input length. Tests and embedders may inject semantic/non-additive counters;
  // those retain exact per-candidate selection rather than inheriting an
  // additivity assumption their contract does not provide.
  const shortProbe = 'neutral token boundary ';
  final shortCost = tokenCounter(shortProbe);
  final longCost = tokenCounter(shortProbe * 16);
  return longCost > shortCost;
}

List<CanonPromptItem> _items(
  EffectiveCanonPromptProjection projection, {
  required List<Tracker> trackers,
  required List<String> present,
  required List<String> spotlight,
  required String context,
  required String focalUserName,
}) {
  final items = <CanonPromptItem>[];
  final lockedTargets = trackers
      .where((tracker) => tracker.name.startsWith('canon_lock:'))
      .map((tracker) => tracker.name.substring('canon_lock:'.length))
      .toSet();
  for (final fact in projection.facts) {
    final entities = <String>{
      fact.knowerKey,
      fact.knowerName,
      fact.subjectKey,
      fact.subjectName,
      ...fact.entities,
    }.where((value) => value.trim().isNotEmpty).toSet();
    final mentioned = entities.any(
      (entity) => _contextContains(context, entity),
    );
    final spotlightFact = entities.any(
      (entity) => spotlight.any((name) => _sameEntity(entity, name)),
    );
    if (fact.factClass == CharacterKnowledgeFactClass.relationship &&
        !_relationshipEntitiesRelevant(
          entities,
          spotlight: spotlight,
          focalUserName: focalUserName,
          context: context,
        )) {
      continue;
    }
    final hard =
        fact.factClass == CharacterKnowledgeFactClass.persistentCondition ||
        ((spotlightFact || mentioned) &&
            _looksLikeBoundary('${fact.predicate} ${fact.object}'));
    final tier = hard
        ? CanonItemTier.mandatory
        : spotlightFact || mentioned
        ? CanonItemTier.spotlight
        : fact.factClass == CharacterKnowledgeFactClass.commitment ||
              fact.factClass == CharacterKnowledgeFactClass.relationship
        ? CanonItemTier.relevant
        : CanonItemTier.archive;
    final scope = fact.scopeKey.isNotEmpty
        ? fact.scopeKey
        : '${fact.factClass.wireName}:${fact.subjectKey}';
    final subject = fact.subjectName.isNotEmpty
        ? fact.subjectName
        : fact.subjectKey;
    final knower = fact.knowerName.isNotEmpty
        ? fact.knowerName
        : fact.knowerKey;
    items.add(
      CanonPromptItem(
        stableId: 'fact:${fact.id}',
        tier: tier,
        renderedText:
            '- [${_escapeData(scope)}] ${_escapeData(knower)} '
            '${_escapeData(fact.predicate)} ${_escapeData(subject)}: '
            '${_escapeData(fact.object)} '
            '(${fact.epistemicState.wireName}).',
        channel: 'knowledge',
        entityKeys: entities,
        semanticGroupId: scope,
        hardConstraint: hard,
        rank: (fact.importance * 1000).round() + fact.updatedAt,
      ),
    );
  }

  final presentTracker = trackers
      .where(
        (tracker) =>
            _effectiveTrackerKey(tracker.name) == 'scene.present_entities',
      )
      .lastOrNull;
  if (presentTracker != null && present.isNotEmpty) {
    items.add(
      CanonPromptItem(
        stableId: 'tracker:scene.present_entities',
        tier: CanonItemTier.mandatory,
        renderedText: 'Present now: ${present.map(_escapeData).join(', ')}.',
        channel: 'state',
        hardConstraint: true,
        rank: 1000000,
      ),
    );
    for (final name in present) {
      items.add(
        CanonPromptItem(
          stableId: 'roster:${_normalize(name)}',
          tier: CanonItemTier.roster,
          renderedText: '- ${_escapeData(name)}: present in the current scene.',
          channel: 'state',
          entityKeys: {name},
          semanticGroupId: 'roster:${_normalize(name)}',
          hardConstraint: true,
          rank: 900000,
        ),
      );
    }
  }

  items.addAll(_arcItems(trackers, context: context));

  for (final tracker in trackers.where(
    (tracker) => tracker.name.startsWith('canon_lock:'),
  )) {
    final target = tracker.name.substring('canon_lock:'.length);
    items.add(
      CanonPromptItem(
        stableId: 'control:${tracker.name}',
        tier: CanonItemTier.mandatory,
        renderedText:
            '- [${_escapeData(target)}] locked by explicit user control.',
        channel: 'state',
        semanticGroupId: target,
        hardConstraint: true,
        rank: tracker.updatedAt,
      ),
    );
  }

  for (final tracker in trackers) {
    if (tracker.value.trim().isEmpty ||
        _effectiveTrackerKey(tracker.name) == 'scene.present_entities' ||
        tracker.name.startsWith('_ledger:') ||
        tracker.name.startsWith('canon_lock:')) {
      continue;
    }
    final target = _effectiveTrackerKey(tracker.name);
    if (target.startsWith('arc:')) continue;
    final entities = _trackerEntities(target);
    final isSpotlight = entities.any(
      (entity) => spotlight.any((name) => _sameEntity(entity, name)),
    );
    final relationshipAllowed =
        !target.startsWith('relationship:') ||
        _relationshipRelevant(
          target,
          spotlight: spotlight,
          focalUserName: focalUserName,
          context: context,
        );
    if (!relationshipAllowed) continue;
    final presentEntity = entities.any(
      (entity) => present.any((name) => _sameEntity(entity, name)),
    );
    final capsuleField = presentEntity && _isRosterCapsuleField(target);
    final hard =
        _isManual(tracker.name) ||
        lockedTargets.contains(target) ||
        _isHardTrackerTarget(target) ||
        capsuleField;
    final tier = hard
        ? capsuleField
              ? CanonItemTier.roster
              : CanonItemTier.mandatory
        : isSpotlight
        ? CanonItemTier.spotlight
        : target.startsWith('world:') || target.startsWith('relationship:')
        ? CanonItemTier.relevant
        : CanonItemTier.archive;
    items.add(
      CanonPromptItem(
        stableId: 'tracker:${tracker.name}',
        tier: tier,
        renderedText:
            '- [${_escapeData(target)}] ${_escapeData(tracker.value)}',
        channel: 'state',
        entityKeys: entities,
        semanticGroupId: target.split('.').first,
        hardConstraint: hard,
        rank: isSpotlight
            ? _spotlightFieldPriority(target) * 1000000 -
                  _spotlightIndex(entities, spotlight)
            : tracker.updatedAt,
      ),
    );
  }

  final transitions = projection.transitions.isNotEmpty
      ? projection.transitions
      : projection.unblockedTransitionClaims.indexed
            .map(
              (item) => EffectiveCanonTransitionProjection(
                id: 'legacy-${item.$1}',
                semanticScopeKey: '',
                affectedTrackerKeys: const [],
                claim: item.$2,
              ),
            )
            .toList(growable: false);
  for (final transition in transitions) {
    items.add(
      CanonPromptItem(
        stableId: 'transition:${transition.id}',
        tier:
            _looksLikeBoundary(
              '${transition.semanticScopeKey} ${transition.claim}',
            )
            ? CanonItemTier.mandatory
            : CanonItemTier.relevant,
        renderedText: '- ${_escapeData(transition.claim)}',
        channel: 'transition',
        semanticGroupId: transition.semanticScopeKey,
        hardConstraint: _looksLikeBoundary(
          '${transition.semanticScopeKey} ${transition.claim}',
        ),
      ),
    );
  }
  return items;
}

List<CanonPromptItem> _arcItems(
  List<Tracker> trackers, {
  required String context,
}) {
  final lockedTargets = trackers
      .where((tracker) => tracker.name.startsWith('canon_lock:arc:'))
      .map((tracker) => tracker.name.substring('canon_lock:'.length))
      .toSet();
  final fields = <String, Map<String, Tracker>>{};
  for (final tracker in trackers.where(
    (tracker) =>
        _effectiveTrackerKey(tracker.name).startsWith('arc:') &&
        tracker.value.isNotEmpty,
  )) {
    final remainder = _effectiveTrackerKey(tracker.name).substring(4);
    final separator = remainder.indexOf('.');
    if (separator <= 0) continue;
    fields.putIfAbsent(
      remainder.substring(0, separator),
      () => {},
    )[remainder.substring(separator + 1)] = tracker;
  }
  final items = <CanonPromptItem>[];
  for (final id in fields.keys.toList()..sort()) {
    final arc = fields[id]!;
    String value(String key) => arc[key]?.value.trim() ?? '';
    final status = value('status');
    final title = value('title').isEmpty ? id : value('title');
    final summary = value('summary');
    final doNotReopen = value('do_not_reopen').toLowerCase() == 'true';
    final cardOverride = value('card_override');
    final terminal = const {
      'completed',
      'failed',
      'abandoned',
      'superseded',
    }.contains(status.toLowerCase());
    final mentioned =
        _contextContains(context, title) ||
        (summary.isNotEmpty && _contextContains(context, summary));
    final summaryHard =
        _isManual(arc['summary']?.name ?? '') ||
        lockedTargets.contains('arc:$id.summary');
    final hard =
        doNotReopen ||
        cardOverride.isNotEmpty ||
        arc.entries.any(
          (entry) =>
              entry.key != 'summary' &&
              (_isManual(entry.value.name) ||
                  lockedTargets.contains('arc:$id.${entry.key}')),
        );
    if (terminal && !hard && !mentioned) continue;
    final newest = arc.values.fold<int>(
      0,
      (current, tracker) => math.max(current, tracker.updatedAt),
    );
    final guard = [
      if (doNotReopen) 'do not reopen',
      if (cardOverride.isNotEmpty) cardOverride,
    ].join('; ');
    items.add(
      CanonPromptItem(
        stableId: 'arc:$id:state',
        tier: hard
            ? CanonItemTier.mandatory
            : terminal || status.toLowerCase() == 'paused'
            ? CanonItemTier.archive
            : CanonItemTier.relevant,
        renderedText:
            '- ${_escapeData(title)}: ${_escapeData(status.isEmpty ? 'active' : status)}'
            '${guard.isEmpty ? '.' : '; ${_escapeData(guard)}.'}',
        channel: 'arc',
        semanticGroupId: 'arc:$id',
        hardConstraint: hard,
        rank: newest,
      ),
    );
    if (summary.isNotEmpty) {
      items.add(
        CanonPromptItem(
          stableId: 'arc:$id:summary',
          tier: summaryHard
              ? CanonItemTier.mandatory
              : mentioned
              ? CanonItemTier.spotlight
              : CanonItemTier.archive,
          renderedText:
              '- ${_escapeData(title)} summary: ${_escapeData(summary)}',
          channel: 'arc',
          semanticGroupId: 'arc:$id',
          hardConstraint: summaryHard,
          rank: newest,
        ),
      );
    }
  }
  return items;
}

({
  String? knowledge,
  String? state,
  String? transitions,
  String? arc,
  String combined,
})
_render(List<CanonPromptItem> items) {
  final knowledgeItems = items.where((item) => item.channel == 'knowledge');
  final stateItems = items.where((item) => item.channel == 'state');
  final transitionItems = items.where((item) => item.channel == 'transition');
  final arcItems = items.where((item) => item.channel == 'arc');
  final knowledge = knowledgeItems.isEmpty
      ? null
      : '<current_character_state>\n'
            'These are committed current character truths. They override '
            'conflicting base-card traits within their stated scope. Omitted '
            'facts remain unresolved, not false or unknown. Do not generalize '
            'them or mention this block.\n'
            '${knowledgeItems.map((item) => item.renderedText).join('\n')}\n'
            '</current_character_state>';
  final state = stateItems.isEmpty
      ? null
      : '<studio_session_state>\n'
            'These are established facts from this chat. They override '
            'conflicting character-card baseline. Omission is not ignorance.\n'
            '${stateItems.map((item) => item.renderedText).join('\n')}\n'
            '</studio_session_state>';
  final transitions = transitionItems.isEmpty
      ? null
      : '<effective_canon_transitions>\n'
            'Canonical transition claims for unblocked scopes:\n'
            '${transitionItems.map((item) => item.renderedText).join('\n')}\n'
            '</effective_canon_transitions>';
  final arc = arcItems.isEmpty
      ? null
      : '<arc_state>\n'
            'Session canon overrides character-card baseline when conflicting.\n'
            '${arcItems.map((item) => item.renderedText).join('\n')}\n'
            '</arc_state>';
  final combined = [
    knowledge,
    state,
    transitions,
    arc,
  ].whereType<String>().join('\n\n');
  return (
    knowledge: knowledge,
    state: state,
    transitions: transitions,
    arc: arc,
    combined: combined,
  );
}

int _compareItems(CanonPromptItem left, CanonPromptItem right) {
  final tier = left.tier.index.compareTo(right.tier.index);
  if (tier != 0) return tier;
  final rank = right.rank.compareTo(left.rank);
  if (rank != 0) return rank;
  return left.stableId.compareTo(right.stableId);
}

List<Tracker> _resolvedTrackers(List<Tracker> trackers) {
  final overrides = <String, Tracker>{};
  for (final tracker in trackers.where(
    (tracker) => tracker.name.startsWith('canon_override:'),
  )) {
    overrides[_effectiveTrackerKey(tracker.name)] = tracker;
  }
  return [
    for (final tracker in trackers)
      if (!tracker.name.startsWith('canon_override:') &&
          !overrides.containsKey(tracker.name))
        tracker,
    ...overrides.values,
  ];
}

String _effectiveTrackerKey(String key) => key.startsWith('canon_override:')
    ? key.substring('canon_override:'.length)
    : key;

List<String> _presentEntities(List<Tracker> trackers) =>
    trackers
        .where(
          (tracker) =>
              _effectiveTrackerKey(tracker.name) == 'scene.present_entities',
        )
        .expand((tracker) => tracker.value.split(RegExp(r'[,;\n]+')))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();

List<String> _spotlightEntities(
  List<Tracker> trackers, {
  required List<String> present,
  required String context,
}) {
  final scores = <String, int>{};
  for (final name in present) {
    scores[name] = _contextContains(context, name) ? 100 : 0;
  }
  for (final tracker in trackers) {
    for (final entity in _trackerEntities(tracker.name)) {
      final presentName = present
          .where((name) => _sameEntity(name, entity))
          .firstOrNull;
      if (presentName == null) continue;
      var score = scores[presentName] ?? 0;
      if (_contextContains(context, entity)) score += 80;
      if (tracker.name.endsWith('.current_goal') ||
          tracker.name.endsWith('.action') ||
          tracker.name.contains('conflict')) {
        score += 35;
      }
      scores[presentName] = score;
    }
  }
  final ordered = scores.entries.where((entry) => entry.value > 0).toList()
    ..sort((a, b) {
      final score = b.value.compareTo(a.value);
      return score != 0 ? score : a.key.compareTo(b.key);
    });
  final desired = math.min(5, ordered.length);
  return ordered
      .take(desired)
      .map((entry) => entry.key)
      .toList(growable: false);
}

Set<String> _trackerEntities(String key) {
  var value = key;
  if (value.startsWith('canon_override:') || value.startsWith('canon_lock:')) {
    value = value.substring(value.indexOf(':') + 1);
  }
  if (value.startsWith('npc:')) {
    return {value.substring(4).split('.').first};
  }
  if (value.startsWith('relationship:')) {
    return value.substring(13).split('.').first.split(':').toSet();
  }
  return const <String>{};
}

bool _relationshipRelevant(
  String key, {
  required List<String> spotlight,
  required String focalUserName,
  required String context,
}) {
  final entities = _trackerEntities(key).toList(growable: false);
  if (entities.any((entity) => _sameEntity(entity, focalUserName))) return true;
  if (entities.any((entity) => _contextContains(context, entity))) return true;
  return entities.isNotEmpty &&
      entities.every(
        (entity) => spotlight.any((name) => _sameEntity(entity, name)),
      );
}

bool _relationshipEntitiesRelevant(
  Set<String> entities, {
  required List<String> spotlight,
  required String focalUserName,
  required String context,
}) {
  if (entities.any((entity) => _sameEntity(entity, focalUserName))) return true;
  if (entities.any((entity) => _contextContains(context, entity))) return true;
  final spotlightMatches = entities
      .where((entity) => spotlight.any((name) => _sameEntity(entity, name)))
      .length;
  return spotlightMatches >= 2;
}

bool _isRosterCapsuleField(String key) =>
    key.endsWith('.location') ||
    key.endsWith('.ability') ||
    key.endsWith('.physical_condition') ||
    key.endsWith('.hard_boundary') ||
    key.endsWith('.boundary');

bool _isHardTrackerTarget(String key) =>
    key == 'scene.absent_backstory_entities' ||
    key == 'scene.location' ||
    key == 'scene.clock' ||
    key == 'scene.current_thread' ||
    key == 'world:location' ||
    key == 'world:clock' ||
    key.endsWith('.do_not_reopen') ||
    key.endsWith('.card_override') ||
    key.endsWith('.hard_boundary') ||
    key.endsWith('.boundary') ||
    key.endsWith('.physical_constraint') ||
    key.contains('persistent_condition');

int _spotlightFieldPriority(String key) {
  if (key.endsWith('.current_goal') || key.endsWith('.action')) return 5;
  if (key.contains('conflict') || key.contains('tension')) return 4;
  if (key.endsWith('.relationship') || key.startsWith('relationship:')) {
    return 3;
  }
  if (key.endsWith('.mood')) return 2;
  return 1;
}

int _spotlightIndex(Set<String> entities, List<String> spotlight) {
  for (var index = 0; index < spotlight.length; index++) {
    if (entities.any((entity) => _sameEntity(entity, spotlight[index]))) {
      return index;
    }
  }
  return spotlight.length;
}

bool _isManual(String key) =>
    key.startsWith('canon_override:') || key.startsWith('canon_lock:');

bool _looksLikeBoundary(String value) {
  final lower = value.toLowerCase();
  return lower.contains('boundar') ||
      lower.contains('persistent_condition') ||
      lower.contains('hard_constraint') ||
      lower.contains('must_not') ||
      lower.contains('must not') ||
      lower.contains('cannot') ||
      lower.contains('не может') ||
      lower.contains('нельзя') ||
      lower.contains('запрещено') ||
      lower.contains('границ');
}

bool _contextContains(String context, String entity) {
  final needle = _normalize(entity);
  if (needle.length < 2) return false;
  return RegExp(
    '(^|[^\\p{L}\\p{N}_])${RegExp.escape(needle)}(?=\$|[^\\p{L}\\p{N}_])',
    unicode: true,
  ).hasMatch(_normalize(context));
}

bool _sameEntity(String left, String right) =>
    _normalize(left) == _normalize(right);

String _normalize(String value) => value
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^entity:'), '')
    .replaceAll('ё', 'е');

String _escapeData(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _opaqueId(String salt, String value) =>
    'canon-${sha256.convert(utf8.encode('$salt\u0000$value')).toString().substring(0, 16)}';

String _selectionIdentity({
  required EffectiveCanonPromptProjection projection,
  required EffectiveCanonTokenBudget budget,
  required String tokenizerMode,
  required List<CanonPromptItem> selected,
}) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'policy': 1,
          'projection': projection.cacheIdentity,
          'nominal': budget.nominalTokens,
          'hard': budget.hardCeilingTokens,
          'reserve': budget.mandatoryReserveTokens,
          'tokenizer': tokenizerMode,
          'selected': selected.map((item) => item.stableId).toList(),
        }),
      ),
    )
    .toString();
