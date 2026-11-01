part of '../support_source_text_repo.dart';

String _applicationKey(String key) =>
    key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

bool _applicationPrivateKey(String key) {
  final k = _applicationKey(key);
  return SecretRedactor.isSecretField(key) ||
      const {
        'key',
        'apikey',
        'embeddingapikey',
        'authorization',
        'authentication',
        'auth',
        'bearer',
        'token',
        'accesstoken',
        'refreshtoken',
        'password',
        'passwd',
        'secret',
        'secrets',
        'credential',
        'credentials',
        'vault',
        'headers',
        'header',
        'customheaders',
        'requestheaders',
        'cookie',
        'cookies',
        'session',
        'messageids',
        'evidencemessageids',
        'anchors',
        'acceptedmanifestrefs',
        'sourceentryids',
        'entityids',
        'retrievalkeys',
        'retrievalkeysjson',
        'provenance',
        'protectedfacts',
        'receipts',
        'cas',
        'authority',
        'owner',
        'nonce',
        'signature',
        'privatekey',
        'publickey',
        'encryptionkey',
      }.contains(k) ||
      k.endsWith('id') ||
      k.endsWith('ids') ||
      k.contains('ciphertext') ||
      k.contains('hash') ||
      k.contains('stamp') ||
      k.contains('receipt') ||
      k.contains('credential') ||
      k.contains('password') ||
      k.contains('secret') ||
      k.contains('authorization') ||
      k.contains('apikey') ||
      k.contains('header') ||
      k.contains('vault') ||
      k.endsWith('accesstoken') ||
      k.contains('owner');
}

