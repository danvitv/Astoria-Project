/// The only credential information suitable for diagnostics or model DTOs.
final class CredentialMetadata {
  const CredentialMetadata._(this.configured, this.characterCount);

  static const absent = CredentialMetadata._(false, 0);

  /// Trusted code may derive metadata, but must not retain [secret] in a DTO.
  factory CredentialMetadata.fromSecret(String? secret) {
    if (secret == null || secret.isEmpty) return absent;
    return CredentialMetadata._(true, secret.runes.length);
  }

  /// Decodes only the public summary, never reconstructing a secret string.
  factory CredentialMetadata.fromJson(Map<String, dynamic> json) {
    final configured = json['configured'];
    final count = json['characterCount'];
    if (json.length != 2 ||
        configured is! bool ||
        count is! int ||
        count < 0 ||
        configured != (count > 0)) {
      throw const FormatException('Invalid credential metadata');
    }
    return CredentialMetadata._(configured, count);
  }

  final bool configured;
  final int characterCount;

  Map<String, Object> toJson() => {
    'configured': configured,
    'characterCount': characterCount,
  };

  @override
  bool operator ==(Object other) =>
      other is CredentialMetadata &&
      configured == other.configured &&
      characterCount == other.characterCount;

  @override
  int get hashCode => Object.hash(configured, characterCount);

  @override
  String toString() => 'CredentialMetadata($configured, $characterCount)';
}
