import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/credentials/credential_vault.dart';
import '../../core/credentials/datacat_account_credential_owner.dart';
import '../../core/state/credential_vault_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import 'services/datacat/datacat_account.dart';
import 'services/datacat/datacat_account_transport.dart';
import 'services/datacat/datacat_models.dart';

/// Native composition only. Captures the original producer before any await.
final datacatAccountServiceProvider = Provider<DatacatAccountService>((ref) {
  final original = ref.watch(sharedPreferencesProvider.future);
  final redaction = ref.watch(secretRedactionCoordinatorProvider);
  final credentials = DatacatAccountCredentialOwner(
    vault: ref.watch(credentialVaultProvider),
    redaction: redaction,
    originalPreferences: original,
  );
  final transport = DatacatAccountTransport(redaction: redaction);
  final service = DatacatAccountService(
    credentials: credentials,
    transport: transport,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// The DataCat account linked to this installation, as the UI sees it.
///
/// Linking exists for one reason: kudos and comments are attributed to a
/// logged-in account. Everything else DataCat is used for works without it, so
/// nothing here blocks startup and an unlinked state is a normal, permanent
/// one — not an error to recover from.
class DatacatAccount {
  /// DataCat's own three-way answer: `unlinked`, `linked_anonymous` or
  /// `logged_in`.
  final String accountState;

  final String? displayName;
  final List<String> scopes;

  /// True while the link is being established or read.
  final bool busy;
  final bool credentialUnavailable;

  const DatacatAccount({
    this.accountState = 'unlinked',
    this.displayName,
    this.scopes = const [],
    this.busy = false,
    this.credentialUnavailable = false,
  });

  /// Whether this installation is attached to DataCat at all.
  bool get linked =>
      accountState == 'logged_in' || accountState == 'linked_anonymous';

  /// Whether a real account stands behind the link. An installation can be
  /// linked anonymously, which reads fine but cannot post.
  bool get loggedIn => accountState == 'logged_in';

  /// Whether kudos and comments can actually be sent. Three things have to
  /// hold: linked, to a logged-in account, with the write scope approved — and
  /// a button that always fails is worse than no button.
  bool get canWrite =>
      !credentialUnavailable && loggedIn && scopes.contains('community:write');

  DatacatAccount copyWith({
    String? accountState,
    String? displayName,
    List<String>? scopes,
    bool? busy,
    bool? credentialUnavailable,
  }) => DatacatAccount(
    accountState: accountState ?? this.accountState,
    displayName: displayName ?? this.displayName,
    scopes: scopes ?? this.scopes,
    busy: busy ?? this.busy,
    credentialUnavailable: credentialUnavailable ?? this.credentialUnavailable,
  );
}

class DatacatAccountNotifier extends Notifier<DatacatAccount> {
  late DatacatAccountService _service;
  int _generation = 0, _publication = 0;

  @override
  DatacatAccount build() {
    _service = ref.watch(datacatAccountServiceProvider);
    unawaited(_loadStored(_service, ++_generation, ++_publication));
    return const DatacatAccount();
  }

  /// Shows what is stored immediately, without a round-trip. The server is
  /// only asked when the user opens the account screen — a launch must not
  /// spend a request on a feature most sessions never touch.
  ///
  /// A stored token means the link survived, so it is shown as logged in until
  /// a real status read says otherwise; the alternative is a screen that says
  /// "not linked" for a second on every launch.
  bool _current(
    DatacatAccountService service,
    int generation,
    int publication,
  ) =>
      ref.mounted &&
      identical(service, _service) &&
      generation == _generation &&
      publication == _publication;

  DatacatAccount _account(DatacatCredentialAccount value) => DatacatAccount(
    accountState: value.authenticated ? 'logged_in' : 'unlinked',
    displayName: value.displayName,
    scopes: value.scopes,
    credentialUnavailable: value.unavailable,
  );

  Future<void> _loadStored(
    DatacatAccountService service,
    int generation,
    int publication,
  ) async {
    final authCurrent = service.captureAuthGuard();
    try {
      final value = await service.load();
      if (_current(service, generation, publication) && authCurrent())
        state = _account(value);
    } catch (_) {
      if (_current(service, generation, publication)) {
        state = const DatacatAccount(credentialUnavailable: true);
      }
    }
  }

  /// Re-reads the link from the server, so a token revoked on the website
  /// stops being shown as linked here.
  Future<void> refresh() async {
    final service = _service, generation = _generation;
    final publication = ++_publication;
    final authCurrent = service.captureAuthGuard();
    state = state.copyWith(busy: true);
    try {
      final status = await service.status();
      if (!_current(service, generation, publication) || !authCurrent()) return;
      state = DatacatAccount(
        accountState: status.accountState,
        displayName: status.displayName,
        scopes: status.scopes,
        credentialUnavailable: status.credentialUnavailable,
      );
    } catch (_) {
      if (_current(service, generation, publication)) {
        state = state.copyWith(credentialUnavailable: true);
      }
    } finally {
      if (_current(service, generation, publication))
        state = state.copyWith(busy: false);
    }
  }

  /// The provider, not a WidgetRef held past await, owns completed publication.
  Future<void> link({
    void Function(DatacatAccountApproval)? onFlow,
    bool Function()? isCancelled,
  }) => _mutate(
    (service) => service.link(onFlow: onFlow, isCancelled: isCancelled),
  );

  Future<void> _mutate(
    Future<DatacatCredentialAccount> Function(DatacatAccountService) operation,
  ) async {
    final service = _service, generation = _generation;
    final publication = ++_publication;
    state = state.copyWith(busy: true);
    final pending = operation(
      service,
    ); // Original admission precedes first await.
    final authCurrent = service.captureAuthGuard();
    try {
      final value = await pending;
      if (!_current(service, generation, publication) || !authCurrent()) {
        throw const CredentialVaultAdmissionDenied();
      }
      state = _account(value);
    } catch (_) {
      if (_current(service, generation, publication)) {
        state = state.copyWith(busy: false, credentialUnavailable: true);
      }
      rethrow;
    }
  }

  Future<void> unlink() => _mutate((service) => service.unlink());
}

final datacatAccountProvider =
    NotifierProvider<DatacatAccountNotifier, DatacatAccount>(
      DatacatAccountNotifier.new,
    );
