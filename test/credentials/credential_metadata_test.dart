import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';

void main() {
  test('metadata equality uses configured/count only, not secret identity', () {
    final first = CredentialMetadata.fromSecret('A🔐');
    final second = CredentialMetadata.fromSecret('Bc');
    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(first, isNot(CredentialMetadata.fromSecret('abc')));
    expect(first, isNot(CredentialMetadata.absent));
    expect(
      CredentialMetadata.fromSecret(null),
      CredentialMetadata.fromSecret(''),
    );
    expect({first, second}, hasLength(1));
    expect(first == Object(), isFalse);
  });
}
