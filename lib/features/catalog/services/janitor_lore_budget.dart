import '../../../core/llm/tokenizer.dart';
import 'janitor_separate.dart';

const janitorLoreTokenCap = 120000;
const janitorLoreSaturationMargin = 12000;

/// Astoria keeps o200k. This is a conservative saturation heuristic, not a
/// claim to match Janitor's cl100k tokenizer or recover every possible entry.
class JanitorLoreBudget {
  JanitorLoreBudget(this.count);
  factory JanitorLoreBudget.local() => JanitorLoreBudget((text) {
    final tokens = estimateTokens(text, useCache: false);
    final conservative = (text.length / 3).ceil();
    return tokens > conservative ? tokens : conservative;
  });
  final int Function(String) count;
  int loreTokens(Map<String, dynamic> payload, {Map<String, dynamic>? probe}) {
    final split = stripWrappers(getSystemContent(payload));
    var total = count(split.out);
    if (probe != null) {
      final old = stripWrappers(getSystemContent(probe));
      final growth =
          split.removed.fold<int>(0, (s, b) => s + count(b.text)) -
          old.removed.fold<int>(0, (s, b) => s + count(b.text));
      if (growth > 0) total += growth;
    }
    return total;
  }

  bool isSaturated(
    Map<String, dynamic> payload, {
    Map<String, dynamic>? probe,
  }) =>
      loreTokens(payload, probe: probe) >=
      janitorLoreTokenCap - janitorLoreSaturationMargin;
}

List<String> splitTrigger(String text) {
  final trimmed = text.trim();
  for (final (boundary, separator) in [
    (RegExp(r'\n\s*\n'), '\n\n'),
    (RegExp(r'\n'), '\n'),
    (RegExp(r'(?<=[.!?…])\s+'), ' '),
    (RegExp(r'\s+'), ' '),
  ]) {
    final parts = trimmed
        .split(boundary)
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2) continue;
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    var cut = 1;
    var left = parts.first.length;
    while (cut < parts.length - 1 &&
        (left + parts[cut].length) * 2 <= total + parts[cut].length) {
      left += parts[cut++].length;
    }
    return [parts.take(cut).join(separator), parts.skip(cut).join(separator)];
  }
  return [trimmed];
}

String mergeLorebookTexts(Iterable<String> texts) {
  final seen = <String>{};
  final entries = <String>[];
  for (final text in texts) {
    for (final entry in splitEntries(text)) {
      if (seen.add(
        entry.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase(),
      )) {
        entries.add(entry);
      }
    }
  }
  return entries.join('\n\n');
}
