import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Only these two explicitly declared PUBLIC source assets are read. No app,
  // platform, provider, runtime settings, credential store or default database.
  final locales = <String, Map<String, dynamic>>{
    for (final language in ['en', 'ru'])
      language:
          jsonDecode(
                File('assets/translations/$language.json').readAsStringSync(),
              )
              as Map<String, dynamic>,
  };
  final englishKeys = locales['en']!.keys
      .where((key) => key.startsWith('support_provider_'))
      .toSet();
  test(
    'native provider English/Russian keys match and contain no empty copy',
    () {
      expect(englishKeys.length, greaterThanOrEqualTo(80));
      for (final locale in locales.values) {
        expect(
          locale.keys
              .where((key) => key.startsWith('support_provider_'))
              .toSet(),
          englishKeys,
        );
        for (final key in englishKeys) {
          expect(locale[key], isA<String>(), reason: key);
          expect((locale[key] as String).trim(), isNotEmpty, reason: key);
        }
      }
    },
  );
  test(
    'copy separates key custody, active/default selection and verification',
    () {
      expect(
        locales['en']!['support_provider_key_notice'],
        contains('tool arguments'),
      );
      expect(
        locales['ru']!['support_provider_key_notice'],
        contains('аргументы инструментов'),
      );
      expect(
        locales['en']!['support_provider_no_assignment'],
        contains('fallback'),
      );
      expect(
        locales['ru']!['support_provider_no_assignment'],
        contains('по умолчанию'),
      );
      for (final locale in locales.values) {
        expect(
          locale['support_provider_scope_notice'],
          isNot(locale['support_provider_key_notice']),
        );
        expect(
          locale['support_provider_unverified'],
          isNot(locale['support_provider_key_saved']),
        );
      }
    },
  );
}
