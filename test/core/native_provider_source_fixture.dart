import 'dart:async';

import 'package:glaze_flutter/core/llm/native_saved_connection_source.dart';

import 'native_provider_transport_fixture.dart';

export 'native_provider_transport_fixture.dart';
export 'package:glaze_flutter/core/llm/native_saved_connection_source.dart';

/// Declared fake saved source. A held read returns its ORIGINAL row, so tests
/// can distinguish original-stamp checking from accidental late reobservation.
final class NativeSourceFakeApiRepo {
  NativeSourceFakeApiRepo(this.row);
  ApiConfig row;
  Future<void> Function()? beforeRead;
  int reads = 0;

  Future<List<ApiConfig>> getAll() async {
    final original = row;
    reads++;
    await beforeRead?.call();
    return [original];
  }
}

final class NativeSourceConsumerFixture {
  NativeSourceConsumerFixture({String protocol = 'openai', ApiConfig? row})
    : wire = NativeTransportHarness(protocol, row: row) {
    sources = NativeSavedConnectionSourceResolver(
      mutations: wire.core.mutations,
      auth: wire.core.auth,
      credentials: wire.core.credentials,
      currentRedactor: () => wire.core.redaction.redactor,
    );
    repo = NativeSourceFakeApiRepo(wire.core.row);
  }

  final NativeTransportHarness wire;
  late final NativeSavedConnectionSourceResolver sources;
  late final NativeSourceFakeApiRepo repo;
  bool runCurrent = true;
  String sessionId = 'original-session';
  int promptBuilds = 0;
  ApiConfig? promptConfig;

  Future<NativePreparedSavedConnection> prepare({
    NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
  }) async {
    final original = sources.captureOriginalStamp();
    final originalSession = sessionId;
    final rows = await repo.getAll();
    final source = await sources.prepare(
      originalStamp: original,
      configuration: rows.single,
      purpose: purpose,
      isCurrent: () => runCurrent && sessionId == originalSession,
    );
    source.requireCurrent();
    promptBuilds++;
    promptConfig = source.configuration;
    return source;
  }
}

final class NativeSourceHeldGate {
  final entered = Completer<void>();
  final released = Completer<void>();
  Future<void> hold() async {
    if (!entered.isCompleted) entered.complete();
    await released.future;
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}
