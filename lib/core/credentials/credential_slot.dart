/// Identifies a credential without containing its value.
final class CredentialSlot {
  factory CredentialSlot({required String domain, required String id}) {
    final valid = RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9._-]{0,127}$');
    if (!valid.hasMatch(domain) || !valid.hasMatch(id)) {
      // Never attach caller-controlled values to validation errors.
      throw const FormatException('Invalid credential slot');
    }
    return CredentialSlot._(domain, id);
  }

  const CredentialSlot._(this.domain, this.id);

  final String domain;
  final String id;

  // Length-prefixing prevents collisions between domain/id pairs.
  String get storageSuffix => '${domain.length}:$domain:$id';

  @override
  bool operator ==(Object other) =>
      other is CredentialSlot && domain == other.domain && id == other.id;

  @override
  int get hashCode => Object.hash(domain, id);

  @override
  String toString() => 'CredentialSlot';
}
