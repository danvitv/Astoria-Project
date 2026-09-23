import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class SyncConfig {
  // Dropbox requires an exact registered localhost redirect, including port.
  // Google Drive desktop clients can continue to use an OS-assigned port.
  static const dropboxDesktopPort = 43178;

  static String? _dropboxAppKey;
  static String? _dropboxAppSecret;
  static String? _gdriveClientId;
  static String? _gdriveClientSecret;
  static String? _gdriveIosClientId;
  static String? _gdriveAndroidServerClientId;

  static Future<void> load() async {
    if (!dotenv.isInitialized) {
      await dotenv.load(fileName: '.env');
    }
    _dropboxAppKey = dotenv.env['DROPBOX_APP_KEY'];
    _dropboxAppSecret = dotenv.env['DROPBOX_APP_SECRET'];
    _gdriveClientId = dotenv.env['GDRIVE_CLIENT_ID'];
    _gdriveClientSecret = dotenv.env['GDRIVE_CLIENT_SECRET'];
    _gdriveIosClientId = dotenv.env['GDRIVE_IOS_CLIENT_ID'];
    _gdriveAndroidServerClientId =
        dotenv.env['GDRIVE_ANDROID_SERVER_CLIENT_ID'];
  }

  static String? get dropboxAppKey => _dropboxAppKey;
  static String? get dropboxAppSecret => _dropboxAppSecret;
  // Dropbox's mobile SDKs use the app-key-specific db- scheme. The same
  // callback can be handled by app_links without bundling a Dropbox SDK.
  static String get dropboxRedirectNative => 'db-$_dropboxAppKey://2/token';
  static String? get gdriveClientId => _gdriveClientId;
  static String? get gdriveClientSecret => _gdriveClientSecret;
  static String? get gdriveIosClientId => _gdriveIosClientId;
  static String? get gdriveAndroidServerClientId =>
      _gdriveAndroidServerClientId;

  static bool canStartSyncAuth(String provider) {
    switch (provider) {
      case 'dropbox':
        return _dropboxAppKey != null && _dropboxAppKey!.isNotEmpty;
      case 'gdrive':
        if (Platform.isIOS) {
          return _gdriveIosClientId?.isNotEmpty ?? false;
        }
        if (Platform.isAndroid) {
          return _gdriveAndroidServerClientId?.isNotEmpty ?? false;
        }
        return _gdriveClientId != null && _gdriveClientId!.isNotEmpty;
      default:
        return false;
    }
  }

  static bool hasAnySyncProviderConfigured() =>
      canStartSyncAuth('dropbox') || canStartSyncAuth('gdrive');
}
