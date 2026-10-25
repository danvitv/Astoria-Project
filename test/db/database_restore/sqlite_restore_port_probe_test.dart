import 'package:flutter_test/flutter_test.dart';

import 'sqlite_restore_port_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['DELETE', 'WAL']) {
    restorePortTest(
      'SQLite restore port $mode retained lease full image and same raw acceptance',
      mode,
      RestorePortCase.complete,
    );
    restorePortTest(
      'SQLite restore port $mode real contention and active destination refusal',
      mode,
      RestorePortCase.contention,
    );
    restorePortTest(
      'SQLite restore port $mode incomplete backup finish rolls back',
      mode,
      RestorePortCase.incomplete,
    );
    restorePortTest(
      'SQLite restore port $mode bootstrap invalid header observations',
      mode,
      RestorePortCase.bootstrap,
    );
  }
}
