import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_config.dart';

void main() {
  test(
    'mobile Dropbox callback is derived from the configured app key',
    () async {
      dotenv.loadFromString(envString: 'DROPBOX_APP_KEY=astoriakey');
      await SyncConfig.load();

      expect(SyncConfig.dropboxRedirectNative, 'db-astoriakey://2/token');
      expect(SyncConfig.canStartSyncAuth('dropbox'), isTrue);
    },
  );
}
