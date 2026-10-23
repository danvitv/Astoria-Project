import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['en', 'ru']) {
    test(
      '$language mode copy separates field-only approval and passive history',
      () {
        // Only these declared public repository sources are read; no app bootstrap,
        // preference plugin, runtime path, credential storage or network is used.
        final copy =
            jsonDecode(
                  File('assets/translations/$language.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        for (final key in [
          'support_theme_mode_title',
          'support_theme_mode_dark',
          'support_theme_mode_light',
          'support_theme_mode_system',
          'support_theme_mode_preserves_fields',
          'support_theme_mode_exact_review',
          'support_theme_history_kind_selection',
          'support_theme_history_kind_mode',
          'support_theme_mode_history_notice',
        ]) {
          expect(copy[key], isA<String>());
          expect((copy[key] as String).trim(), isNotEmpty);
        }
        final review = copy['support_theme_mode_exact_review'] as String;
        expect(review, contains('Undo'));
        expect(review, isNot(copy['support_theme_exact_review']));
        final history = copy['support_theme_mode_history_notice'] as String;
        expect(history, contains('Undo'));
        expect(
          copy['support_theme_history_kind_mode'],
          isNot(copy['support_theme_history_kind_selection']),
        );
        expect(
          {
            for (final mode in ['dark', 'light', 'system'])
              copy['support_theme_mode_$mode'],
          },
          hasLength(3),
        );
      },
    );
  }
}
