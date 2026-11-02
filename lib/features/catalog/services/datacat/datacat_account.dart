import '../../../../core/constants/app_version.dart';
import '../../../../core/credentials/datacat_account_credential_owner.dart';
import 'datacat_account_transport.dart';
import 'datacat_client.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';

/// Native linked-account lifecycle. Only nonsecret account state is returned;
/// tokens live in the owner's callback, never in provider/UI/service fields.
final class DatacatAccountService {
  DatacatAccountService({
    required DatacatAccountCredentialOwner credentials,
    required DatacatAccountTransport transport,
  }) : _credentials = credentials,
       _transport = transport;
  final DatacatAccountCredentialOwner _credentials;
  final DatacatAccountTransport _transport;
  bool _disposed = false;
  bool Function() captureAuthGuard() {
    final current = _credentials.captureAuthGuard();
    return () => !_disposed && current();
  }

  void dispose() {
    _disposed = true;
    _credentials.dispose();
    _transport.dispose();
  }

  Future<DatacatCredentialAccount> load() => _credentials.load();

  Map<String, dynamic> _deviceBody(
    String device, [
    Map<String, dynamic> extra = const {},
  ]) => {
    'installationId': device,
    'clientName': datacatClientName,
    'clientVersion': appVersion,
    ...extra,
  };

  /// Start and exchange retain ONE original admission and device, not a fresh
  /// lookup when the approval page eventually completes. No fabricated grants.
  Future<DatacatCredentialAccount> link({
    void Function(DatacatAccountApproval)? onFlow,
    bool Function()? isCancelled,
  }) => _credentials.link((device, ownerCurrent, commit) async {
    bool current() => !_disposed && ownerCurrent();
    final publicApproval = _transport.captureApprovalValidator();
    final data = await _transport.request(
      'POST',
      '/account-links',
      body: _deviceBody(device),
      isCurrent: current,
    );
    _transport.check(current);
    final flow = DatacatDeviceFlow.fromJson(data);
    if (flow.id.isEmpty ||
        flow.deviceCode.isEmpty ||
        !publicApproval(flow.uri, flow.userCode)) {
      throw const DatacatApiException(
        status: 0,
        message: 'DataCat did not return a link request',
      );
    }
    // This guard captures public fields only, never the raw flow/deviceCode.
    final userCode = flow.userCode;
    final approval = DatacatAccountApproval(
      uri: flow.uri,
      userCode: userCode,
      expiresIn: flow.expiresIn,
      canNavigate: (uri) => current() && publicApproval(uri, userCode),
    );
    _transport.check(current);
    if (!approval.canPublish)
      throw const DatacatApiException(
        status: 0,
        message: 'DataCat did not return a safe approval page',
      );
    onFlow?.call(approval);
    _transport.check(current);
    final deadline = DateTime.now().add(flow.expiresIn);
    while (DateTime.now().isBefore(deadline)) {
      _transport.check(current);
      await Future<void>.delayed(flow.interval);
      _transport.check(current);
      try {
        final data = await _transport.request(
          'POST',
          '/account-links/${Uri.encodeComponent(flow.id)}/token',
          body: _deviceBody(device, {'deviceCode': flow.deviceCode}),
          isCurrent: current,
        );
        _transport.check(current);
        // Only the original protocol's accessToken is accepted as the grant.
        // Other aliases are redaction coverage, NOT permission to forge a link.
        final token = data['accessToken'];
        if (token is! String || token.isEmpty) continue;
        final account = datacatMap(data['account']);
        final name = datacatString(account['displayName']).isNotEmpty
            ? datacatString(account['displayName'])
            : datacatString(account['username']);
        final scopes = data['scopes'] is List
            ? (data['scopes'] as List)
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .toList()
            : <String>[];
        await commit(token, name.isEmpty ? null : name, scopes);
        _transport.check(current);
        return;
      } on DatacatApiException catch (error) {
        _transport.check(current);
        if (error.isPending) continue;
        rethrow;
      }
    }
    throw const DatacatApiException(
      status: 410,
      message: 'The link request expired',
    );
  }, isCancelled: () => _disposed || (isCancelled?.call() ?? false));

