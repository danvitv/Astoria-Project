/// Comparison-only projection of CharacterRepo's redundant world field.
/// Extensions stay exact: this is not a card repair or a new published hash.
class SyncCharacterWorldEquivalence {
  static bool isValid(Map<String, dynamic> json) {
    final top = json['world'];
    final extensions = json['extensions'];
    if (top != null && top is! String) return false;
    if (extensions is! Map<String, dynamic>) return false;
    final linked = extensions['world'];
    return !extensions.containsKey('world') || linked is String;
  }

  static Map<String, dynamic>? project(Map<String, dynamic> json) {
    if (!isValid(json)) return null;
    final top = json['world'];
    final linked = (json['extensions'] as Map<String, dynamic>)['world'];
    final effective = top is String && top.isNotEmpty
        ? top
        : linked is String && linked.isNotEmpty
        ? linked
        : null;
    return Map<String, dynamic>.from(json)..['world'] = effective;
  }
}
