part of 'support_provider_ui_binding.dart';

/// Trusted native input port. No key enters ActionService, a review DTO, chat,
/// tools, history or config row. Only configured/Unicode-rune count comes back.
final class SupportProviderNativeKeyEntry {
  SupportProviderNativeKeyEntry._(this._binding, this._handle, this._auth) {
    _lifetime = NativeProviderViewLifetime(isCurrent: () => current);
  }
  final SupportProviderUiBinding _binding;
  final SupportProviderConnectionHandle _handle;
  final SavedConnectionAuth _auth;
  late final NativeProviderViewLifetime _lifetime;
  NativeProviderRouteReview? _destination;
  NativeProviderDestinationApproval? _approval;
  NativeProviderSecretEntryReview? _review;
  bool _closed = false, _submitting = false;

  bool get current => !_closed && _binding.current && _handle.value != null;
  SupportProviderSetupValue? get value => current ? _handle.value : null;
  SupportProviderPurpose get purpose => _handle.purpose;
  bool get requiresCustomConfirmation =>
      _destination != null && _approval == null;
  bool get readyForInput =>
      current && _review?.isCurrent == true && !_submitting;
  List<String> get destinations => current
      ? List.unmodifiable(
          (_review?.routes ?? _destination?.routes ?? const []).map(
            (r) => r.endpoint.toString(),
          ),
        )
      : const [];

  Future<bool> _prepare() async {
    try {
      if (!current) return false;
      final native = _binding._native;
      final purposes = {_auth.purpose};
      if (native.routes.requiresCustomDestinationApproval(_auth.connection)) {
        _destination = native.routes.reviewCustomDestination(
          connection: _auth.connection,
          purposes: purposes,
          lifetime: _lifetime,
        );
        return current;
      }
      return _prepareReview();
    } catch (_) {
      return false;
    }
  }

  /// Separate actual native destination gesture. The keyless setup confirmation
  /// is NOT reused here and cannot be transferred to another key/origin.
  Future<bool> confirmDestination() async {
    final destination = _destination;
    if (!current || destination == null || _approval != null || _submitting) {
      return false;
    }
    try {
      _approval = _binding._native.routes.confirmCustomDestination(destination);
      return await _prepareReview() && current;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _prepareReview() async {
    final review = await _binding._native.secretEntry.review(
      connection: _auth,
      purposes: {_auth.purpose},
      lifetime: _lifetime,
      destinationApproval: _approval,
    );
    if (!current) return false;
    _review = review;
    return true;
  }

  /// ONLY the trusted native TextEditingController's final submit gesture.
  /// Caller starts this future then clears input before notifying/awaiting.
  Future<CredentialMetadata>? submitNativeSecret(String secret) {
    if (!readyForInput) return null;
    _submitting = true; // Reentrant final gestures cannot create a second job.
    try {
      _binding._redaction.registerSecret(
        secret,
      ); // Before the first permission await.
    } catch (_) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.unavailable),
      );
    }
    return _submitOriginal(secret);
  }

  Future<CredentialMetadata> _submitOriginal(String secret) async {
    if (!await _binding._freshLocalChanges() ||
        !current ||
        _review?.isCurrent != true) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    final native = _binding._native;
    final permit = native.secretEntry.confirmNativeEntry(_review!);
    // No UI transition, notify or await between permit and actual native owner.
    return native.credentials.storeFromNativeEntry(
      permit: permit,
      secret: secret,
    );
  }

  void dispose() {
    _closed = true;
    _lifetime.retire();
  }

  @override
  String toString() => 'SupportProviderNativeKeyEntry';
}
