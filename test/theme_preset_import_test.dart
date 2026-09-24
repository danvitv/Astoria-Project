import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';

void main() {
  late ThemePresetStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = ThemePresetStorage(await SharedPreferences.getInstance());
  });

  test('upgrades only the untouched Glaze default theme', () async {
    const oldDefault = ThemePreset(
      id: 'default',
      name: 'Default',
      accentColor: '#7996CE',
      bgDim: 0.15,
      noiseOpacity: 0.03,
      noiseIntensity: 0.8,
      bgNoiseOpacity: 0.03,
      bgNoiseIntensity: 0.4,
    );
    await storage.saveAll([oldDefault.copyWith(accentColor: '#7996ce')]);

    final upgraded = (await storage.loadAll()).first;
    expect(upgraded.accentColor, '#F5C400');

    // This is how the old Windows preferences serialized the stock preset.
    final oldJson = oldDefault.copyWith(accentColor: '#7996ce').toJson()
      ..['bgDim'] = 0.0
      ..['bgOpacity'] = 0.85;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_presets', jsonEncode([oldJson]));
    expect((await storage.loadAll()).first.accentColor, '#F5C400');

    await storage.saveAll([oldDefault.copyWith(accentColor: '#B77F96')]);
    expect((await storage.loadAll()).first.accentColor, '#F5C400');

    await storage.saveAll([oldDefault.copyWith(accentColor: '#123456')]);
    final custom = (await storage.loadAll()).first;
    expect(custom.accentColor, '#123456');

    await storage.saveAll([
      oldDefault.copyWith(accentColor: '#7996ce', uiFontWeight: 600),
    ]);
    final customizedDefault = (await storage.loadAll()).first;
    expect(customizedDefault.accentColor, '#7996ce');
    expect(customizedDefault.uiFontWeight, 600);
  });

  test('stock colors keep gold readable in both modes', () async {
    final preset = (await storage.loadAll()).first;
    expect(preset.accentColor, '#F5C400');
    final dark = AppTheme.dark(preset);
    final light = AppTheme.light(preset);
    final darkChat = GlazeColors.fromPreset(preset, isDark: true);
    final lightChat = GlazeColors.fromPreset(preset, isDark: false);
    expect(dark.colorScheme.primary, const Color(0xFFF5C400));
    expect(light.colorScheme.primary, const Color(0xFF8A6900));
    expect(darkChat.userBubble, const Color(0xFFF5C400));
    expect(lightChat.userBubble, const Color(0xFFF5C400));
    expect(darkChat.userText, const Color(0xFF1A1A1B));
    expect(lightChat.userText, const Color(0xFF1A1A1B));
    expect(darkChat.userQuote, darkChat.accent);
    expect(lightChat.userQuote, lightChat.accent);
    expect(dark.colorScheme.surface, const Color(0xFF101010));
    expect(dark.colorScheme.surfaceContainerHighest, const Color(0xFF313131));
    final bubbleChat = GlazeColors.fromPreset(
      preset.copyWith(chatLayout: 'bubble'),
      isDark: true,
    );
    expect(bubbleChat.userQuote, bubbleChat.userText);
    expect(light.colorScheme.primary, isNot(equals(dark.colorScheme.primary)));

    final custom = preset.copyWith(
      userBubbleColor: '#333333',
      userTextColor: '#E1E3E6',
    );
    final customChat = GlazeColors.fromPreset(custom, isDark: true);
    expect(customChat.userBubble, const Color(0xFF333333));
    expect(customChat.userQuote, customChat.accent);
  });

  test('imports a SillyTavern theme', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'name': 'Yellow',
        'main_text_color': 'rgba(253, 253, 253, 1)',
        'italics_text_color': 'rgba(252, 247, 137, 1)',
        'quote_text_color': 'rgba(255, 250, 107, 1)',
        'blur_tint_color': 'rgba(11, 10, 10, 0.65)',
        'user_mes_blur_tint_color': 'rgba(252, 233, 233, 0)',
        'bot_mes_blur_tint_color': 'rgba(224, 224, 219, 0)',
        'border_color': 'rgba(160, 157, 72, 0.51)',
        'blur_strength': 4,
        'hideChatAvatars_enabled': true,
        'mesIDDisplay_enabled': false,
        'message_token_count_enabled': true,
      }),
    );

    expect(preset.name, 'Yellow');
    expect(preset.author, 'SillyTavern');
    expect(preset.accentColor, '#FFFA6B');
    expect(preset.uiColor, '#0B0A0A');
    expect(preset.elementOpacity, 0.65);
    expect(preset.elementBlur, 4);
    expect(preset.showUserAvatar, isFalse);
    expect(preset.showCharAvatar, isFalse);
    expect(preset.hideMessageId, isTrue);
    expect(preset.hideTokenCount, isFalse);
  });

  test('imports portable Moonlit Echoes settings', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'moonlitEchoesPreset': true,
        'presetName': 'Glimmer',
        'settings': {
          'customThemeColor': 'rgba(204, 204, 0, 1)',
          'customThemeColor2': 'rgba(255, 255, 255, 1)',
          'customTopBarColor': 'rgba(30, 30, 30, 1)',
          'customBgColor1': 'rgba(255, 255, 255, 0.1)',
          'customBgColor2': 'rgba(255, 255, 255, 0.05)',
          'sheldBackgroundColor': 'rgba(0, 0, 0, 0.21)',
          'sheldBlurStrength': '8',
          'messageTextFontSize': '15px',
          'rawCustomCss': 'body { display: none; }',
        },
      }),
    );

    expect(preset.name, 'Glimmer');
    expect(preset.author, 'Moonlit Echoes');
    expect(preset.accentColor, '#CCCC00');
    expect(preset.uiColor, '#1E1E1E');
    expect(preset.elementOpacity, 0.21);
    expect(preset.elementBlur, 8);
    expect(preset.chatFontSize, 15);
    expect(preset.toJson(), isNot(contains('rawCustomCss')));
  });

  test('rejects a non-object root as a format error', () async {
    await expectLater(
      storage.importFromJson('[]'),
      throwsA(isA<FormatException>()),
    );
  });
}