// Known logical fields, not an arbitrary JSON/column dump. Unknown schema is
// omitted visibly. Authored variable/map names are handled in the narrow map
// mode and become VALUES in _fields, never attested structured keys.
const _applicationJsonFields = {
  'name',
  'title',
  'label',
  'description',
  'personality',
  'scenario',
  'firstMes',
  'mesExample',
  'systemPrompt',
  'postHistoryInstructions',
  'creator',
  'creatorNotes',
  'characterVersion',
  'alternateGreetings',
  'tags',
  'extensions',
  'depth_prompt',
  'depth',
  'prompt',
  'world',
  'content',
  'text',
  'role',
  'timestamp',
  'reasoning',
  'swipes',
  'swipesMeta',
  'agentSwipes',
  'kind',
  'isHidden',
  'isError',
  'isLocked',
  'isAllReasoning',
  'isTyping',
  'isEditing',
  'tokens',
  'genTime',
  'tokenCount',
  'reasoningTokens',
  'type',
  'format',
  'mimeType',
  'imagePath',
  'imageHidden',
  'personaName',
  'guidanceText',
  'guidanceType',
  'studioOutputs',
  'time',
  'extraImagePaths',
  'path',
  'caption',
  'gallery',
  'fileName',
  'size',
  'width',
  'height',
  'enabled',
  'position',
  'order',
  'priority',
  'constant',
  'selective',
  'keys',
  'secondaryKeys',
  'matchWholeWords',
  'sticky',
  'cooldown',
  'delay',
  'group',
  'groupProminence',
  'characterFilter',
  'names',
  'isExclude',
  'ignoreBudget',
  'vectorSearch',
  'useKeywordSearch',
  'useGroupScoring',
  'lorebookName',
  'excludeFromVectorization',
  'maxInjectedEntries',
  'contextPercent',
  'budgetCap',
  'reserveMode',
  'reserveValue',
  'minActivations',
  'maxDepth',
  'maxRecursionSteps',
  'insertionStrategy',
  'injectionPosition',
  'includeNames',
  'recursiveScan',
  'alertOnOverflow',
  'searchType',
  'embeddingTarget',
  'vectorizeAllEntries',
  'vectorThreshold',
  'vectorTopK',
  'keywordVectorSplit',
  'vectorScanDepth',
  'vectorSearchEnabled',
  'keySearchEnabled',
  'value',
  'comment',
  'caseSensitive',
  'useRegex',
  'selectiveLogic',
  'insertionOrder',
  'probability',
  'useProbability',
  'excludeRecursion',
  'preventRecursion',
  'delayUntilRecursion',
  'scanDepth',
  'tokenBudget',
  'recursiveScanning',
  'entries',
  'settings',
  'before',
  'after',
  'replacement',
  'findRegex',
  'replaceString',
  'regex',
  'scripts',
  'script',
  'staticContent',
  'template',
  'render',
  'panelMinHeight',
  'apiModel',
  'inject',
  'injectLastN',
  'injectPrefix',
  'streamToPanel',
  'contextMessageCount',
  'contextSystemPrompt',
  'contextPolicy',
  'previousBlocksCount',
  'manualOnly',
  'triggerOnUser',
  'triggerOnChar',
  'triggerOnSwipe',
  'generationPause',
  'period',
  'keyword',
  'blocks',
  'trigger',
  'dependsOnPrevious',
  'executionMode',
  'periodicIntervalSeconds',
  'config',
  'model',
  'protocol',
  'protocolEndpoint',
  'stream',
  'maxTokens',
  'temperature',
  'topP',
  'topK',
  'frequencyPenalty',
  'presencePenalty',
  'requestReasoning',
  'useResponsesApi',
  'omitReasoning',
  'reasoningEffort',
  'showNativeReasoning',
  'cacheControlTtl',
  'cacheBreakpointMode',
  'sessionIdMode',
  'messageCount',
  'messages',
  'toolCount',
  'toolChoice',
  'seq',
  'ts',
  'context',
  'truncated',
  'stage',
  'stageOrdinal',
  'attempt',
  'status',
  'statusCode',
  'error',
  'code',
  'detail',
  'parserCode',
  'parserDetail',
  'elapsedMs',
  'durationMs',
  'input',
  'output',
  'request',
  'response',
  'result',
  'operations',
  'operation',
  'op',
  'targetKind',
  'cardFieldPath',
  'field',
  'fieldPath',
  'oldValue',
  'newValue',
  'currentValue',
  'proposedValue',
  'reason',
  'rationale',
  'evidence',
  'evidenceText',
  'canonicalClaim',
  'observedChange',
  'semanticScopeKey',
  'scope',
  'confidence',
  'importance',
  'decision',
  'validationStatus',
  'statusReason',
  'selectedInput',
  'writerOptions',
  'card',
  'baselineCard',
  'snapshot',
  'lorebook',
  'lorebooks',
  'baseContent',
  'previousContent',
  'acceptedAt',
  'createdAt',
  'updatedAt',
  'revision',
  'sequence',
  'manifestSchemaVersion',
  'entryOrder',
  'sourceKind',
  'sourceType',
  'source',
  'summary',
  'note',
  'noteType',
  'attempts',
  'rejectedOps',
  'parseFailure',
  'repairFailure',
  'repairAttempted',
  'failureCode',
  'failureDetail',
  'target',
  'destination',
  'injectionPoint',
  'apiConfig',
  'authorNote',
  'authorsNote',
  'sessionName',
  'textBefore',
  'textAfter',
  'frequency',
  'retrievalHints',
  'hints',
  'topics',
  'entities',
  'locations',
  'abstractText',
  'parts',
  'contents',
  'systemInstruction',
  'system',
  'inputText',
  'outputText',
};

final class _ApplicationProjection {
  _ApplicationProjection(this.repo);
  final SupportSourceNavigationRepo repo;
  bool omitted = false;
  int _nodes = 0, _rawBytes = 0;

  void _node(int depth) {
    if (++_nodes > 8192 || depth > 24) {
      throw const FormatException('Unsupported saved unit');
    }
  }

  void _raw(String raw) {
    _rawBytes += utf8.encode(raw).length;
    if (_rawBytes > 65536) {
      throw const FormatException('Unsupported saved unit');
    }
  }

  Object? _decodeUnit(String raw, int depth) {
    _raw(raw);
    final decoded = SupportSourceJson.decode(raw, maxBytes: 65536);
    // Charge the COMPLETE parsed tree, including denied subtrees, to the same
    // unit budget. Embedded decodes cannot restart depth/node/raw allowances.
    void visit(Object? value, int level) {
      _node(level);
      if (value is Map<String, Object?>) {
        for (final e in value.entries) {
          visit(e.key, level + 1);
          visit(e.value, level + 1);
        }
      } else if (value is List<Object?>) {
        for (final item in value) {
          visit(item, level + 1);
        }
      }
    }

    visit(decoded, depth);
    return decoded;
  }

