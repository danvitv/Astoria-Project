import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';

import 'content_control_fixture.dart';

void contentControlTest(
  String name,
  Future<void> Function(ContentControlFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String what) {
      attempts.add(what);
      throw StateError('Outside synthetic content-control fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native:$channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final fixture = ContentControlFixture(block);
            try {
              await fixture.initialize();
              await body(fixture);
            } finally {
              fixture.container.dispose();
              fixture.sources.dispose();
              await fixture.db.close();
              await messenger.platformMessagesFinished;
              expect(
                attempts,
                isEmpty,
                reason:
                    'No swallowed native, file, preferences, vault, AEAD or network access.',
              );
            }
          },
          createFile: (_) => block('file/defaultDB'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              block('socket.startConnect'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

/// Finite fake custody: these operations are never needed in this no-Undo lane.
/// Any accidentally evaluated vault graph is still synthetic and a tripwire.
final class ContentTrapStorage implements CredentialStorage {
  ContentTrapStorage(this.block);
  final Never Function(String) block;
  @override
  Future<String?> read(String key) async => block('vault:read');
  @override
  Future<void> write(String key, String value) async => block('vault:write');
  @override
  Future<void> delete(String key) async => block('vault:delete');
}

final class ContentTrapCipher implements Cipher {
  ContentTrapCipher(this.block);
  final Never Function(String) block;
  @override
  List<int> newNonce() => block('AEAD:nonce');
  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async => block('AEAD:encrypt');
  @override
  Future<List<int>> decrypt(
    SecretBox box, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async => block('AEAD:decrypt');
  @override
  dynamic noSuchMethod(Invocation invocation) => block('AEAD:unsupported');
}
