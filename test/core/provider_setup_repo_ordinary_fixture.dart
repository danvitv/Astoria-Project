import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

import 'provider_setup_repo_fixture.dart';

/// Declared synthetic guard only. Production record readiness/disabling remains
/// the parent's native owner integration; this fixture never reads a real key.
final class ProviderFakeOrdinaryGuard
    implements ApiConfigOrdinaryMutationGuard {
  ProviderFakeOrdinaryGuard(this.fixture);
  final ProviderRepoFixture fixture;
  final labels = <String>[];
  final puts = <({ApiConfig? existing, ApiConfig proposed})>[];
  final deletes = <String>[];
  final disabled = <String>{};
  bool denyPut = false;
  bool denyDelete = false;
  Future<void> Function(ApiConfig? existing, ApiConfig proposed)? inspectPut;

  @override
  Future<T> run<T>({
    required String connectionId,
    required Future<T> Function() operation,
  }) async {
    labels.add(connectionId);
    final lease = await fixture.native.acquireOrdinary(
      connectionId,
      () => fixture.current,
    );
    if (lease == null) {
      throw StateError('Synthetic unavailable ordinary owner.');
    }
    try {
      return await lease.runObservedMutation(operation);
    } finally {
      await lease.release();
    }
  }

  @override
  Future<void> beforePut({
    required ApiConfig? existing,
    required ApiConfig proposed,
  }) async {
    puts.add((existing: existing, proposed: proposed));
    await inspectPut?.call(existing, proposed);
    if (!fixture.native.credentialStateKnown) {
      throw StateError('Synthetic unavailable record state.');
    }
    if (denyPut) throw StateError(ProviderRepoFixture.secretCanary);
    // The actual proposal ID/previous row are authority inputs, not the run label.
    if (!fixture.native.protectedConnections.contains(proposed.id)) return;
    if (proposed.apiKey.isNotEmpty ||
        proposed.embeddingApiKey.isNotEmpty ||
        proposed.embeddingEnabled ||
        proposed.embeddingUseSame ||
        proposed.extraRequestParameters.isNotEmpty) {
      throw StateError('Synthetic conflicting native row.');
    }
    if (existing == null || existing.id != proposed.id) {
      throw StateError('Synthetic native row unavailable.');
    }
    if (existing.endpoint != proposed.endpoint ||
        existing.model != proposed.model ||
        existing.protocol != proposed.protocol ||
        existing.stream != proposed.stream) {
      disabled.add(proposed.id);
    }
  }

  @override
  Future<void> beforeDelete(String id) async {
    deletes.add(id);
    if (!fixture.native.credentialStateKnown) {
      throw StateError('Synthetic unavailable record state.');
    }
    if (denyDelete) throw StateError(ProviderRepoFixture.secretCanary);
    if (fixture.native.protectedConnections.contains(id)) disabled.add(id);
    // There is intentionally no native credential delete or transfer method.
  }
}
