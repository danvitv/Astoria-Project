import 'credential_metadata.dart';
import 'credential_route.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';

/// This callback is installed by trusted native code, never supplied by a tool.
/// It must send ONLY to [route], disable authenticated redirects, and avoid
/// logging/retaining the secret. There is no HTTP implementation in Phase 1A.
typedef NativeCredentialTransport =
    Future<void> Function(CredentialRoute route, String secret);

/// The composition root's native policy: vetted routes or explicit native UI
/// approval for this exact slot/route/protocol/purpose. Not an assistant boolean.
typedef NativeCredentialApproval =
    Future<bool> Function(CredentialSlot slot, CredentialRoute route);

enum CredentialBrokerFailure { denied, revoked, unavailable }

final class CredentialBrokerException implements Exception {
  const CredentialBrokerException(this.failure);
  const CredentialBrokerException.revoked()
    : failure = CredentialBrokerFailure.revoked;

  final CredentialBrokerFailure failure;

  @override
  String toString() => 'CredentialBrokerException(${failure.name})';
}

/// Opaque in-process capability, with no secret, public route, or serializer.
final class CredentialHandle {
  const CredentialHandle._(this._slot, this._route);

  final CredentialSlot _slot;
  final CredentialRoute _route;

  @override
  String toString() => 'CredentialHandle';
}

/// Public methods never accept a secret consumer or return a secret/response.
/// Only the constructor-injected native transport can consume a vault value.
/// Possession of a handle permits its previously approved route, not rebinding.
final class CredentialBroker {
  CredentialBroker({
    required CredentialVault vault,
    required NativeCredentialApproval approve,
    required NativeCredentialTransport transport,
    // Public injection names must not expose the private dependency fields.
    // ignore: prefer_initializing_formals
  }) : _vault = vault,
       // ignore: prefer_initializing_formals
       _approve = approve,
       // ignore: prefer_initializing_formals
       _transport = transport;

  final CredentialVault _vault;
  final NativeCredentialApproval _approve;
  final NativeCredentialTransport _transport;
  final Set<CredentialHandle> _active = {};
  final Map<CredentialSlot, int> _slotEpochs = {};

  Future<CredentialHandle> bind(
    CredentialSlot slot,
    CredentialRoute route,
  ) async {
    final epoch = _slotEpochs[slot] ?? 0;
    final bool approved;
    try {
      approved = await _approve(slot, route);
    } catch (_) {
      _requireEpoch(slot, epoch);
      throw const CredentialBrokerException(CredentialBrokerFailure.denied);
    }
    _requireEpoch(slot, epoch);
    if (!approved) {
      throw const CredentialBrokerException(CredentialBrokerFailure.denied);
    }
    final handle = CredentialHandle._(slot, route);
    _active.add(handle);
    return handle;
  }

  Future<CredentialMetadata> metadata(CredentialHandle handle) async {
    _requireActive(handle);
    try {
      final result = await _vault.metadata(handle._slot);
      _requireActive(handle);
      return result;
    } on CredentialBrokerException {
      rethrow;
    } catch (_) {
      _requireActive(handle);
      throw const CredentialBrokerException(
        CredentialBrokerFailure.unavailable,
      );
    }
  }

  Future<void> dispatch(
    CredentialHandle handle, {
    required CredentialRoute route,
  }) async {
    _requireActive(handle);
    if (route != handle._route) {
      throw const CredentialBrokerException(CredentialBrokerFailure.denied);
    }
    try {
      await _vault.useSecret(handle._slot, (secret) async {
        // Revocation while awaiting the vault must prevent a late send.
        _requireActive(handle);
        await _transport(handle._route, secret);
      });
    } catch (_) {
      // The vault suppresses consumer exceptions; check our own capability
      // state rather than recovering an unsafe underlying exception.
      _requireActive(handle);
      throw const CredentialBrokerException(
        CredentialBrokerFailure.unavailable,
      );
    }
  }

  /// Prevents future dispatches; does not abort an already invoked transport.
  void revoke(CredentialHandle handle) => _active.remove(handle);

  /// Invalidate active handles AND approvals already in flight for this slot.
  /// Native rotation/deletion/endpoint changes must call this before mutation.
  void revokeSlot(CredentialSlot slot) {
    _slotEpochs[slot] = (_slotEpochs[slot] ?? 0) + 1;
    _active.removeWhere((handle) => handle._slot == slot);
  }

  void _requireEpoch(CredentialSlot slot, int epoch) {
    if ((_slotEpochs[slot] ?? 0) != epoch) {
      throw const CredentialBrokerException.revoked();
    }
  }

  void _requireActive(CredentialHandle handle) {
    if (!_active.contains(handle)) {
      throw const CredentialBrokerException.revoked();
    }
  }

  @override
  String toString() => 'CredentialBroker';
}
