part of '../support_source_text_repo.dart';

String _selectionKey(nav.Selection s) => jsonEncode(_selectionMaterial(s));
Object _selectionMaterial(nav.Selection s) => [
  s.kind.name,
  s.sectionId,
  s.recordId,
  if (s.range != null)
    [
      s.range!.start.messageId,
      s.range!.start.ordinal,
      s.range!.start.swipe,
      s.range!.start.agentSwipe,
      s.range!.end.messageId,
      s.range!.end.ordinal,
      s.range!.end.swipe,
      s.range!.end.agentSwipe,
    ],
];
Object _bindingMaterial(nav.Binding b) => [
  b.sessionId,
  b.characterId,
  b.knowerId,
  b.subjectId,
  b.evidence.state.name,
  if (b.savedAnchor case final saved?) [saved.messageId, saved.swipe, saved.agentSwipe],
  if (b.anchor != null)
    [
      b.anchor!.messageId,
      b.anchor!.ordinal,
      b.anchor!.swipe,
      b.anchor!.agentSwipe,
    ],
  if (b.evidence.range != null)
    _selectionMaterial(nav.Selection.messages('evidence', b.evidence.range)),
];

bool _scopeWithin(nav.FrozenScope original, nav.FrozenScope supplied) =>
    original.messages != null
    ? supplied.messages != null &&
          supplied.sections.isEmpty &&
          original.messages!.contains(supplied.messages!)
    : supplied.messages == null &&
          supplied.sections.isNotEmpty &&
          supplied.sections.every(original.sections.contains);

/// Only declared schema fields. Missing optional fields remain missing, not
/// defaults. Lists and authored map keys are converted to finite value records.
final class _NavShape {
  _NavShape(this.repo);
  final SupportSourceNavigationRepo repo;
  Never bad() => repo._fail(SupportSourceReadFailure.unsupportedFormat);
  Map<String, Object?> map(Object? v) {
    if (v is! Map<String, Object?>) bad();
    return v;
  }

  List<Object?> list(Object? v) {
    if (v is! List<Object?> || v.length > 512) bad();
    return v;
  }

  String id(Object? v, {bool empty = false}) {
    if (empty && v == '') return '';
    if (!SupportSourceJson.identity(v) || utf8.encode(v as String).length > 256)
      bad();
    return v;
  }

  void fields(
    Map<String, Object?> m, {
    Set<String> strings = const {},
    Set<String> bools = const {},
    Set<String> ints = const {},
    Set<String> nums = const {},
    Set<String> nullable = const {},
    Set<String> nested = const {},
    Set<String> required = const {},
  }) {
    if (!required.every(m.containsKey)) bad();
    for (final e in m.entries) {
      final v = e.value, k = e.key;
      if (nullable.contains(k) && v == null) continue;
      if ((strings.contains(k) && v is String) ||
          (bools.contains(k) && v is bool) ||
          (ints.contains(k) && v is int && v.abs() <= 8640000000000000) ||
          (nums.contains(k) && v is num && v.isFinite) ||
          nested.contains(k))
        continue;
      bad();
    }
  }

  void choice(Map<String, Object?> m, String k, Set<String> allowed) {
    if (m.containsKey(k) && m[k] != null && !allowed.contains(m[k])) bad();
  }

  void strings(Object? v, {bool identities = false}) {
    for (final item in list(v)) {
      if (item is! String) bad();
      if (identities) id(item);
    }
  }
}

extension _NavShapes on SupportSourceNavigationRepo {
  _NavShape get _shape => _NavShape(this);
  Object? _decode(Object? raw) {
    if (raw is! String) _fail(SupportSourceReadFailure.unsupportedFormat);
    return SupportSourceJson.decode(raw, maxBytes: nav.Limits.rawBytes);
  }

  /// Candidate prefilter ONLY after complete authored-string redaction. Host
  /// projects again and attests the actual nested wire before provenance. The
  /// original policy identity is fenced for this repository's entire lifetime.
  bool _visibleMatch(String raw, String literal) =>
      _projectComplete(raw).contains(literal);

  String _projectComplete(String raw) {
    _guard();
    final policy = _projectionPolicy!;
    final safe = policy
        .withKnownSecrets(
          const [],
          maxInputLength: max(policy.maxInputLength, nav.Limits.rawBytes),
          maxOutputLength: nav.Limits.rawBytes,
        )
        .redactText(raw);
    if (safe.contains(SecretRedactor.limited) ||
        safe.length > nav.Limits.rawBytes) {
      _fail(SupportSourceReadFailure.tooLarge);
    }
    _guard();
    return safe;
  }

  bool _allowed(
    _NavSource source,
    nav.FrozenScope scope,
    nav.Selection selected,
  ) {
    if (source.scope == null ||
        !_scopeWithin(source.scope!, scope) ||
        scope.excludedRecords.contains(selected.recordId) ||
        (selected.range != null &&
            scope.excludedRecords.any(
              (id) =>
                  id == selected.range!.start.messageId ||
                  id == selected.range!.end.messageId,
            )))
      return false;
    return scope.messages != null
        ? selected.range != null && scope.messages!.contains(selected.range!)
        : scope.sections.contains(selected.sectionId);
  }

