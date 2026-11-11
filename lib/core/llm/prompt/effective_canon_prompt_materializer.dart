import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../models/ledger_prompt_injection_mode.dart';
import '../tokenizer.dart';
import 'effective_canon_prompt_formatter.dart';
import 'effective_canon_token_packer.dart';
import 'selective_ledger_projection_filter.dart';

final class EffectiveCanonPromptMaterialization {
  const EffectiveCanonPromptMaterialization({
    required this.filteredProjection,
    required this.characterKnowledgeContent,
    required this.studioSessionStateContent,
    required this.arcContent,
    required this.transitionContent,
    required this.diagnostics,
    required this.packingDiagnostics,
    required this.injectionCacheIdentity,
  });

  final EffectiveCanonPromptProjection filteredProjection;
  final String? characterKnowledgeContent;
  final String? studioSessionStateContent;
  final String? arcContent;
  final String? transitionContent;
  final List<LedgerProjectionDiagnostic> diagnostics;
  final EffectiveCanonPackingDiagnostics packingDiagnostics;
  final String injectionCacheIdentity;
}

/// Selects and renders every Ledger-owned prompt channel from one immutable
/// projection under the final responder's token budget.
abstract final class EffectiveCanonPromptMaterializer {
  static EffectiveCanonPromptMaterialization materialize(
    SelectiveLedgerProjectionInput input, {
    required String sessionId,
    String latestUserText = '',
    String latestAssistantText = '',
    int contextSize = 32000,
    int maxTokens = 8000,
    int reservedPromptTokens = 0,
    EffectiveCanonTokenBudget? budget,
    CanonTokenCounter tokenCounter = estimateTokens,
    String? tokenizerMode,
  }) {
    final resolvedBudget = _boundedBudget(
      budget ??
          EffectiveCanonTokenBudget.forResponder(
            contextSize: contextSize,
            outputTokens: maxTokens,
            reservedPromptTokens: reservedPromptTokens,
            presentEntityCount: _presentEntityCount(input.projection),
          ),
      availableTokens: contextSize - maxTokens - reservedPromptTokens,
    );
    final selection = SelectiveLedgerProjectionFilter.select(input);
    final projection = selection.projection;
    final packed = EffectiveCanonTokenPacker.pack(
      projection,
      budget: resolvedBudget,
      latestUserText: latestUserText,
      latestAssistantText: latestAssistantText,
      focalUserName: input.focalUserName,
      tokenCounter: tokenCounter,
      tokenizerMode: tokenizerMode,
    );
    final diagnostics = packed.diagnostics;
    return EffectiveCanonPromptMaterialization(
      filteredProjection: projection,
      characterKnowledgeContent: packed.characterKnowledge,
      studioSessionStateContent: packed.sessionState,
      // This is the packer's structured, token-accounted arc channel. Never
      // substitute the old pre-rendered buildArcContent blob here.
      arcContent: packed.arcContent,
      transitionContent: null,
      diagnostics: selection.diagnostics,
      packingDiagnostics: diagnostics,
      injectionCacheIdentity: _identity(
        input,
        selection.selectiveProjection,
        diagnostics,
      ),
    );
  }

  /// Materializes with the asymmetric failure contract used by generation:
  /// explicit opt-out stays empty, hard-ceiling failures remain explicit, and
  /// unexpected failures return a bounded empty projection.
  static EffectiveCanonPromptMaterialization materializeSafely(
    SelectiveLedgerProjectionInput input, {
    required String sessionId,
    String latestUserText = '',
    String latestAssistantText = '',
    int contextSize = 32000,
    int maxTokens = 8000,
    int reservedPromptTokens = 0,
    EffectiveCanonTokenBudget? budget,
    CanonTokenCounter tokenCounter = estimateTokens,
    String? tokenizerMode,
  }) {
    final safeInput = _generationSafeInput(input);
    final resolvedBudget = _boundedBudget(
      budget ??
          EffectiveCanonTokenBudget.forResponder(
            contextSize: contextSize,
            outputTokens: maxTokens,
            reservedPromptTokens: reservedPromptTokens,
            presentEntityCount: _presentEntityCount(safeInput.projection),
          ),
      availableTokens: contextSize - maxTokens - reservedPromptTokens,
    );
    if (safeInput.policy.effectiveMode == LedgerPromptInjectionMode.disabled) {
      return _emptyMaterialization(
        safeInput,
        budget: resolvedBudget,
        tokenizerMode: tokenizerMode,
      );
    }
    try {
      return materialize(
        safeInput,
        sessionId: sessionId,
        latestUserText: latestUserText,
        latestAssistantText: latestAssistantText,
        contextSize: contextSize,
        maxTokens: maxTokens,
        reservedPromptTokens: reservedPromptTokens,
        budget: resolvedBudget,
        tokenCounter: tokenCounter,
        tokenizerMode: tokenizerMode,
      );
    } on EffectiveCanonBudgetExceeded {
      rethrow;
    } catch (_) {
      // Never restore the old unbounded formatter here. An unexpected packing
      // failure is safer as an explicit bounded empty projection than as a
      // request that can silently consume the responder's whole context.
      return _emptyMaterialization(
        safeInput,
        budget: resolvedBudget,
        tokenizerMode: tokenizerMode,
        identitySuffix: 'bounded-fallback',
      );
    }
  }
}

EffectiveCanonTokenBudget _boundedBudget(
  EffectiveCanonTokenBudget requested, {
  required int availableTokens,
}) {
  final available = availableTokens.clamp(0, 1 << 30);
  final hard = requested.hardCeilingTokens.clamp(0, available);
  final nominal = requested.nominalTokens.clamp(0, hard);
  return EffectiveCanonTokenBudget(
    nominalTokens: nominal,
    hardCeilingTokens: hard,
    mandatoryReserveTokens: requested.mandatoryReserveTokens.clamp(0, nominal),
  );
}

