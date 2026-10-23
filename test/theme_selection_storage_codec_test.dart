import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';
import 'package:glaze_flutter/shared/theme/theme_selection_storage_codec.dart';

void main() {
  test(
    'known legacy omissions migrate while retaining full installed content',
    () {
      final preset = decodeThemeSelectionPresets([
        {
          'id': 'custom',
          'name': 'Custom',
          'bgOpacity': 0.85,
          'customFont': 'FONT_CANARY',
          'bgImage': 'IMAGE_CANARY',
          'chatFontSize': 17.5,
          'hideMessageId': true,
        },
      ]).single;
      expect(preset.bgDim, closeTo(0.15, 1e-9));
      expect(preset.customFont, 'FONT_CANARY');
      expect(preset.bgImage, 'IMAGE_CANARY');
      expect(preset.chatFontSize, 17.5);
      expect(preset.hideMessageId, isTrue);
      expect(decodeThemeSelectionPresets([preset.toJson()]).single, preset);
    },
  );

  for (final (index, malformed) in <Object?>[
    null,
    <String, Object?>{},
    '[]',
    [null],
    [3],
    [<String, Object?>{}],
    [
      {'id': 'a', 'name': 42},
    ],
    [
      {'id': 'a', 'name': 'A', 'accentColor': null},
    ],
    [
      {'id': 'a', 'name': 'A', 'bgBlur': '12'},
    ],
    [
      {'id': 'a', 'name': 'A', 'uiFontSize': <String, Object?>{}},
    ],
    [
      {'id': 'a', 'name': 'A', 'chatFontSize': <Object?>[]},
    ],
    [
      {'id': 'a', 'name': 'A', 'customFont': 42},
    ],
    [
      {'id': 'a', 'name': 'A', 'uiFontWeight': 400.5},
    ],
    [
      {'id': 'a', 'name': 'A', 'showUserAvatar': null},
    ],
    [
      {'id': 'a', 'name': 'A', 'hideMessageId': 'true'},
    ],
    [
      {'id': 'a', 'name': 'A', 'bgBlur': double.infinity},
    ],
    [
      {'id': 'a', 'name': 'A', 'bgOpacity': double.nan},
    ],
    [
      {'id': 'a', 'name': 'A', 'unknownStoredField': 'SECRET_CANARY'},
    ],
  ].indexed) {
    test('malformed stored projection $index denies without fallback', () {
      expect(
        () => decodeThemeSelectionPresets(malformed),
        throwsA(isA<ThemeSelectionInvalidStorage>()),
      );
    });
  }

  for (final (index, invalid) in <({List<ThemePreset> presets, String active})>[
    (presets: [], active: 'default'),
    (presets: [const ThemePreset(id: '', name: 'A')], active: ''),
    (presets: [const ThemePreset(id: 'a', name: 'A')], active: 'missing'),
    (
      presets: [
        const ThemePreset(id: 'a', name: 'A'),
        const ThemePreset(id: 'a', name: 'Duplicate'),
      ],
      active: 'a',
    ),
    (
      presets: [const ThemePreset(id: 'a', name: 'A', accentColor: 'oops')],
      active: 'a',
    ),
    (
      presets: [ThemePreset(id: 'a', name: 'A', uiFontSize: <String>[])],
      active: 'a',
    ),
  ].indexed) {
    test('invalid active/list/content projection $index denies', () {
      expect(
        () => ThemeSelectionStoredState(
          presets: invalid.presets,
          activeId: invalid.active,
        ),
        throwsA(isA<ThemeSelectionInvalidStorage>()),
      );
    });
  }

  test('strict state snapshots list membership immutably', () {
    final source = [const ThemePreset(id: 'a', name: 'A')];
    final state = ThemeSelectionStoredState(presets: source, activeId: 'a');
    source.clear();
    expect(state.active.id, 'a');
    expect(() => state.presets.clear(), throwsUnsupportedError);
    expect(
      const ThemeSelectionInvalidStorage().toString(),
      'ThemeSelectionInvalidStorage',
    );
  });
}
