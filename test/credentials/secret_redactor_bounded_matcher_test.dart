import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_patterns.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';

import 'helpers/legacy_redaction_reference.dart';
import 'helpers/redaction_watchdog.dart';

String _fill(String block, int length) =>
    (block * ((length + block.length - 1) ~/ block.length)).substring(
      0,
      length,
    );

void main() {
  const removed = SecretRedactor.removed;
  const limited = SecretRedactor.limited;
  const unknown = 'SYNTHETIC_UNKNOWN';

  for (final length in [8192, 65536]) {
    for (final block in [
      'x',
      'a',
      'a.',
      'a-',
      'a+',
      'a1_',
      'a"',
      "a'",
      r'a\',
    ]) {
      test('original $length repeated $block remains intact', () async {
        final text = _fill(block, length);
        expect(await redactWithWatchdog([RedactionCase(text)]), [text]);
      });
    }

    test('original $length boundary named fields and URLs', () async {
      const suffixes = [
        ' password=SYNTHETIC_UNKNOWN',
        '.password=SYNTHETIC_UNKNOWN',
        '-password=SYNTHETIC_UNKNOWN',
        '+password=SYNTHETIC_UNKNOWN',
        ' "password"="SYNTHETIC_UNKNOWN"',
        ' \'password\'=\'SYNTHETIC_UNKNOWN\'',
        r'\password=SYNTHETIC_UNKNOWN',
        ' https://user:SYNTHETIC_UNKNOWN@provider.example/p?q=SYNTHETIC_UNKNOWN#SYNTHETIC_UNKNOWN',
      ];
      final cases = <RedactionCase>[];
      final expected = <String>[];
      for (final suffix in suffixes) {
        final prefix = 'a' * (length - suffix.length);
        cases.add(RedactionCase('$prefix$suffix'));
        if (suffix.startsWith('.') || suffix.startsWith('-')) {
          expected.add('$prefix${suffix[0]}password="$removed"');
        } else if (suffix.startsWith('+')) {
          expected.add('$prefix+password="$removed"');
        } else if (suffix.contains('https://')) {
          expected.add('$prefix https://provider.example/p');
        } else if (suffix.startsWith(r'\')) {
          expected.add('$prefix\\password="$removed"');
        } else if (suffix.contains('"password"')) {
          expected.add('$prefix "password"="$removed"');
        } else if (suffix.contains("'password'")) {
          expected.add("$prefix 'password'=\"$removed\"");
        } else {
          expected.add('$prefix password="$removed"');
        }
      }
      expect(await redactWithWatchdog(cases), expected);
    });

    test('original $length long known literal near-matches', () async {
      final cases = <RedactionCase>[];
      for (final block in ['a', 'a.', 'a-', 'a+', 'a1_', r'a"\']) {
        cases.add(
          RedactionCase(
            _fill(block, length),
            knownSecrets: ['${_fill(block, length ~/ 2)}b'],
          ),
        );
      }
      expect(
        await redactWithWatchdog(cases),
        cases.map((c) => c.text).toList(),
      );
    });
  }

  test('full 256-secret policy bounds repeated near-match input', () async {
    final text = 'a' * 65536;
    final known = List.generate(
      256,
      (index) => '${'a' * 128}${index.toString().padLeft(3, '0')}b',
    );
    expect(
      await redactWithWatchdog([RedactionCase(text, knownSecrets: known)]),
      [text],
    );
  });

  test(
    'long known matches, field names and URL paths remain covered',
    () async {
      final long = '${'a' * 32768}b';
      final prefix = 'a' * 32767;
      final name = '${'x.' * 30000}password';
      final url = 'https://user:$unknown@provider.example/$long?q=$unknown#x';
      expect(
        await redactWithWatchdog([
          RedactionCase('${'a' * 65535}b', knownSecrets: [long]),
          RedactionCase('$name=$unknown'),
          RedactionCase(url, knownSecrets: [long], url: true),
          RedactionCase('failed $url', knownSecrets: [long]),
        ]),
        [
          '$prefix$removed',
          '$name="$removed"',
          'https://provider.example/${Uri.encodeComponent(removed)}',
          'failed https://provider.example/${Uri.encodeComponent(removed)}',
        ],
      );
    },
  );

  test(
    'complete long schemes redact rather than retrying their suffixes',
    () async {
      final cases = <RedactionCase>[];
      for (final block in ['a', 'a.', 'a-', 'a+']) {
        const tail =
            '://user:SYNTHETIC_UNKNOWN@provider.example?q=SYNTHETIC_UNKNOWN';
        cases.add(RedactionCase('${_fill(block, 65536 - tail.length)}$tail'));
      }
      expect(
        await redactWithWatchdog(cases),
        List.filled(cases.length, removed),
      );
    },
  );

  test(
    'long quotes, escaped quotes and missing terminators retain coverage',
    () async {
      final value = _fill(r'a\"', 60000);
      final cases = [
        RedactionCase('password="$value"'),
        RedactionCase("password='$value'"),
        RedactionCase('password="$value'),
        RedactionCase('message="$value"'),
        RedactionCase('message="$value'),
      ];
      expect(await redactWithWatchdog(cases), [
        'password="$removed"',
        'password="$removed"',
        'password="$removed"',
        'message="$value"',
        'message="$value',
      ]);
    },
  );

  test(
    'default input/output bounds remain inclusive with late credentials',
    () async {
      final cases = <RedactionCase>[];
      final expected = <String>[];
      const tail = ' password="[REDACTED]"';
      for (final outputLength in [8191, 8192, 8193]) {
        final prefix = 'a' * (outputLength - tail.length);
        cases.add(
          RedactionCase(
            '$prefix password=${'x' * 20000}',
            maxOutputLength: 8192,
          ),
        );
        expected.add(outputLength <= 8192 ? '$prefix$tail' : limited);
      }
      cases.addAll([
        RedactionCase('a' * 8192, maxOutputLength: 8192),
        RedactionCase('a' * 65536, maxOutputLength: 8192),
        RedactionCase('a' * 65537),
        RedactionCase('password=${'x' * (65536 - 'password='.length)}'),
      ]);
      expected.addAll(['a' * 8192, limited, limited, 'password="$removed"']);
      expect(await redactWithWatchdog(cases), expected);
      final defaults = SecretRedactor();
      expect(defaults.maxInputLength, 65536);
      expect(defaults.maxOutputLength, 8192);
      expect(defaults.maxDepth, 12);
      expect(defaults.maxNodes, 512);
    },
  );

  test(
    'known literals retain variants, case, overlap and original markers',
    () {
      const canary = 'Synthetic_🔐_"\\_Value';
      final redactor = SecretRedactor(knownSecrets: [canary]);
      for (final value in {
        canary,
        Uri.encodeComponent(canary),
        Uri.encodeFull(canary),
        jsonEncode(canary).substring(1, jsonEncode(canary).length - 1),
        base64Encode(utf8.encode(canary)),
        base64UrlEncode(utf8.encode(canary)),
      }) {
        expect(redactor.redactText('literal $value'), 'literal $removed');
      }
      expect(redactor.redactText(canary.toLowerCase()), canary.toLowerCase());
      final overlaps = SecretRedactionPatterns([
        'aaa',
        'aa',
        'a',
        removed,
        'R',
      ], 65536);
      expect(overlaps.replaceKnown('aaaaa'), '$removed$removed');
      expect(overlaps.replaceKnown('R $removed'), '$removed $removed');
      expect(
        overlaps.replaceText('password=$unknown message="R"', (_) => removed),
        'p${removed}ssword="$removed" mess${removed}ge="$removed"',
      );
      final all = List.generate(
        256,
        (i) => 'SyntheticKnown${i.toString().padLeft(3, '0')}!',
      );
      final every = SecretRedactor(knownSecrets: all);
      expect(
        every.redactText(all.join(' ')),
        List.filled(256, removed).join(' '),
      );
      expect(every.withKnownSecrets(['overflow']).redactText('safe'), limited);
    },
  );

  test(
    'field suffixes and misleading partial names keep historical policy',
    () {
      final redactor = SecretRedactor();
      for (final name in [
        '1password',
        '.password',
        '-password',
        'api.keynote',
        'ses.sion-id',
        'access.tokenized',
      ]) {
        expect(redactor.redactText('$name=$unknown'), '$name="$removed"');
      }
      for (final name in ['tok', 'author', 'session', 'pass', 'api']) {
        expect(redactor.redactText('$name=$unknown'), '$name=$unknown');
      }
      for (final text in [
        'id__https://provider.example/path',
        '9https://provider.example/path',
      ]) {
        expect(redactor.redactText(text), text);
      }
      expect(
        redactor.redactText('id__x.https://provider.example?q=$unknown'),
        'id__x.https://provider.example',
      );
      expect(
        redactor.redactText('AUTHORIZATION: bEaReR $unknown\nkept'),
        'Authorization: $removed\nkept',
      );
      expect(
        redactor.redactText(
          'HTTPS://user:$unknown@provider.example/path?q=$unknown#x',
        ),
        'https://provider.example/path',
      );
    },
  );

  test('nested JSON, JSON-in-JSON, cycles and budgets do not reset', () {
    final redactor = SecretRedactor(knownSecrets: ['REDACTED']);
    final input = {
      'label': 'a' * 8192,
      'nested': [
        {'ses.sion-id': unknown, 'tok': unknown},
        {'message': 'password=$unknown'},
        {'endpoint': 'https://user:$unknown@provider.example/p?q=$unknown'},
      ],
    };
    // The default whole-container/output budget still fails closed.
    expect(redactor.redactJson(input), limited);
    final wide = redactor.withKnownSecrets(const [], maxOutputLength: 65536);
    final expected = {
      'label': 'a' * 8192,
      'nested': [
        {'ses.sion-id': removed, 'tok': unknown},
        {'message': 'password="$removed"'},
        {'endpoint': 'https://provider.example/p'},
      ],
    };
    expect(wide.redactJson(input), expected);
    expect(jsonDecode(wide.redactText(jsonEncode(input))), expected);
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    expect(wide.redactJson(cyclic), [limited]);
    final shallow = wide.withKnownSecrets(const [], maxDepth: 1, maxNodes: 3);
    expect(
      shallow.redactJson([
        [
          ['safe'],
        ],
      ]),
      [
        [limited],
      ],
    );
    expect(shallow.redactJson(List.filled(4, 'safe')), limited);
    expect(
      wide.redactJson({
        'message': jsonEncode({'password': unknown}),
      }),
      {'message': '{"password":"$removed"}'},
    );
  });

  test(
    'small frozen pre-fix oracle preserves candidate priority and boundaries',
    () {
      final random = Random(81265536);
      const pieces = [
        'a',
        '1',
        '_',
        '.',
        '-',
        '+',
        '"',
        "'",
        r'\',
        ' ',
        ':',
        '=',
        ',',
        ';',
        'password',
        'message',
        'Authorization',
        'Bearer',
        'Basic',
        'https',
        '://provider.example/p?q=x',
        'sk-abcdefgh',
        'github_pat_abcdefghijklmnopqrstuv',
        'eyJx.x.x',
        'R',
        'REDACTED',
        'SyntheticKnown42',
        '\n',
      ];
      const policies = <List<String>>[
        [],
        ['R', 'REDACTED'],
        ['a', 'aa', 'aaa'],
        ['SyntheticKnown42', 'password'],
        ['https', '.', '"', r'\'],
      ];
      for (var iteration = 0; iteration < 250; iteration++) {
        // Prefix prevents valid JSON dispatch: this oracle is the plain matcher.
        final text =
            'prose ${List.generate(12, (_) => pieces[random.nextInt(pieces.length)]).join()}';
        expect(text.length, lessThan(512));
        final known = policies[iteration % policies.length];
        expect(
          SecretRedactor(knownSecrets: known).redactText(text),
          legacyRedactPlain(text, known),
          reason: 'deterministic original-priority fixture $iteration',
        );
      }
    },
  );
}
