import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_selection_test_store.dart';

/// Every declared field has a non-default synthetic value where possible.
/// Resource strings are inert canaries: no fixture reads files or contacts fonts.
const modeActive = ThemePreset(
  id: 'a',
  name: 'MODE_NAME_CANARY',
  author: 'Synthetic author',
  themeMode: 'dark',
  accentColor: '#123456',
  bgBlur: 7,
  elementOpacity: 0.63,
  elementBlur: 4,
  uiColor: '#102030',
  bgColor: '#203040',
  chatLayout: 'bubble',
  userBubbleColor: '#304050',
  charBubbleColor: '#405060',
  userBubbleGradient: '45|#112233|#445566',
  charBubbleGradient: '90|#223344|#556677',
  userQuoteColor: '#506070',
  charQuoteColor: '#607080',
  userTextColor: '#708090',
  charTextColor: '#8090A0',
  userItalicColor: '#90A0B0',
  charItalicColor: '#A0B0C0',
  uiFontSize: 16.5,
  uiFontWeight: 500,
  uiLetterSpacing: 0.3,
  chatFontSize: 18.5,
  userMessageFontWeight: 600,
  charMessageFontWeight: 700,
  chatLetterSpacing: 0.4,
  customFont: 'MODE_PRIVATE_FONT_CANARY',
  customFontName: 'Synthetic custom font',
  chatFont: 'MODE_PRIVATE_CHAT_FONT_CANARY',
  chatFontName: 'Synthetic chat font',
  googleFontName: 'Synthetic UI font',
  chatGoogleFontName: 'Synthetic chat google font',
  uiFontMode: 'custom',
  chatFontMode: 'custom',
  uiTextColor: '#B0C0D0',
  uiTextGrayColor: '#C0D0E0',
  borderWidth: 2,
  borderColor: '#D0E0F0',
  borderOpacity: 0.3,
  userBubbleRadius: 11,
  charBubbleRadius: 13,
  showUserAvatar: false,
  showCharAvatar: false,
  showUserName: false,
  showCharName: false,
  hideMessageId: true,
  hideGenerationTime: false,
  hideTokenCount: true,
  noiseOpacity: 0.08,
  noiseIntensity: 0.5,
  bgNoiseOpacity: 0.09,
  bgNoiseIntensity: 0.6,
  bgDim: 0.28,
  bgImage: 'MODE_PRIVATE_IMAGE_CANARY',
  chatBgMode: 'custom',
  chatBgColor: '#E0F010',
  chatBgImage: 'MODE_PRIVATE_CHAT_IMAGE_CANARY',
  textBgOpacity: 0.22,
);

Future<ThemeSelectionHarness> createModeHarness() =>
    ThemeSelectionHarness.create(
      ThemeSelectionBacking(presets: [selectionC, modeActive, selectionB]),
    );

extension ThemeModeHarness on ThemeSelectionHarness {
  Future<ThemeSelectionPlan> modePlan([String mode = 'light']) async {
    final read = await notifier.observeInstalledThemes(isCurrent: () => true);
    if (read.code != ThemeSelectionCode.ready) {
      throw StateError('Synthetic mode plan not ready: ${read.code}');
    }
    return read.observation!.planForMode(mode)!;
  }
}

List<ThemePreset> modeList(String mode) => [
  selectionC,
  modeActive.copyWith(themeMode: mode),
  selectionB,
];
