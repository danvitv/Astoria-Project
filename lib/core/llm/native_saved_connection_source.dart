import '../credentials/native_provider_credentials.dart';
import '../credentials/secret_redactor.dart';
import '../models/api_config.dart';

/// Constructor-owned saved-source preparation. Never reads a raw credential,
/// invokes a broker, or performs network work. The original stamp belongs to
/// the caller's run and must be captured before its first configuration await.
final class NativeSavedConnectionSourceResolver {
  NativeSavedConnectionSourceResolver({
    required this.mutations,
    required this.auth,
    required this.credentials,
    required this.currentRedactor,
  });

  final NativeConnectionMutationOwner mutations;
  final NativeSavedConnectionAuthIssuer auth;
  final NativeProviderCredentialVault credentials;
  final SecretRedactor Function() currentRedactor;
  final Expando<SecretRedactor> _redactors = Expando<SecretRedactor>(
    'original source redactor',
  );

  SecretRedactor? _readRedactor() {
    try {
      return currentRedactor();
    } catch (_) {
      return null;
    }
  }

  NativeConnectionStamp captureOriginalStamp() {
    final redactor = _readRedactor();
    final stamp = mutations.observe();
    if (stamp == null ||
        redactor == null ||
        !identical(redactor, _readRedactor()) ||
        !mutations.isCurrent(stamp)) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    _redactors[stamp] = redactor;
    return stamp;
  }

  /// Denial-only port for unrelated domains (summary/card/image/Janitor). A
  /// shared auxiliary client is not permission to borrow a Studio/Memory key.
  Future<void> requireLegacyOnly({
    required NativeConnectionStamp originalStamp,
    required String savedConnectionId,
    required bool Function() isCurrent,
  }) async {
    bool current() => isOriginalCurrent(originalStamp, isCurrent);
    if (!current()) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    final presence = await credentials.inspectNativePresence(
      connectionId: savedConnectionId,
      isCurrent: current,
    );
    if (!current()) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    if (presence != NativeProviderCredentialPresence.absent) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
  }

  /// An unused active config can supply prompt limits while Studio executes a
  /// DIFFERENT explicitly selected source. Project it without borrowing or
  /// requiring that source's Studio purpose. This returns NO dispatch authority.
  Future<ApiConfig> projectSavedSnapshot({
    required NativeConnectionStamp originalStamp,
    required ApiConfig configuration,
    required bool Function() isCurrent,
  }) async {
    bool current() => isOriginalCurrent(originalStamp, isCurrent);
    if (!current()) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    final presence = await credentials.inspectNativePresence(
      connectionId: configuration.id,
      isCurrent: current,
    );
    if (!current()) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    if (presence == NativeProviderCredentialPresence.absent) {
      return configuration;
    }
    if (presence != NativeProviderCredentialPresence.present) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final projected = projectNativeConfiguration(configuration);
    if (!current()) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    return projected;
  }

  bool isOriginalCurrent(
    NativeConnectionStamp stamp,
    bool Function() isCurrent,
  ) {
    final redactor = _redactors[stamp];
    try {
      if (redactor == null ||
          !mutations.isCurrent(stamp) ||
          !identical(redactor, _readRedactor()) ||
          !isCurrent()) {
        return false;
      }
      // A caller callback can synchronously retire the original native owner.
      return identical(redactor, _readRedactor()) && mutations.isCurrent(stamp);
    } catch (_) {
      return false;
    }
  }

