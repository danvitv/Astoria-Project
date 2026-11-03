import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_compression.dart';

void main() {
  final logical = utf8.encode('synthetic retained evidence Ж\n' * 1024);

  test('new pages have a portable header without altering the gzip body', () {
    final original = Uint8List.fromList(gzip.encode(logical));
    final compressed = Uint8List.fromList(original);
    final hash = ReconciliationPageCompression.preparePage(compressed, {});
    expect(compressed[9], 255);
    expect(compressed.sublist(0, 9), original.sublist(0, 9));
    expect(compressed.sublist(10), original.sublist(10));
    expect(sha256.convert(compressed).toString(), hash);
    expect(gzip.decode(compressed), logical);
  });

  for (final operatingSystem in [0, 3, 7, 10, 19, 255]) {
    test(
      'reused OS=$operatingSystem page retains its exact bytes and hash',
      () {
        final previous = Uint8List.fromList(gzip.encode(logical))
          ..[9] = operatingSystem;
        final previousHash = sha256.convert(previous).toString();
        final compressed = Uint8List.fromList(gzip.encode(logical));
        final hash = ReconciliationPageCompression.preparePage(compressed, {
          '$previousHash.b64',
        });
        expect(hash, previousHash);
        expect(compressed, previous);
        expect(sha256.convert(compressed).toString(), hash);
        expect(gzip.decode(compressed), logical);
      },
    );
  }

  test('different content cannot reuse a published legacy hash', () {
    final previous = Uint8List.fromList(gzip.encode(logical))..[9] = 3;
    final previousHash = sha256.convert(previous).toString();
    final replacement = utf8.encode('different synthetic evidence Ж\n' * 1024);
    final compressed = Uint8List.fromList(gzip.encode(replacement));
    final hash = ReconciliationPageCompression.preparePage(compressed, {
      '$previousHash.b64',
    });
    expect(hash, isNot(previousHash));
    expect(compressed[9], 255);
    expect(sha256.convert(compressed).toString(), hash);
    expect(gzip.decode(compressed), replacement);
  });

  test('optional or invalid gzip headers cannot be silently rewritten', () {
    for (final compressed in [
      Uint8List(10),
      Uint8List.fromList(gzip.encode(logical))..[0] = 0,
      Uint8List.fromList(gzip.encode(logical))..[3] = 2,
    ]) {
      final before = Uint8List.fromList(compressed);
      expect(
        () => ReconciliationPageCompression.preparePage(compressed, {}),
        throwsFormatException,
      );
      expect(compressed, before);
    }
  });
}
