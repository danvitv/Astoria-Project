part of '../support_source_text_repo.dart';

final class _PreferencesCursor {
  const _PreferencesCursor(
    this.source,
    this.scope,
    this.operation,
    this.section,
    this.literal,
    this.offset,
  );
  final _NavSource source;
  final nav.FrozenScope scope;
  final String operation;
  final nav.Selection? section;
  final String? literal;
  final int offset;
}

extension _NavPreferences on SupportSourceNavigationRepo {
  int _preferenceReference(String kind, String id) {
    final private = '$kind:$id';
    final existing = _preferenceReferences[private];
    if (existing != null) return existing;
    if (_preferenceReferences.length >= nav.Limits.candidates) {
      _fail(SupportSourceReadFailure.tooLarge);
    }
    return _preferenceReferences[private] = _preferenceReferences.length + 1;
  }

  Future<_NavSource> _newPreferencesSource(
    nav.SourceKey key,
    String label,
  ) async {
    final family = key.nativeId;
    final port = _preferences;
    final lease = _preferenceLeases[family];
    if (port == null || lease == null) {
      // No original producer: unavailable is not a notifier's default values.
      _preferenceValues[family] = {
        'availability': 'unavailable_original_preferences_port',
      };
      return _newApplicationSource(
        key,
        {'dataset': family, 'savedPreferences': 'unavailable'},
        label,
        ['availability'],
      );
    }
    if (!port.isCurrent(lease)) _fail(SupportSourceReadFailure.changed);
    _observedPreferenceFamilies.add(family); // Before any await, never rebind.
    final raw = await port.read(family, lease);
    _guard();
    final values = <String, Object?>{};
    for (final e in raw.entries) {
      // One complete persisted preference is one structural projection unit.
      // The same budget also charges embedded JSON strings, including denied
      // subtrees. No raw search, clipping, script execution or header dump.
      final projection = _ApplicationProjection(this);
      final codec = SavedPreferencesCodec(
        decode: (v) => projection._decodeUnit(v, 0),
        text: projection.text,
        parameters: projection.customParameters,
        authoredMap: (v) => projection.sanitize(v, authoredMap: true),
        reference: _preferenceReference,
      );
      values[e.key] = codec.project(e.key, e.value);
    }
    _guard();
    _preferenceValues[family] = Map.unmodifiable(values);
    return _newApplicationSource(
      key,
      {
        'dataset': family,
        'savedPreferences': 'original_process_store_finite_writers',
        // Private header participates in frozen observation/catalog/body digest;
        // it is never copied to model metadata or selector grammar.
        'preferencesOwner': lease.privateMaterial,
      },
      label,
      values.keys,
    );
  }

  List<nav.DataRecord> _preferencesRecords(
    _NavSource source,
    nav.FrozenScope scope,
  ) {
    final values = _preferenceValues[source.observation.key.nativeId];
    if (values == null) _fail();
    final result = <nav.DataRecord>[];
    var ordinal = 0;
    void emit(Object? value, String section, String label) {
      result.add(
        nav.DataRecord(
          selection: nav.Selection.record(section, '$section:${ordinal++}'),
          kind: nav.SectionKind.applicationRecord,
          state: source.observation.state,
          // Literal-search selectors and citation scalar offsets refer to text.
          // These values are already completely projected by the pinned codec;
          // represent finite typed fields as canonical JSON text consistently
          // for contents/search/read, never search or stringify raw preferences.
          payload: value is String ? value : jsonEncode(value),
          schemaKeysAttested: true,
          label: label.length <= 120 ? label : section,
        ),
      );
    }

    void flatten(Object? value, String section, String field) {
      if (value is Map<String, Object?>) {
        for (final e in value.entries) {
          // Missing/defaulted metadata is one bounded typed record, not dozens
          // of pretend saved defaults consuming the native selector budget.
          if (e.key == 'missingDefaultedFields') {
            final missing = e.value;
            if (missing is List<Object?> &&
                missing.length > nav.Limits.collection) {
              // Preserve every missing-field name in bounded records. A partial
              // pipeline can exceed the engine's per-collection limit; that is
              // metadata to page, not a reason to retire the entire source.
              for (
                var start = 0;
                start < missing.length;
                start += nav.Limits.collection
              ) {
                final proposedEnd = start + nav.Limits.collection;
                final end = proposedEnd < missing.length
                    ? proposedEnd
                    : missing.length;
                emit(
                  {
                    'field':
                        '$field.${e.key}.part${start ~/ nav.Limits.collection}',
                    'value': missing.sublist(start, end),
                  },
                  section,
                  '$field.${e.key}',
                );
              }
            } else {
              emit(
                {'field': '$field.${e.key}', 'value': missing},
                section,
                '$field.${e.key}',
              );
            }
          } else {
            flatten(e.value, section, '$field.${e.key}');
          }
        }
      } else if (value is List<Object?>) {
        if (value.isEmpty) {
          emit({'field': field, 'value': const <Object?>[]}, section, field);
        }
        for (var i = 0; i < value.length; i++) {
          flatten(value[i], section, '$field.item$i');
        }
      } else if (value is String) {
        emit(value, section, field);
      } else {
        emit({'field': field, 'value': value}, section, field);
      }
    }

    for (final e in values.entries) {
      if (!scope.sections.contains(e.key)) continue;
      flatten(e.value, e.key, e.key);
    }
    if (result.length > 4096) _fail(SupportSourceReadFailure.tooLarge);
    return result;
  }