  Future<NativePreparedSavedConnection> prepare({
    required NativeConnectionStamp originalStamp,
    required ApiConfig configuration,
    required NativeProviderPurpose purpose,
    required bool Function() isCurrent,
  }) async {
    bool current() => isOriginalCurrent(originalStamp, isCurrent);
    void requireCurrent() {
      if (!current()) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
    }

    requireCurrent();
    // Presence comes BEFORE identity parsing: even a malformed saved row cannot
    // turn a physical empty/corrupt/unavailable native slot into a legacy key.
    final presence = await credentials.inspectNativePresence(
      connectionId: configuration.id,
      isCurrent: current,
    );
    requireCurrent();
    if (presence == NativeProviderCredentialPresence.absent) {
      return NativePreparedSavedConnection._(
        configuration: configuration,
        savedConnectionAuth: null,
        savedConnectionId: configuration.id,
        isCurrent: current,
      );
    }
    if (presence != NativeProviderCredentialPresence.present) {
      throw NativeProviderException(
        presence == NativeProviderCredentialPresence.corrupt
            ? NativeProviderFailure.corrupt
            : NativeProviderFailure.unavailable,
      );
    }
    final reference = auth.referenceFor(configuration, purpose);
    requireCurrent();
    if (reference == null) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    final observed = await credentials.inspectSavedConnection(
      connection: reference,
      isCurrent: current,
    );
    // First read after restart can register key redaction and retire this stamp.
    // The ROOT caller decides to start a new run; never renew the old scope here.
    requireCurrent();
    if (!auth.isCurrent(reference) ||
        observed.state != NativeProviderCredentialState.ready) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final projected = projectNativeConfiguration(configuration);
    requireCurrent();
    return NativePreparedSavedConnection._(
      configuration: projected,
      savedConnectionAuth: reference,
      savedConnectionId: configuration.id,
      isCurrent: () => current() && auth.isCurrent(reference) && current(),
    );
  }

  /// Never redact an executable model/route into a different destination. The
  /// issuer already validates canonical route identity; check all other strings
  /// that can cross prompt/snapshot boundaries against the CURRENT redactor.
  ApiConfig projectNativeConfiguration(ApiConfig config) {
    final redactor = _readRedactor();
    if (redactor == null) {
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
    final fields = [
      config.id,
      config.providerId,
      config.protocol,
      config.model,
      config.mode,
      config.historyTrimMode,
      config.reasoningEffort,
      config.reasoningTagStart ?? '',
      config.reasoningTagEnd ?? '',
      config.embeddingEndpoint,
      config.embeddingModel,
      config.embeddingLlmPresetId,
      config.cacheControlTtl,
      config.cacheBreakpointMode,
      config.sessionIdMode,
      config.promptPostProcessing,
    ];
    if (config.apiKey.isNotEmpty ||
        config.embeddingApiKey.isNotEmpty ||
        config.embeddingEnabled ||
        config.extraRequestParameters.isNotEmpty ||
        fields.any((value) => redactor.redactText(value) != value)) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    // Endpoint projection encodes Gemini's ':' legitimately. Compare decoded
    // canonical output as well as the scheme-free original path.
    final safeUrl = redactor.redactUrl(config.endpoint);
    if (!config.endpoint.startsWith('https://') ||
        Uri.decodeFull(safeUrl) != config.endpoint ||
        redactor.redactText(config.endpoint.substring('https://'.length)) !=
            config.endpoint.substring('https://'.length)) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    return config.copyWith(
      name: redactor.redactText(config.name),
      apiKey: '',
      embeddingApiKey: '',
    );
  }
}

/// Opaque, nonserialized native scope. Only safe keyless configuration and the
/// original saved authority travel to constructors; neither contains a key.
final class NativePreparedSavedConnection {
  const NativePreparedSavedConnection._({
    required this.configuration,
    required this.savedConnectionAuth,
    required this.savedConnectionId,
    required this._isCurrent,
  });

  final ApiConfig configuration;
  final SavedConnectionAuth? savedConnectionAuth;
  final String savedConnectionId;
  final bool Function() _isCurrent;
  bool get isNative => savedConnectionAuth != null;
  bool get isCurrent => _isCurrent();

  /// Denial-only request custody, bound to THIS exact prepared scope. Request
  /// copies retain this closure; no row/auth/scope is freshly observed at wire.
  /// Legacy scopes keep the original null-callback constructor behavior.
  bool Function()? bindNativeCurrent({bool Function()? isCurrent}) {
    if (!isNative) return null;
    var retired = false;
    return () {
      if (retired) return false;
      try {
        if (!this.isCurrent || isCurrent?.call() == false || !this.isCurrent) {
          retired = true;
          return false;
        }
        return true;
      } catch (_) {
        retired = true;
        return false;
      }
    };
  }

  void requireCurrent() {
    if (!isCurrent) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
  }

  void requireModel(String model) {
    requireCurrent();
    if (isNative && model != configuration.model) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
  }

  @override
  String toString() => 'NativePreparedSavedConnection';
}
