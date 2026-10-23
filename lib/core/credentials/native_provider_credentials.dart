import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../models/api_config.dart';
import 'credential_metadata.dart';
import 'credential_route.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

export 'credential_metadata.dart';
export 'credential_route.dart';

part 'native_provider_connection.dart';
part 'native_provider_mutations.dart';
part 'native_provider_route_policy.dart';
part 'native_provider_secret_entry.dart';
part 'native_provider_credential_record.dart';
part 'native_provider_credential_vault.dart';
part 'native_provider_credential_presence.dart';
part 'native_provider_preparation.dart';
part 'native_provider_credential_metadata.dart';
part 'native_provider_credential_broker.dart';
part 'native_provider_ordinary_mutation.dart';
part 'native_provider_ownership.dart';

enum NativeProviderPurpose { roleplay, studio, memoryBooks, astoria }

enum NativeProviderFailure { denied, stale, unavailable, corrupt, conflicting }

/// Never retains a cause, caller text, storage key, route or credential.
final class NativeProviderException implements Exception {
  const NativeProviderException(this.failure);
  final NativeProviderFailure failure;

  @override
  String toString() => 'NativeProviderException(${failure.name})';
}

bool _current(bool Function() check) {
  try {
    return check();
  } catch (_) {
    return false;
  }
}

void _requireCurrent(bool Function() check) {
  if (!_current(check)) {
    throw const NativeProviderException(NativeProviderFailure.stale);
  }
}

String _nativeRevision() {
  final random = Random.secure();
  return List.generate(
    24,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
