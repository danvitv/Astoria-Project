import '../../models/studio_ledger_export.dart';
import '../../models/tracker.dart';

/// Rejects a narrow, observable copy-contamination pattern before any writes.
/// This is not a semantic romance classifier: it catches new long passages
/// copied from an absent, different NPC's relationship state without source
/// support. Shared scenes and already-owned state are deliberately unaffected.
abstract final class LedgerAttributionGuard {
  static const _windowWords = 12;
  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static const _relationshipFields = {
    'attitude_to_user',
    'relationship_to_user',
    'trust_to_user',
    'boundaries',
    'card_overrides',
  };

  static void validate({
    required List<LedgerOp> ops,
    required List<Tracker> priorTrackers,
    required String sourceText,
  }) {
    // Callers project assistant OOC only; never strip explicit user retcons.
    final source = _words(sourceText);
    final prior = {for (final tracker in priorTrackers) tracker.name: tracker};
    final owners = priorTrackers.where(
      (tracker) => _owner(tracker.name) != null,
    );
    for (final op in ops) {
      final target = _owner(op.key);
      if (op.op != 'set' || target == null) continue;
      final existing = _words(prior[op.key]?.value ?? '');
      final proposed = _words(op.value);
      for (final other in owners) {
        final owner = _owner(other.name)!;
        if (owner == target || _mentions(source, owner)) continue;
        final otherWords = _words(other.value).split(' ');
        for (var i = 0; i + _windowWords <= otherWords.length; i++) {
          final fragment = otherWords.sublist(i, i + _windowWords).join(' ');
          if (fragment.length < 60 ||
              !_contains(proposed, fragment) ||
              _contains(existing, fragment) ||
              _contains(source, fragment)) {
            continue;
          }
          throw LedgerAttributionConflict(op.key, other.name);
        }
      }
    }
  }

  static String? _owner(String key) {
    if (!key.startsWith('npc:')) return null;
    final dot = key.lastIndexOf('.');
    if (dot < 4 || !_relationshipFields.contains(key.substring(dot + 1))) {
      return null;
    }
    return key.substring(4, dot);
  }

  static String _words(String text) => _word
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0)!)
      .join(' ');

  static bool _contains(String text, String fragment) =>
      ' $text '.contains(' $fragment ');

  static bool _mentions(String source, String name) => _words(name)
      .split(' ')
      .where((word) => word.length > 2)
      .any((word) => ' $source '.contains(' $word '));
}

final class LedgerAttributionConflict implements Exception {
  const LedgerAttributionConflict(this.targetKey, this.sourceKey);

  final String targetKey;
  final String sourceKey;

  @override
  String toString() =>
      'Ledger attribution conflict: $targetKey copies unsupported relationship '
      'state from $sourceKey. Previous canon was preserved; review the source.';
}
