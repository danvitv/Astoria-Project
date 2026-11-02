part of 'support_native_global_regex_adapter.dart';

extension _GlobalRegexDiscovery on SupportNativeGlobalRegexAdapter {
  SupportAppPreparedAction? _scripts(SupportAppActionContext context) {
    final original = port;
    if (original == null || !original.current) return null;
    // ONLY the ordinary owner's retained loaded facts. observe(id) would read
    // private raw JSON and a saved-key lease, neither needed for discovery.
    final loaded = original.loaded();
    if (loaded == null) return null;
    final revision = original.revision();
    final count = loaded.length;
    final scripts = loaded.take(32).toList(growable: false);
    bool current() {
      if (!_current ||
          !context.current ||
          !original.current ||
          original.revision() != revision) return false;
      final latest = original.loaded();
      return latest != null &&
          latest.length == count &&
          Iterable<int>.generate(scripts.length).every(
            (i) => identical(latest[i], scripts[i]),
          );
    }

    if (!current()) return null;
    return SupportAppPreparedAction(
      target: 'native-loaded-global-regex-metadata',
      observation: Object(),
      observationIsCurrent: current,
      execute: (admitted) async {
        if (!admitted() || !current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        final records = <Map<String, Object?>>[];
        var omitted = 0, omittedNames = 0;
        const idField = SupportAppActionField.text(
          128,
          pattern: r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
        );
        for (final script in scripts) {
          final id = script.id;
          if (!idField.accepts(id) || !_safeDiscoveryText(id, 128)) {
            omitted++;
            continue;
          }
          final nameSafe = _safeDiscoveryText(script.name, 256);
          if (!nameSafe) omittedNames++;
          records.add({
            'id': id,
            if (nameSafe) 'name': script.name,
            'disabled': script.disabled,
          });
        }
        if (!admitted() || !current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        return SupportAppActionOutcome(
          SupportAppActionCode.completed,
          data: {
            'regexDomain': 'global',
            'records': records,
            'count': count,
            'inspectedCount': scripts.length,
            'returnedCount': records.length,
            'omittedCount': omitted,
            'omittedNameCount': omittedNames,
            'unlistedCount': count - scripts.length,
            'truncated': count > scripts.length,
            'visibility': 'originalLoadedOwnerOnly',
            'bodyAccess': 'notGranted',
          },
        );
      },
    );
  }

  bool _safeDiscoveryText(String value, int maxLength) {
    try {
      // Compare the WHOLE field under the current exact redactor. A partial
      // redaction, clipping, policy failure or reentry never becomes an ID/name.
      return metadata.exactText(value, maxLength: maxLength) == value;
    } catch (_) {
      return false;
    }
  }
}
