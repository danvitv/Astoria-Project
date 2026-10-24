import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'app_control_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  appControlTest(
    'installed selection and mode change real theme store and notifier',
    (f) async {
      final listing = await f.call('astoria_themes_list');
      final data = listing.content['data']! as Map;
      expect(data['activeThemeId'], 'default');
      expect((data['themes']! as List), hasLength(2));
      final selection = await f.call('astoria_theme_select', {
        'themeId': 'synthetic-night',
      });
      expect(selection.content['code'], 'completed');
      expect(selection.content['effect'], 'persisted');
      expect(f.backing.activeId, 'synthetic-night');
      expect(
        f.container.read(themeProvider).activePreset.id,
        'synthetic-night',
      );
      final other = f.backing.presets.first;
      final mode = await f.call('astoria_theme_mode_set', {'mode': 'light'});
      expect(mode.content['code'], 'completed');
      expect(f.backing.presets.last.themeMode, 'light');
      expect(f.container.read(themeProvider).activePreset.themeMode, 'light');
      expect(f.backing.presets.first, other);
      expect(f.backing.checkedWrites, 2);
    },
  );

  appControlTest(
    'cancel during fresh theme observation starts no checked write',
    (f) async {
      f.backing.beforeFresh = () async => f.cancelToken.cancel();
      final result = await f.call('astoria_theme_select', {
        'themeId': 'synthetic-night',
      });
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(f.backing.checkedWrites, 0);
      expect(f.backing.activeId, 'default');
    },
  );

  appControlTest(
    'unknown theme is unavailable, never fabricated selection success',
    (f) async {
      final result = await f.call('astoria_theme_select', {
        'themeId': 'missing',
      });
      expect(result.content['ok'], isFalse);
      expect(result.content['code'], 'unavailable');
      expect(f.backing.checkedWrites, 0);
    },
  );
}