  void _keep(
    _NavSource source,
    nav.DataRecord record,
    Object raw,
    Iterable<String> ids,
  ) {
    final key = _selectionKey(record.selection);
    final previous = source.captures[key];
    if (previous != null &&
        !(previous.record?.payload == null && record.payload != null))
      return;
    final encoded = jsonEncode(raw);
    final digest = sha256.convert(utf8.encode(encoded)).toString();
    final cacheKey = '${source.observation.snapshot.incarnation}:$digest';
    var capture = _captures[cacheKey];
    if (capture == null) {
      final bytes = utf8.encode(encoded).length;
      if (_captureBytes + bytes > nav.Limits.retainedBytes ||
          _captures.length >= 128)
        _fail(SupportSourceReadFailure.tooLarge);
      _captureBytes += bytes;
      capture = _NavCapture(raw, List.unmodifiable(ids), null);
      _captures[cacheKey] = capture;
    }
    if (previous == null && source.captures.length >= 128)
      _fail(SupportSourceReadFailure.tooLarge);
    source.captures[key] = _NavCapture(
      capture.raw,
      List.unmodifiable(ids),
      record,
    );
  }

  nav.DataRecord _unit(
    _NavSource source,
    String section,
    String recordId,
    nav.SectionKind kind,
    Object? value, {
    nav.SourceState? state,
    nav.Binding? binding,
    String? role,
  }) => nav.DataRecord(
    selection: nav.Selection.record(section, recordId),
    kind: kind,
    payload: value,
    state: state ?? source.observation.state,
    binding: binding ?? source.observation.binding,
    role: role,
    schemaKeysAttested: true,
  );

  /// Complete authored scalar strings have their own selectors. Numeric/boolean
  /// settings retain finite typed shape; native identity/hash fields are private.
  List<nav.DataRecord> _fields(
    _NavSource source,
    String section,
    String prefix,
    nav.SectionKind kind,
    Map<String, Object?> values, {
    Set<String> private = const {},
    nav.SourceState? state,
    nav.Binding? binding,
  }) {
    final units = <nav.DataRecord>[];
    final settings = <String, Object?>{};
    var n = 0;
    void visit(Object? value, String path, String key) {
      if (private.contains(key)) return;
      if (value is String) {
        units.add(
          _unit(
            source,
            section,
            '$prefix:${n++}',
            kind,
            value,
            state: state,
            binding: binding,
            role:
                key == 'content' &&
                    const {
                      'system',
                      'assistant',
                      'user',
                      'tool',
                    }.contains(values['role'])
                ? values['role'] as String
                : null,
          ),
        );
      } else if (value is Map<String, Object?>) {
        // Authored map keys (memory keyParagraphs etc.) are VALUES, not keys
        // in model-visible structured schema. Do not dump a serialized object.
        var index = 0;
        final identityMap = const {
          'agentEnabled',
          'agentEnabledBeforeDependencyOff',
          'agentBlockRestoreState',
          'controllerAlternativeBlockIds',
        }.contains(key);
        for (final e in value.entries) {
          // Suppress the real private name AND its entire value subtree before
          // converting either to authored units or fixed ordinal output paths.
          if (private.contains(e.key)) continue;
          // Nested map keys are never attested merely because their parent is.
          // Use fixed ordinal paths, and project authored key text as a VALUE.
          final field = 'item${index++}';
          if (!identityMap) visit(e.key, '$path.$field.key', 'key');
          visit(e.value, '$path.$field', e.key);
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) visit(value[i], '$path.$i', key);
      } else {
        settings[path] = value;
      }
    }

    for (final e in values.entries) visit(e.value, e.key, e.key);
    if (settings.isNotEmpty) {
      // Long/larger schemas remain separate finite field records, not JSON chunks.
      for (final e in settings.entries) {
        units.add(
          _unit(
            source,
            section,
            '$prefix:${n++}',
            kind,
            {'field': e.key, 'value': e.value},
            state: state,
            binding: binding,
          ),
        );
      }
    }
    // Preserve associated saved flag names as finite typed records as well as
    // searchable authored field units. These are logical fixed-schema settings
    // groups, never fragments of a serialized block or source definition.
    final typed = <String, Object?>{};
    const enumFields = {
      'role',
      'status',
      'type',
      'kind',
      'insertionMode',
      'mode',
      'section',
      'injectionPoint',
      'contextSlot',
      'prefillStyle',
      'groupBoundary',
      'reasoningMode',
      'execution_mode',
      'memoryMode',
      'memoryPackingMode',
      'memoryBudgetPreset',
      'injectionTarget',
      'keyMatchMode',
      'scope',
      'fact_class',
      'epistemic_state',
      'lifecycle',
      'eventState',
      'op',
    };
    for (final e in values.entries) {
      if (private.contains(e.key)) continue;
      if (e.value is bool ||
          e.value is num ||
          (e.value is String && enumFields.contains(e.key)))
        typed[e.key] = e.value;
    }
    final entries = typed.entries.toList();
    for (var i = 0; i < entries.length; i += 16) {
      units.add(
        _unit(
          source,
          section,
          '$prefix:flags:$i',
          kind,
          {for (final e in entries.skip(i).take(16)) e.key: e.value},
          state: state,
          binding: binding,
        ),
      );
    }
    return units;
  }
}