EffectiveCanonPromptMaterialization _emptyMaterialization(
  SelectiveLedgerProjectionInput input, {
  required EffectiveCanonTokenBudget budget,
  required String? tokenizerMode,
  String identitySuffix = 'disabled',
}) {
  final source = input.projection;
  final empty = EffectiveCanonPromptProjection(
    facts: const [],
    trackers: const [],
    unblockedTransitionClaims: const [],
    transitions: const [],
    revisionNumber: source.revisionNumber,
    revisionHash: source.revisionHash,
    cacheIdentity: source.cacheIdentity,
  );
  return EffectiveCanonPromptMaterialization(
    filteredProjection: empty,
    characterKnowledgeContent: null,
    studioSessionStateContent: null,
    arcContent: null,
    transitionContent: null,
    diagnostics: const [],
    packingDiagnostics: EffectiveCanonPackingDiagnostics(
      nominalTokens: budget.nominalTokens,
      hardCeilingTokens: budget.hardCeilingTokens,
      mandatoryReserveTokens: budget.mandatoryReserveTokens,
      usedTokens: 0,
      channelTokens: const {},
      presentEntityCount: 0,
      spotlightEntityIds: const [],
      decisions: const [],
      requiredOverflowTokens: 0,
      tokenizerMode: tokenizerMode ?? (o200kBaseLoaded ? 'o200k' : 'fallback'),
      selectionIdentity: identitySuffix,
    ),
    injectionCacheIdentity: '${input.policy.identity}/$identitySuffix',
  );
}

int _presentEntityCount(EffectiveCanonPromptProjection projection) => projection
    .trackers
    .where((tracker) => tracker.name == 'scene.present_entities')
    .expand((tracker) => tracker.value.split(RegExp(r'[,;\n]+')))
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .length;

SelectiveLedgerProjectionInput _generationSafeInput(
  SelectiveLedgerProjectionInput input,
) {
  final safeFacts = input.projection.facts
      .where(isSelectableLedgerFact)
      .toList(growable: false);
  if (safeFacts.length == input.projection.facts.length) return input;
  final source = input.projection;
  return SelectiveLedgerProjectionInput(
    policy: input.policy,
    consumerPath: input.consumerPath,
    projection: EffectiveCanonPromptProjection(
      facts: safeFacts,
      trackers: source.trackers,
      unblockedTransitionClaims: source.unblockedTransitionClaims,
      transitions: source.transitions,
      revisionNumber: source.revisionNumber,
      revisionHash: source.revisionHash,
      cacheIdentity: source.cacheIdentity,
    ),
    visibleMessages: input.visibleMessages,
    selectedSwipeByMessageId: input.selectedSwipeByMessageId,
    focalUserName: input.focalUserName,
    structuredContinuitySourceIds: input.structuredContinuitySourceIds,
    freshness: input.freshness,
  );
}

String _identity(
  SelectiveLedgerProjectionInput input,
  EffectiveCanonPromptProjection selected,
  EffectiveCanonPackingDiagnostics packing,
) {
  final visible = input.visibleMessages
      .where(
        (message) =>
            (message.role == 'user' || message.role == 'assistant') &&
            !message.isHidden &&
            !message.isTyping,
      )
      .map(
        (message) => {
          'id': message.id,
          'contentHash': _hash(message.content),
          'swipe':
              input.selectedSwipeByMessageId[message.id] ?? message.swipeId,
        },
      )
      .toList(growable: false);
  final trackers =
      selected.trackers
          .map(
            (item) => jsonEncode({
              'name': item.name,
              'value': item.value,
              'scope': item.scope,
              'provenance': item.provenance,
              'basisRevisionNumber': item.basisRevisionNumber,
              'basisRevisionHash': item.basisRevisionHash,
            }),
          )
          .toList()
        ..sort();
  final facts =
      selected.facts
          .map(
            (item) => jsonEncode({
              'id': item.id,
              'scopeKey': item.scopeKey,
              'predicate': item.predicate,
              'object': item.object,
              'lifecycle': item.lifecycle.wireName,
              'epistemicState': item.epistemicState.wireName,
              'sourceMessageId': item.sourceMessageId,
              'sourceSwipeId': item.sourceSwipeId,
              'sourceAgentSwipeId': item.sourceAgentSwipeId,
            }),
          )
          .toList()
        ..sort();
  final transitions =
      selected.transitions
          .map(
            (item) => jsonEncode({
              'id': item.id,
              'scope': item.semanticScopeKey,
              'keys': [...item.affectedTrackerKeys]..sort(),
              'claim': item.claim,
            }),
          )
          .toList()
        ..sort();
  final continuity = input.structuredContinuitySourceIds.toList()..sort();
  return _hash(
    jsonEncode({
      'effectiveCanon': selected.cacheIdentity,
      'policy': input.policy.toJson(),
      'consumerPath': input.consumerPath,
      'freshness': input.freshness.name,
      'visible': visible,
      'continuitySourceIds': continuity,
      'facts': facts,
      'trackers': trackers,
      'transitions': transitions,
      'packing': {
        'nominalTokens': packing.nominalTokens,
        'hardCeilingTokens': packing.hardCeilingTokens,
        'mandatoryReserveTokens': packing.mandatoryReserveTokens,
        'tokenizerMode': packing.tokenizerMode,
        'selectionIdentity': packing.selectionIdentity,
        'selectedItemIds': [
          for (final decision in packing.decisions)
            if (decision.reason == CanonPackingReason.selected) decision.itemId,
        ],
      },
    }),
  );
}

String _hash(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();