  nav.Page<nav.SectionDescriptor> _preferencesContents(
    _NavSource source,
    nav.FrozenScope scope,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) {
    if (section != null) {
      return _applicationDescriptors(
        _preferencesPage(
          source,
          scope,
          'contents',
          section,
          null,
          cursor,
          bound,
        ),
      );
    }
    if (cursor != null) _fail();
    final result = <nav.SectionDescriptor>[];
    for (final key
        in _preferenceValues[source.observation.key.nativeId]!.keys) {
      if (!scope.sections.contains(key)) continue;
      final selection = nav.Selection.section(key);
      final record = nav.DataRecord(
        selection: selection,
        kind: nav.SectionKind.applicationRecord,
        state: source.observation.state,
        payload: null,
        label: 'Saved $key',
      );
      _keep(source, record, source.header, const []);
      result.add(
        nav.SectionDescriptor(
          selection,
          record.kind,
          state: record.state,
          label: record.label,
        ),
      );
    }
    return nav.Page(result);
  }

  nav.Page<nav.DataRecord> _preferencesPage(
    _NavSource source,
    nav.FrozenScope scope,
    String operation,
    nav.Selection? section,
    String? literal,
    Object? cursor,
    nav.WorkBound bound,
  ) {
    _guard();
    if (section != null &&
        (section.kind != nav.SelectionKind.section ||
            !_allowed(source, scope, section) ||
            !source.captures.containsKey(_selectionKey(section)))) {
      _fail();
    }
    var offset = 0;
    if (cursor != null) {
      if (cursor is! _PreferencesCursor ||
          !identical(cursor.source, source) ||
          !identical(cursor.scope, scope) ||
          cursor.operation != operation ||
          cursor.literal != literal ||
          (section == null
              ? cursor.section != null
              : cursor.section == null || !section.same(cursor.section!))) {
        _fail();
      }
      offset = cursor.offset;
    }
    final records = _preferencesRecords(source, scope);
    final result = <nav.DataRecord>[];
    var examined = 0, bytes = 0;
    while (offset < records.length &&
        examined < bound.candidateLimit &&
        result.length < bound.pageSize) {
      final record = records[offset];
      final size = _payloadBytes(record.payload);
      if (bytes + size > bound.rawByteLimit) break;
      offset++;
      examined++;
      if (section != null && section.sectionId != record.selection.sectionId) {
        continue;
      }
      final safe = record.payload is String
          ? record.payload as String
          : jsonEncode(record.payload);
      if (literal != null && !safe.contains(literal)) continue;
      _keep(
        source,
        record,
        _preferenceValues[source.observation.key.nativeId]!,
        ['${source.observation.key.nativeId}:${record.selection.recordId}'],
      );
      result.add(record);
      bytes += size;
    }
    _guard();
    final complete = offset >= records.length;
    return nav.Page(
      result,
      candidatesExamined: examined,
      complete: complete,
      exhaustedWork: !complete && result.length < bound.pageSize,
      next: complete
          ? null
          : _PreferencesCursor(
              source,
              scope,
              operation,
              section,
              literal,
              offset,
            ),
    );
  }
}