  /// Owner guards are retained through HTTP and after the caller's await.
  /// Safe API failures are carried out of useSecret without raw exception causes.
  Future<T> withAccount<T>(
    Future<T> Function(
      String? token,
      String? device,
      DatacatCredentialAccount account,
      bool Function() current,
    )
    consume, {
    bool requiredAccount = false,
  }) async {
    final originalCurrent = captureAuthGuard();
    DatacatApiException? failure;
    final result = await _credentials.withAccount<T?>((
      token,
      device,
      account,
      ownerCurrent,
    ) async {
      bool current() => !_disposed && ownerCurrent();
      _transport.check(current);
      try {
        final value = await consume(token, device, account, current);
        _transport.check(current);
        return value;
      } on DatacatApiException catch (error) {
        _transport.check(current);
        failure = error;
        return null;
      }
    }, requiredAccount: requiredAccount);
    _transport.check(originalCurrent);
    if (failure != null) throw failure!;
    return result as T;
  }

  Future<DatacatAccountStatus> status() => withAccount((
    token,
    device,
    account,
    current,
  ) async {
    try {
      final data = await _transport.request(
        'GET',
        '/account/status',
        token: token,
        device: device,
        isCurrent: current,
      );
      _transport.check(current);
      // Missing, malformed or future states are not evidence of revocation.
      // Decide from the original finite protocol value, not a parsed fallback.
      final originalState = data['accountState'];
      if (data['success'] == false ||
          originalState is! String ||
          !const {
            'unlinked',
            'linked_anonymous',
            'logged_in',
          }.contains(originalState)) {
        return DatacatAccountStatus(
          accountState: account.authenticated ? 'logged_in' : 'unknown',
          displayName: account.displayName,
          scopes: account.scopes,
          credentialUnavailable: true,
        );
      }
      final status = DatacatAccountStatus.fromJson(
        _transport.safeData(data),
        scopes: account.scopes,
      );
      if (status.accountState != originalState) {
        return DatacatAccountStatus(
          accountState: account.authenticated ? 'logged_in' : 'unknown',
          displayName: account.displayName,
          scopes: account.scopes,
          credentialUnavailable: true,
        );
      }
      if (originalState == 'unlinked' && data['success'] != true) {
        return DatacatAccountStatus(
          accountState: account.authenticated ? 'logged_in' : 'unknown',
          displayName: account.displayName,
          scopes: account.scopes,
          credentialUnavailable: true,
        );
      }
      if (token != null && originalState == 'unlinked') {
        await _credentials.forgetRevoked(isCurrent: current);
        _transport.check(current);
        return const DatacatAccountStatus();
      }
      return status;
    } on DatacatApiException catch (error) {
      _transport.check(current);
      if (error.isUnauthorized) {
        if (token != null) {
          await _credentials.forgetRevoked(isCurrent: current);
          _transport.check(current);
        }
        return const DatacatAccountStatus();
      }
      // A network blip is not a logout, and a revoked token is not permission
      // for migration cleanup or an implicit remote revoke.
      return DatacatAccountStatus(
        accountState: account.authenticated ? 'logged_in' : 'unlinked',
        displayName: account.displayName,
        scopes: account.scopes,
        credentialUnavailable: true,
      );
    }
  });

  Future<Map<String, dynamic>> communityRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, Object?> query = const {},
    bool requiredAccount = false,
  }) => withAccount((token, device, account, current) async {
    final data = await _transport.request(
      method,
      path,
      token: token,
      device: device,
      body: body,
      query: query,
      isCurrent: current,
    );
    _transport.check(current);
    return _transport.safeData(data);
  }, requiredAccount: requiredAccount);

  Future<DatacatCredentialAccount> setToken(
    String token, {
    required String installationId,
    String? name,
    List<String> scopes = const [],
  }) => _credentials.setToken(
    token,
    installationId: installationId,
    name: name,
    scopes: scopes,
  );

  /// Only this explicit native action revokes remotely. Never used by migration
  /// or passive status reads; local truth follows verified secure readback.
  Future<DatacatCredentialAccount> unlink() =>
      _credentials.unlink((token, device, ownerCurrent) async {
        bool current() => !_disposed && ownerCurrent();
        await _transport.request(
          'DELETE',
          '/account',
          token: token,
          device: device,
          isCurrent: current,
        );
        _transport.check(current);
      });
}