  Object? jsonColumn(String raw, String field) {
    final decoded = _decodeUnit(raw, 0);
    const arrays = {
      'tags_json',
      'alternate_greetings_json',
      'gallery_json',
      'entries_json',
      'rejected_ops_json',
      'attempts_json',
      'evidence_clusters_json',
      'operation_snapshot_json',
      'extra_request_parameters_json',
    };
    if (arrays.contains(field)
        ? decoded is! List<Object?>
        : decoded is! Map<String, Object?>) {
      throw const FormatException('Unsupported saved unit');
    }
    return field == 'extra_request_parameters_json'
        ? customParameters(decoded)
        : sanitize(decoded, authoredMap: field == 'session_vars_json');
  }

  String text(String raw, {int depth = 0, bool authoredMap = false}) {
    final trimmed = raw.trimLeft();
    if (trimmed.startsWith('{') ||
        trimmed.startsWith('[') ||
        trimmed.startsWith('"')) {
      final decoded = _decodeUnit(raw, depth + 1);
      return jsonEncode(
        sanitize(decoded, authoredMap: authoredMap, depth: depth + 1),
      );
    }
    _raw(raw);
    return repo._projectComplete(raw);
  }

  Object? sanitize(
    Object? value, {
    bool authoredMap = false,
    String parent = '',
    int depth = 0,
  }) {
    _node(depth);
    if (value is String) {
      return text(value, depth: depth, authoredMap: authoredMap);
    }
    if (value == null || value is bool || value is num) return value;
    if (value is List<Object?>) {
      if (value.length > 512)
        throw const FormatException('Unsupported saved unit');
      return [
        for (final v in value)
          sanitize(
            v,
            authoredMap: authoredMap,
            parent: parent,
            depth: depth + 1,
          ),
      ];
    }
    if (value is! Map<String, Object?>)
      throw const FormatException('Unsupported saved unit');
    // Key/value custom containers are one redaction unit. Never keep the value
    // after discarding a secret-looking discriminator, including disabled ones.
    final discriminators = <String, Object?>{};
    for (final entry in value.entries) {
      final key = _applicationKey(entry.key);
      if (!const {'key', 'name', 'value'}.contains(key)) continue;
      if (discriminators.containsKey(key)) {
        // A normalized alias cannot choose a different credential discriminator
        // after another alias has been filtered out.
        omitted = true;
        return const <String, Object?>{};
      }
      discriminators[key] = entry.value;
    }
    final hasValue = discriminators.containsKey('value');
    final discriminator = discriminators.containsKey('key')
        ? discriminators['key']
        : hasValue
        ? discriminators['name']
        : null;
    if ((discriminators.containsKey('key') && hasValue) ||
        (hasValue &&
            discriminators.containsKey('name') &&
            discriminator is! String) ||
        (discriminator is String && _applicationPrivateKey(discriminator)) ||
        (hasValue && value.keys.any(_applicationPrivateKey))) {
      omitted = true;
      return const <String, Object?>{};
    }
    final result = <String, Object?>{};
    for (final e in value.entries) {
      // Do not inspect or stringify a denied value, including entire headers.
      if (_applicationPrivateKey(e.key)) {
        omitted = true;
        continue;
      }
      if (!authoredMap && !_applicationJsonFields.contains(e.key)) {
        omitted = true;
        continue;
      }
      final safeKey = repo._projectComplete(e.key);
      if (safeKey != e.key) {
        omitted = true;
        continue;
      }
      result[e.key] = sanitize(
        e.value,
        authoredMap:
            authoredMap ||
            const {'variables', 'characterVars', 'chatVars'}.contains(e.key),
        parent: e.key,
        depth: depth + 1,
      );
    }
    return result;
  }

  Object customParameters(Object? value) {
    if (value is! List<Object?> || value.length > 512) {
      omitted = true;
      return const [];
    }
    const allowed = {
      'temperature',
      'top_p',
      'top_k',
      'frequency_penalty',
      'presence_penalty',
      'min_p',
      'typical_p',
      'repetition_penalty',
      'seed',
      'max_tokens',
      'max_output_tokens',
    };
    final result = <Object?>[];
    for (final item in value) {
      if (item is! Map<String, Object?> ||
          !allowed.contains(item['key']) ||
          item['value'] is! String ||
          item['enabled'] is! bool) {
        omitted = true;
        continue;
      }
      final number = num.tryParse(item['value'] as String);
      if (number == null || !number.isFinite) {
        omitted = true;
        continue;
      }
      result.add({
        'parameter': item['key'],
        'value': number,
        'enabled': item['enabled'],
      });
    }
    return result;
  }
}
