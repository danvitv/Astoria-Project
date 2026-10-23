import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

// Pure synthetic metadata only. No App, DB, provider, native bootstrap, vault,
// socket, filesystem, process, actual model, default ports or environment.
void main() {
  group('dedicated encrypted-storage codec', () {
    test('known v1 roundtrip retains identities, ranges and direct runs', () {
      final fixture = _DagFixture();
      final encoded = _encode(fixture.second);
      final decoded = _decode(encoded);
      expect(decoded.isValid, isTrue);
      final recipe = decoded.recipe!;
      expect(recipe.supportSessionId, 'support');
      expect(recipe.replyMessageId, 'b-reply');
      expect(recipe.runId, 'b-run');
      expect(recipe.currentUserMessageId, 'b-user');
      expect(recipe.originalRanges[0].orderedMessageIds, [
        'legacy',
        'a-user',
        'a-reply',
      ]);
      expect(recipe.originalRanges[1].domain, SupportModelSourceDomain.game);
      expect(recipe.originalRanges[1].orderedMessageIds, ['g0', 'g2']);
      expect(recipe.directReplies.single.runId, 'a-run');
      expect(_encode(recipe), encoded);
      final keys = (jsonDecode(encoded) as Map<String, dynamic>).keys;
      expect(
        keys,
        unorderedEquals([
          'marker',
          'version',
          'supportSessionId',
          'replyMessageId',
          'runId',
          'currentUserMessageId',
          'originalRanges',
          'directReplies',
        ]),
      );
      expect(encoded, isNot(contains('Approval')));
      expect(encoded, isNot(contains('body')));
      expect(encoded, isNot(contains('fingerprint')));
    });

    test('current-only recipe is valid without inventing source rights', () {
      final recipe = _recipe();
      expect(_decode(_encode(recipe)).isValid, isTrue);
      expect(_verify(recipe).isValid, isTrue);
      expect(recipe.originalRanges, isEmpty);
      expect(recipe.directReplies, isEmpty);
    });

    test(
      'all known keys are mandatory and unknown keys rejected at each level',
      () {
        final base = _wire(_DagFixture().second);
        for (final key in base.keys) {
          final missing = Map<String, dynamic>.of(base)..remove(key);
          expect(_decode(jsonEncode(missing)).isValid, isFalse, reason: key);
        }
        for (final key in [
          'nativeCurrentTurnApproval',
          'body',
          'headers',
          'hash',
          'url',
        ]) {
          final extra = Map<String, dynamic>.of(base)..[key] = true;
          expect(
            _decode(jsonEncode(extra)).failure,
            SupportModelProvenanceFailure.unknownField,
          );
        }
        final rangeExtra = _wire(_DagFixture().second);
        (rangeExtra['originalRanges'] as List).first['permission'] = true;
        expect(
          _decode(jsonEncode(rangeExtra)).failure,
          SupportModelProvenanceFailure.unknownField,
        );
        final refExtra = _wire(_DagFixture().second);
        (refExtra['directReplies'] as List).first['authority'] = true;
        expect(
          _decode(jsonEncode(refExtra)).failure,
          SupportModelProvenanceFailure.unknownField,
        );
      },
    );

    test('unknown marker/version/type never defaults to a clean recipe', () {
      for (final value in [
        0,
        2,
        '1',
        1.0,
        null,
        true,
        <String, Object?>{},
        <Object?>[],
      ]) {
        final wire = _wire(_recipe())..['version'] = value;
        expect(
          _decode(jsonEncode(wire)).failure,
          SupportModelProvenanceFailure.unsupportedFormat,
        );
      }
      for (final value in ['', 'legacy', null, 1, false]) {
        final wire = _wire(_recipe())..['marker'] = value;
        expect(
          _decode(jsonEncode(wire)).failure,
          SupportModelProvenanceFailure.unsupportedFormat,
        );
      }
      for (final key in [
        'supportSessionId',
        'replyMessageId',
        'runId',
        'currentUserMessageId',
      ]) {
        for (final value in [
          null,
          1,
          false,
          <String, Object?>{},
          <Object?>[],
        ]) {
          final wire = _wire(_recipe())..[key] = value;
          expect(_decode(jsonEncode(wire)).isValid, isFalse);
        }
      }
      for (final raw in ['', 'null', '[]', '"legacy"']) {
        expect(_decode(raw).isValid, isFalse);
      }
    });

    test(
      'duplicate escaped-equivalent keys rejected BEFORE decode overwrite',
      () {
        final encoded = _encode(_recipe());
        for (final injected in [
          '"runId":"other","runId":"run",',
          '"runId":"other","r\\u0075nId":"run",',
          '"\\u0072unId":"other","runId":"run",',
        ]) {
          final raw = encoded.replaceFirst('"runId":"run",', injected);
          expect(
            _decode(raw).failure,
            SupportModelProvenanceFailure.duplicateKey,
          );
        }
        final fixture = _encode(_DagFixture().second);
        final nested = fixture.replaceFirst(
          '"domain":"support",',
          '"domain":"game","do\\u006dain":"support",',
        );
        expect(
          _decode(nested).failure,
          SupportModelProvenanceFailure.duplicateKey,
        );
        final reference = fixture.replaceFirst(
          '"messageId":"a-reply",',
          '"messageId":"other","message\\u0049d":"a-reply",',
        );
        expect(
          _decode(reference).failure,
          SupportModelProvenanceFailure.duplicateKey,
        );
        // Even an otherwise unknown subtree cannot hide duplicate keys.
        final unknown = encoded.replaceFirst(
          '{',
          '{"extra":{"x":1,"\\u0078":2},',
        );
        expect(
          _decode(unknown).failure,
          SupportModelProvenanceFailure.duplicateKey,
        );
      },
    );

    test(
      'malformed grammar, trailing values, numbers and escapes are unavailable',
      () {
        for (final raw in [
          '{',
          '[1,]',
          '{"x":1,}',
          '{"x":01}',
          '{"x":1.}',
          '{"x":1e}',
          '{"x":-}',
          '{"x":+1}',
          '{"x":NaN}',
          '{"x":"\\q"}',
          '{"x":"\\u00XZ"}',
          '{"x":"unfinished}',
          '{"x":true false}',
          '${_encode(_recipe())} null',
          '{"x":"line\nbreak"}',
        ]) {
          expect(
            _decode(raw).failure,
            SupportModelProvenanceFailure.invalidEncoding,
          );
        }
      },
    );

    test('Unicode scalar identities and escaped quote/backslash roundtrip', () {
      for (final id in ['é', 'кот', 'row-🐈', 'a"b', r'a\b']) {
        final recipe = _recipe(user: id);
        expect(_decode(_encode(recipe)).recipe!.currentUserMessageId, id);
      }
      final escaped = _encode(
        _recipe(),
      ).replaceFirst('"runId":"run"', '"runId":"\\u0072un"');
      expect(_decode(escaped).recipe!.runId, 'run');
      final surrogatePair = _encode(
        _recipe(),
      ).replaceFirst('"runId":"run"', '"runId":"\\ud83d\\udc08"');
      expect(_decode(surrogatePair).recipe!.runId, '🐈');
    });

    test(
      'lone/mixed surrogates and control/whitespace IDs fail without echo',
      () {
        for (final rawId in [
          r'\ud800',
          r'\udfff',
          r'\ud800x',
          r'\ud800\u0061',
        ]) {
          final raw = _encode(_recipe()).replaceFirst('"run"', '"$rawId"');
          expect(
            _decode(raw).failure,
            SupportModelProvenanceFailure.invalidEncoding,
          );
        }
        for (final id in [
          '',
          ' a',
          'a ',
          'a\nb',
          'a\u0000b',
          'a\u007fb',
          'a\u00a0b',
          'a\u200bb',
          'a\u202eb',
          'a\ufeffb',
          String.fromCharCode(0xd800),
          String.fromCharCode(0xdc00),
        ]) {
          expect(
            () => _recipe(user: id),
            _failure(SupportModelProvenanceFailure.invalidIdentity),
          );
        }
        final rawSurrogate = _encode(
          _recipe(),
        ).replaceFirst('"run"', '"${String.fromCharCode(0xd800)}"');
        expect(
          _decode(rawSurrogate).failure,
          SupportModelProvenanceFailure.invalidEncoding,
        );
      },
    );

    test('identity boundaries, exact ownership and unique source IDs', () {
      expect(_recipe(user: 'a' * 128).currentUserMessageId.length, 128);
      expect(
        () => _recipe(user: 'a' * 129),
        _failure(SupportModelProvenanceFailure.invalidIdentity),
      );
      expect(
        () => _recipe(user: 'reply'),
        _failure(SupportModelProvenanceFailure.invalidIdentity),
      );
      expect(
        () => _support([]),
        _failure(SupportModelProvenanceFailure.invalidSource),
      );
      expect(
        () => _support(['same', 'same']),
        _failure(SupportModelProvenanceFailure.invalidSource),
      );
      expect(
        () => _recipe(
          ranges: [
            _support(['a']),
            _support(['b']),
          ],
        ),
        _failure(SupportModelProvenanceFailure.invalidSource),
      );
      expect(
        () => _recipe(
          refs: [
            _ref('a'),
            _ref('a', run: 'other'),
          ],
        ),
        _failure(SupportModelProvenanceFailure.invalidSource),
      );
      // Domain/session names are exact, never ID-only aliases.
      expect(
        _recipe(
          ranges: [
            _support(['a']),
            _game(['a']),
          ],
        ).originalRanges.length,
        2,
      );
    });

    test('strict range/reference field types and unknown source domains', () {
      for (final value in ['allHistory', 'Support', 1, null, true]) {
        final wire = _wire(_DagFixture().first);
        (wire['originalRanges'] as List).first['domain'] = value;
        expect(
          _decode(jsonEncode(wire)).failure,
          SupportModelProvenanceFailure.invalidSource,
        );
      }
      for (final value in [
        null,
        <String, Object?>{},
        'a',
        [1],
        [null],
        ['same', 'same'],
        <Object?>[],
      ]) {
        final wire = _wire(_DagFixture().first);
        (wire['originalRanges'] as List).first['orderedMessageIds'] = value;
        expect(_decode(jsonEncode(wire)).isValid, isFalse);
      }
      for (final value in [
        null,
        <String, Object?>{},
        'a',
        [1],
      ]) {
        final wire = _wire(_recipe())..['directReplies'] = value;
        expect(_decode(jsonEncode(wire)).isValid, isFalse);
      }
      for (final key in ['sessionId', 'messageId', 'runId']) {
        final wire = _wire(_DagFixture().second);
        (wire['directReplies'] as List).first[key] = null;
        expect(_decode(jsonEncode(wire)).isValid, isFalse);
      }
    });

    test('raw size limit is inclusive and checked before schema/decode', () {
      final encoded = _encode(_recipe());
      final atLimit = encoded + ' ' * (65536 - encoded.length);
      expect(_decode(atLimit).isValid, isTrue);
      expect(
        _decode('$atLimit ').failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      expect(
        _decode('x' * 65537).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
    });

    test('depth, JSON node, key and array caps apply before construction', () {
      final atDepth = '${'[' * 24}0${']' * 24}';
      expect(
        _decode(atDepth).failure,
        SupportModelProvenanceFailure.invalidEncoding,
      );
      expect(
        _decode('[$atDepth]').failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      final manyNodes =
          '[${List.filled(64, '[${List.filled(128, '0').join(',')}]').join(',')}]';
      expect(
        _decode(manyNodes).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      final longArray = '[${List.filled(513, '0').join(',')}]';
      expect(
        _decode(longArray).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      final manyKeys = '{${List.generate(129, (i) => '"k$i":0').join(',')}}';
      expect(
        _decode(manyKeys).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
    });

    test('512 IDs per source and 128 combined declarations/references', () {
      final ids = List.generate(512, (i) => 'm$i');
      expect(_support(ids).orderedMessageIds.length, 512);
      expect(
        () => _support([...ids, 'overflow']),
        _failure(SupportModelProvenanceFailure.limitExceeded),
      );
      final ranges = List.generate(128, (i) => _game(['m'], session: 's$i'));
      expect(_decode(_encode(_recipe(ranges: ranges))).isValid, isTrue);
      expect(
        () => _recipe(ranges: ranges, refs: [_ref('a')]),
        _failure(SupportModelProvenanceFailure.limitExceeded),
      );
      final wire = _wire(_recipe())
        ..['directReplies'] = List.generate(
          129,
          (i) => {'sessionId': 'support', 'messageId': 'm$i', 'runId': 'r$i'},
        );
      expect(
        _decode(jsonEncode(wire)).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
    });

    test(
      'total source occurrence budget and encoded raw budget are bounded',
      () {
        final ranges = List.generate(
          8,
          (i) => _game(List.generate(512, (j) => 'm$j'), session: 's$i'),
        );
        expect(_recipe(ranges: ranges).originalRanges.length, 8);
        expect(_decode(_encode(_recipe(ranges: ranges))).isValid, isTrue);
        expect(
          _verify(_recipe(ranges: ranges), ranges: ranges).isValid,
          isTrue,
        );
        expect(
          () => _recipe(
            ranges: [
              ...ranges,
              _game(['extra'], session: 's9'),
            ],
          ),
          _failure(SupportModelProvenanceFailure.limitExceeded),
        );
        final large = _recipe(
          ranges: [_game(List.generate(512, (i) => '${'x' * 124}$i'))],
        );
        expect(
          () => _encode(large),
          _failure(SupportModelProvenanceFailure.limitExceeded),
        );
      },
    );

    test(
      'every public list is defensive and immutable, diagnostics do not echo',
      () {
        final ids = ['history'];
        final range = _support(ids);
        final ranges = [range];
        final refs = [_ref('old')];
        final recipe = _recipe(ranges: ranges, refs: refs);
        ids.add('later');
        ranges.clear();
        refs.clear();
        expect(recipe.originalRanges.single.orderedMessageIds, ['history']);
        expect(recipe.directReplies.single.messageId, 'old');
        expect(() => range.orderedMessageIds.add('no'), throwsUnsupportedError);
        expect(() => recipe.originalRanges.clear(), throwsUnsupportedError);
        expect(() => recipe.directReplies.clear(), throwsUnsupportedError);
        final decoded = _decode(_encode(recipe)).recipe!;
        expect(
          () => decoded.originalRanges.single.orderedMessageIds.clear(),
          throwsUnsupportedError,
        );
        expect(() => decoded.directReplies.clear(), throwsUnsupportedError);
        expect(recipe.toString(), 'SupportModelProvenance');
        expect(range.toString(), 'SupportModelSourceRange');
        expect(
          recipe.directReplies.single.toString(),
          'SupportModelReplyReference',
        );
        final failure = _decode('{"sentinel-secret":');
        expect(failure.toString(), 'SupportModelProvenanceDecodeResult');
        try {
          _recipe(user: 'sentinel-secret\n');
          fail('invalid identity accepted');
        } on SupportModelProvenanceException catch (error) {
          expect(error.toString(), 'Support model provenance unavailable.');
          expect(error.toString(), isNot(contains('sentinel')));
        }
      },
    );
  });

  group('conjunctive selected metadata lineage, not approval', () {
    test(
      'identities stay session/domain/case-sensitive without normalization',
      () {
        final old = _recipe(
          ranges: [
            _support(['same'], session: 'original'),
          ],
        );
        final support = _support(['user', 'reply']);
        for (final foreign in ['foreign', 'Original']) {
          final other = _support(['same'], session: foreign);
          final selected = [support, other];
          final proposed = _recipe(
            user: 'new-user',
            reply: 'new-reply',
            run: 'new-run',
            ranges: selected,
            refs: [_ref('reply')],
          );
          expect(
            _verify(
              proposed,
              ranges: selected,
              messages: [
                _user('user'),
                _assistant(old),
                _user('same', session: foreign),
              ],
            ).failure,
            SupportModelProvenanceFailure.coverageMismatch,
          );
        }
        final valid = _support(['a', 'A', 'é', 'e\u0301']);
        expect(
          _verify(
            _recipe(ranges: [valid]),
            ranges: [valid],
            messages: [_user('a'), _user('A'), _user('é'), _user('e\u0301')],
          ).isValid,
          isTrue,
        );
      },
    );

    test(
      'current-only saved reply later requires historical input explicitly',
      () {
        final old = _recipe(
          user: 'old-user',
          reply: 'old-reply',
          run: 'old-run',
        );
        final range = _support(['old-user', 'old-reply']);
        final proposed = _recipe(
          ranges: [range],
          refs: [_ref('old-reply', run: 'old-run')],
        );
        final result = _verify(
          proposed,
          ranges: [range],
          messages: [_user('old-user'), _assistant(old)],
        );
        expect(result.isValid, isTrue);
        expect(result.retainedRecipes.single, same(old));
        expect(() => result.retainedRecipes.clear(), throwsUnsupportedError);
        final noInput = _support(['old-reply']);
        final missing = _verify(
          _recipe(ranges: [noInput], refs: proposed.directReplies),
          ranges: [noInput],
          messages: [_assistant(old)],
        );
        expect(
          missing.failure,
          SupportModelProvenanceFailure.missingDependency,
        );
        // Saving the old originating identity cannot approve re-submission as a
        // current input. The verifier refuses overlap with selected historical IDs.
        expect(
          _verify(
            _recipe(
              user: 'old-user',
              ranges: [range],
              refs: proposed.directReplies,
            ),
            ranges: [range],
            messages: [_user('old-user'), _assistant(old)],
          ).failure,
          SupportModelProvenanceFailure.currentInputOverlap,
        );
      },
    );

    test(
      'game/support transitive DAG preserves every ORIGINAL range and run',
      () {
        final fixture = _DagFixture();
        final result = fixture.verify();
        expect(result.isValid, isTrue);
        expect(result.retainedRecipes, [fixture.first, fixture.second]);
        expect(
          result.retainedRecipes.first.originalRanges,
          same(fixture.first.originalRanges),
        );
        expect(
          result.retainedRecipes.first.originalRanges[1].orderedMessageIds,
          ['g0', 'g2'],
        );
        expect(fixture.ranges[1].orderedMessageIds, ['g0', 'g1', 'g2']);
        expect(result.retainedRecipes.last.directReplies.single.runId, 'a-run');
        // No flattened union, rebased scope or duplicated inherited node.
        expect(result.retainedRecipes.length, 2);
        expect(result.toString(), 'SupportModelProvenanceCoverageResult');
        expect(
          fixture.messages.first.toString(),
          'SupportModelSelectedSupportMessage',
        );
      },
    );

    test(
      'source declarations alone never supply missing selected rights/data',
      () {
        final fixture = _DagFixture();
        final selected = [fixture.ranges.first];
        final proposed = _recipe(
          ranges: selected,
          refs: fixture.proposed.directReplies,
        );
        final result = _verify(
          proposed,
          ranges: selected,
          messages: fixture.messages,
        );
        expect(result.failure, SupportModelProvenanceFailure.coverageMismatch);
        expect(result.retainedRecipes, isEmpty);
        expect(
          _verify(
            _recipe(
              ranges: [
                _game(['not-selected']),
              ],
            ),
          ).failure,
          SupportModelProvenanceFailure.coverageMismatch,
        );
        // Even successful metadata-only consistency reports no lease/approval.
        expect(fixture.verify().retainedRecipes.first, same(fixture.first));
      },
    );

    test(
      'missing ancestor/current-input/original source refuses WHOLE selection',
      () {
        final fixture = _DagFixture();
        final noAncestor = _support(['legacy', 'a-user', 'b-user', 'b-reply']);
        final ranges = [noAncestor, fixture.ranges[1]];
        final result = _verify(
          _recipe(
            ranges: ranges,
            refs: [_ref('b-reply', run: 'b-run')],
          ),
          ranges: ranges,
          messages: [
            _user('legacy'),
            _user('a-user'),
            _user('b-user'),
            _assistant(fixture.second),
          ],
        );
        expect(result.isValid, isFalse);
        expect(result.retainedRecipes, isEmpty);
        final noOriginal = _support(['a-user', 'a-reply', 'b-user', 'b-reply']);
        final noOriginalRanges = [noOriginal, fixture.ranges[1]];
        expect(
          _verify(
            _recipe(
              ranges: noOriginalRanges,
              refs: fixture.proposed.directReplies,
            ),
            ranges: noOriginalRanges,
            messages: fixture.messages.sublist(1),
          ).failure,
          SupportModelProvenanceFailure.coverageMismatch,
        );
        final noOriginInput = _support([
          'legacy',
          'a-reply',
          'b-user',
          'b-reply',
        ]);
        final noInputRanges = [noOriginInput, fixture.ranges[1]];
        expect(
          _verify(
            _recipe(
              ranges: noInputRanges,
              refs: fixture.proposed.directReplies,
            ),
            ranges: noInputRanges,
            messages: [fixture.messages[0], ...fixture.messages.sublist(2)],
          ).isValid,
          isFalse,
        );
      },
    );

    test(
      'foreign branch/domain with SAME IDs cannot cover an original source',
      () {
        final old = _recipe(
          ranges: [
            _game(['g'], session: 'original'),
          ],
        );
        final support = _support(['user', 'reply']);
        for (final replacement in [
          _game(['g'], session: 'foreign'),
          _support(['g'], session: 'original'),
        ]) {
          final selected = [support, replacement];
          final messages = [
            _user('user'),
            _assistant(old),
            if (replacement.domain == SupportModelSourceDomain.support)
              _user('g', session: 'original'),
          ];
          final proposed = _recipe(
            user: 'new-user',
            reply: 'new-reply',
            run: 'new-run',
            ranges: selected,
            refs: [_ref('reply')],
          );
          expect(
            _verify(proposed, ranges: selected, messages: messages).failure,
            SupportModelProvenanceFailure.coverageMismatch,
          );
        }
      },
    );

    test('recipe/ref owners require exact support session/message/run', () {
      final fixture = _DagFixture();
      for (final bad in [
        _copy(fixture.first, session: 'foreign'),
        _copy(fixture.first, reply: 'different'),
        _copy(fixture.first, run: 'replacement'),
      ]) {
        final messages = [...fixture.messages];
        messages[2] = SupportModelSelectedSupportMessage(
          sessionId: 'support',
          messageId: 'a-reply',
          role: SupportModelSelectedRole.assistant,
          runId: 'a-run',
          provenance: bad,
        );
        expect(
          fixture.verify(messages: messages).failure,
          SupportModelProvenanceFailure.ownerMismatch,
        );
      }
      final wrongRun = _copy(
        fixture.proposed,
        refs: [
          _ref('a-reply', run: 'replacement'),
          _ref('b-reply', run: 'b-run'),
        ],
      );
      expect(
        fixture.verify(proposed: wrongRun).failure,
        SupportModelProvenanceFailure.ownerMismatch,
      );
      final foreignRef = _copy(
        fixture.proposed,
        refs: [
          _ref('a-reply', session: 'foreign', run: 'a-run'),
          _ref('b-reply', run: 'b-run'),
        ],
      );
      expect(
        fixture.verify(proposed: foreignRef).failure,
        SupportModelProvenanceFailure.missingDependency,
      );
    });

    test(
      'legacy authored user allowed; assistant/system/unknown fail whole context',
      () {
        final range = _support(['legacy']);
        final proposed = _recipe(ranges: [range]);
        expect(
          _verify(
            proposed,
            ranges: [range],
            messages: [_user('legacy')],
          ).isValid,
          isTrue,
        );
        for (final role in [
          SupportModelSelectedRole.assistant,
          SupportModelSelectedRole.system,
          SupportModelSelectedRole.unknown,
        ]) {
          final message = SupportModelSelectedSupportMessage(
            sessionId: 'support',
            messageId: 'legacy',
            role: role,
            runId: 'legacy-run',
          );
          final result = _verify(
            proposed,
            ranges: [range],
            messages: [message],
          );
          expect(
            result.failure,
            SupportModelProvenanceFailure.unavailableRecipe,
          );
          expect(result.retainedRecipes, isEmpty);
        }
        final badUser = SupportModelSelectedSupportMessage(
          sessionId: 'support',
          messageId: 'legacy',
          role: SupportModelSelectedRole.user,
          provenance: _recipe(),
        );
        expect(
          _verify(proposed, ranges: [range], messages: [badUser]).failure,
          SupportModelProvenanceFailure.ownerMismatch,
        );
      },
    );

    test(
      'missing run, metadata omissions/extras/reordering and duplicates refuse',
      () {
        final fixture = _DagFixture();
        final messages = [...fixture.messages];
        messages[2] = SupportModelSelectedSupportMessage(
          sessionId: 'support',
          messageId: 'a-reply',
          role: SupportModelSelectedRole.assistant,
          provenance: fixture.first,
        );
        expect(
          fixture.verify(messages: messages).failure,
          SupportModelProvenanceFailure.unavailableRecipe,
        );
        expect(
          fixture.verify(messages: fixture.messages.sublist(0, 4)).failure,
          SupportModelProvenanceFailure.missingDependency,
        );
        expect(
          fixture
              .verify(messages: [...fixture.messages, _user('extra')])
              .failure,
          SupportModelProvenanceFailure.invalidSource,
        );
        expect(
          fixture.verify(messages: fixture.messages.reversed.toList()).failure,
          SupportModelProvenanceFailure.orderMismatch,
        );
        expect(
          _verify(
            fixture.proposed,
            ranges: [...fixture.ranges, fixture.ranges.first],
            messages: fixture.messages,
          ).failure,
          SupportModelProvenanceFailure.invalidSource,
        );
      },
    );

    test(
      'order-preserving subsequence is required, not unordered ID membership',
      () {
        final fixture = _DagFixture();
        final swappedGame = _copy(
          fixture.first,
          ranges: [
            fixture.first.originalRanges.first,
            _game(['g2', 'g0']),
          ],
        );
        final messages = [...fixture.messages]..[2] = _assistant(swappedGame);
        expect(
          fixture.verify(messages: messages).failure,
          SupportModelProvenanceFailure.orderMismatch,
        );
        final swappedSources = _copy(
          fixture.first,
          ranges: fixture.first.originalRanges.reversed.toList(),
        );
        final sources = [...fixture.messages]..[2] = _assistant(swappedSources);
        expect(
          fixture.verify(messages: sources).failure,
          SupportModelProvenanceFailure.orderMismatch,
        );
        final swappedRefs = _copy(
          fixture.proposed,
          refs: fixture.proposed.directReplies.reversed.toList(),
        );
        expect(
          fixture.verify(proposed: swappedRefs).failure,
          SupportModelProvenanceFailure.orderMismatch,
        );
        final reduced = _copy(
          fixture.proposed,
          ranges: [fixture.first.originalRanges.first, fixture.ranges[1]],
        );
        expect(
          fixture.verify(proposed: reduced).failure,
          SupportModelProvenanceFailure.coverageMismatch,
        );
      },
    );

    test(
      'omitting inherited/selected references or adding undeclared ones refuses',
      () {
        final fixture = _DagFixture();
        expect(
          fixture
              .verify(
                proposed: _copy(
                  fixture.proposed,
                  refs: [_ref('b-reply', run: 'b-run')],
                ),
              )
              .failure,
          SupportModelProvenanceFailure.missingDependency,
        );
        final missingInherited = _copy(fixture.second, refs: []);
        final messages = [...fixture.messages]
          ..[4] = _assistant(missingInherited);
        expect(
          fixture.verify(messages: messages).failure,
          SupportModelProvenanceFailure.missingDependency,
        );
        final unsupportedRef = _copy(
          fixture.first,
          refs: [_ref('b-reply', run: 'b-run')],
        );
        final extra = [...fixture.messages]..[2] = _assistant(unsupportedRef);
        expect(
          fixture.verify(messages: extra).failure,
          SupportModelProvenanceFailure.missingDependency,
        );
      },
    );

    test(
      'cross-session cycles refused without recursion or ancestor resolution',
      () {
        final aRange = _support(['a-user', 'a-reply'], session: 'a');
        final bRange = _support(['b-user', 'b-reply'], session: 'b');
        final a = _recipe(
          session: 'a',
          user: 'a-user',
          reply: 'a-reply',
          run: 'a-run',
          ranges: [
            _support(['b-reply'], session: 'b'),
          ],
          refs: [_ref('b-reply', session: 'b', run: 'b-run')],
        );
        final b = _recipe(
          session: 'b',
          user: 'b-user',
          reply: 'b-reply',
          run: 'b-run',
          ranges: [
            _support(['a-reply'], session: 'a'),
          ],
          refs: [_ref('a-reply', session: 'a', run: 'a-run')],
        );
        final proposed = _recipe(
          ranges: [aRange, bRange],
          refs: [
            _ref('a-reply', session: 'a', run: 'a-run'),
            _ref('b-reply', session: 'b', run: 'b-run'),
          ],
        );
        final result = _verify(
          proposed,
          ranges: [aRange, bRange],
          messages: [
            _user('a-user', session: 'a'),
            _assistant(a),
            _user('b-user', session: 'b'),
            _assistant(b),
          ],
        );
        expect(result.failure, SupportModelProvenanceFailure.cycle);
        expect(result.retainedRecipes, isEmpty);
      },
    );

    test(
      'current historical overlap, historical input role and temporal order',
      () {
        final fixture = _DagFixture();
        expect(
          fixture
              .verify(proposed: _copy(fixture.proposed, user: 'legacy'))
              .failure,
          SupportModelProvenanceFailure.currentInputOverlap,
        );
        expect(
          fixture
              .verify(proposed: _copy(fixture.proposed, reply: 'a-reply'))
              .failure,
          SupportModelProvenanceFailure.currentInputOverlap,
        );
        final overlapping = _copy(
          fixture.first,
          ranges: [
            _support(['legacy', 'a-user']),
            fixture.first.originalRanges[1],
          ],
        );
        final overlapMessages = [...fixture.messages]
          ..[2] = _assistant(overlapping);
        expect(
          fixture.verify(messages: overlapMessages).failure,
          SupportModelProvenanceFailure.currentInputOverlap,
        );
        final inputIsReply = _copy(fixture.second, user: 'a-reply');
        final roleMessages = [...fixture.messages]
          ..[4] = _assistant(inputIsReply);
        expect(fixture.verify(messages: roleMessages).isValid, isFalse);
        final old = _recipe(
          user: 'old-user',
          reply: 'old-reply',
          run: 'old-run',
        );
        final reversed = _support(['old-reply', 'old-user']);
        final proposed = _recipe(
          ranges: [reversed],
          refs: [_ref('old-reply', run: 'old-run')],
        );
        expect(
          _verify(
            proposed,
            ranges: [reversed],
            messages: [_assistant(old), _user('old-user')],
          ).failure,
          SupportModelProvenanceFailure.orderMismatch,
        );
      },
    );

    test('duplicate run/input owners refused, not treated as same recipe', () {
      final fixture = _DagFixture();
      for (final bad in [
        _copy(fixture.second, run: 'a-run'),
        _copy(fixture.second, user: 'a-user'),
      ]) {
        final messages = [...fixture.messages]..[4] = _assistant(bad);
        expect(
          fixture.verify(messages: messages).failure,
          SupportModelProvenanceFailure.ownerMismatch,
        );
      }
    });

    test('64-node total DAG bound and selected collection bounds', () {
      final recipes = List.generate(
        64,
        (i) => _recipe(user: 'u$i', reply: 'r$i', run: 'run$i'),
      );
      final range = _support([
        for (var i = 0; i < 64; i++) ...['u$i', 'r$i'],
      ]);
      final proposed = _recipe(
        ranges: [range],
        refs: [
          for (final recipe in recipes)
            _ref(recipe.replyMessageId, run: recipe.runId),
        ],
      );
      final messages = [
        for (final recipe in recipes) ...[
          _user(recipe.currentUserMessageId),
          _assistant(recipe),
        ],
      ];
      expect(
        _verify(proposed, ranges: [range], messages: messages).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      final atLimitRange = _support(range.orderedMessageIds.sublist(0, 126));
      final atLimit = _recipe(
        ranges: [atLimitRange],
        refs: proposed.directReplies.sublist(0, 63),
      );
      expect(
        _verify(
          atLimit,
          ranges: [atLimitRange],
          messages: messages.sublist(0, 126),
        ).isValid,
        isTrue,
      );
      expect(
        _verify(_recipe(), ranges: List.filled(129, range)).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
      expect(
        _verify(
          _recipe(),
          messages: List.filled(4097, _user('legacy')),
        ).failure,
        SupportModelProvenanceFailure.limitExceeded,
      );
    });

    test(
      'aggregate declarations and repeated source occurrences bounded once/node',
      () {
        final sources = List.generate(63, (i) => _game(['g'], session: 'g$i'));
        final a = _recipe(
          user: 'a-user',
          reply: 'a-reply',
          run: 'a-run',
          ranges: sources,
        );
        final b = _recipe(
          user: 'b-user',
          reply: 'b-reply',
          run: 'b-run',
          ranges: sources,
        );
        final range = _support(['a-user', 'a-reply', 'b-user', 'b-reply']);
        final selected = [range, ...sources];
        final exact128Range = _support(['a-user', 'a-reply']);
        final exact128Sources = [exact128Range, ...sources];
        final exact128 = _recipe(
          ranges: exact128Sources,
          refs: [_ref('a-reply', run: 'a-run')],
        );
        expect(
          _verify(
            exact128,
            ranges: exact128Sources,
            messages: [_user('a-user'), _assistant(a)],
          ).isValid,
          isTrue,
        );
        final proposed = _recipe(
          ranges: selected,
          refs: [
            _ref('a-reply', run: 'a-run'),
            _ref('b-reply', run: 'b-run'),
          ],
        );
        expect(
          _verify(
            proposed,
            ranges: selected,
            messages: [
              _user('a-user'),
              _assistant(a),
              _user('b-user'),
              _assistant(b),
            ],
          ).failure,
          SupportModelProvenanceFailure.limitExceeded,
        );
        final game = _game(List.generate(512, (i) => 'g$i'));
        final repeated = List.generate(
          8,
          (i) =>
              _recipe(user: 'u$i', reply: 'r$i', run: 'run$i', ranges: [game]),
        );
        final support = _support([
          for (var i = 0; i < 8; i++) ...['u$i', 'r$i'],
        ]);
        final ranges = [support, game];
        expect(
          _verify(
            _recipe(
              ranges: ranges,
              refs: [
                for (final r in repeated) _ref(r.replyMessageId, run: r.runId),
              ],
            ),
            ranges: ranges,
            messages: [
              for (final r in repeated) ...[
                _user(r.currentUserMessageId),
                _assistant(r),
              ],
            ],
          ).failure,
          SupportModelProvenanceFailure.limitExceeded,
        );
      },
    );
  });
}

SupportModelProvenance _recipe({
  String session = 'support',
  String user = 'user',
  String reply = 'reply',
  String run = 'run',
  List<SupportModelSourceRange> ranges = const [],
  List<SupportModelReplyReference> refs = const [],
}) => SupportModelProvenance(
  supportSessionId: session,
  replyMessageId: reply,
  runId: run,
  currentUserMessageId: user,
  originalRanges: ranges,
  directReplies: refs,
);

SupportModelProvenance _copy(
  SupportModelProvenance value, {
  String? session,
  String? user,
  String? reply,
  String? run,
  List<SupportModelSourceRange>? ranges,
  List<SupportModelReplyReference>? refs,
}) => _recipe(
  session: session ?? value.supportSessionId,
  user: user ?? value.currentUserMessageId,
  reply: reply ?? value.replyMessageId,
  run: run ?? value.runId,
  ranges: ranges ?? value.originalRanges,
  refs: refs ?? value.directReplies,
);

SupportModelSourceRange _support(
  List<String> ids, {
  String session = 'support',
}) => SupportModelSourceRange(
  domain: SupportModelSourceDomain.support,
  sessionId: session,
  orderedMessageIds: ids,
);

SupportModelSourceRange _game(List<String> ids, {String session = 'game'}) =>
    SupportModelSourceRange(
      domain: SupportModelSourceDomain.game,
      sessionId: session,
      orderedMessageIds: ids,
    );

SupportModelReplyReference _ref(
  String id, {
  String session = 'support',
  String run = 'run',
}) => SupportModelReplyReference(sessionId: session, messageId: id, runId: run);

SupportModelSelectedSupportMessage _user(
  String id, {
  String session = 'support',
}) => SupportModelSelectedSupportMessage(
  sessionId: session,
  messageId: id,
  role: SupportModelSelectedRole.user,
);

SupportModelSelectedSupportMessage _assistant(SupportModelProvenance recipe) =>
    SupportModelSelectedSupportMessage(
      sessionId: recipe.supportSessionId,
      messageId: recipe.replyMessageId,
      role: SupportModelSelectedRole.assistant,
      runId: recipe.runId,
      provenance: recipe,
    );

String _encode(SupportModelProvenance recipe) =>
    SupportModelProvenanceCodec.encodeForEncryptedStorage(recipe);
SupportModelProvenanceDecodeResult _decode(String raw) =>
    SupportModelProvenanceCodec.decodeFromEncryptedStorage(raw);
Map<String, dynamic> _wire(SupportModelProvenance recipe) =>
    jsonDecode(_encode(recipe)) as Map<String, dynamic>;
Matcher _failure(SupportModelProvenanceFailure failure) => throwsA(
  isA<SupportModelProvenanceException>().having(
    (e) => e.failure,
    'fixed failure',
    failure,
  ),
);

SupportModelProvenanceCoverageResult _verify(
  SupportModelProvenance proposed, {
  List<SupportModelSourceRange> ranges = const [],
  List<SupportModelSelectedSupportMessage> messages = const [],
}) => SupportModelProvenanceCodec.verifySelectedContext(
  proposedReply: proposed,
  selectedRanges: ranges,
  selectedSupportMessages: messages,
);

final class _DagFixture {
  _DagFixture() {
    first = _recipe(
      user: 'a-user',
      reply: 'a-reply',
      run: 'a-run',
      ranges: [
        _support(['legacy']),
        _game(['g0', 'g2']),
      ],
    );
    second = _recipe(
      user: 'b-user',
      reply: 'b-reply',
      run: 'b-run',
      ranges: [
        _support(['legacy', 'a-user', 'a-reply']),
        _game(['g0', 'g2']),
      ],
      refs: [_ref('a-reply', run: 'a-run')],
    );
    ranges = [
      _support(['legacy', 'a-user', 'a-reply', 'b-user', 'b-reply']),
      _game(['g0', 'g1', 'g2']),
    ];
    proposed = _recipe(
      ranges: ranges,
      refs: [
        _ref('a-reply', run: 'a-run'),
        _ref('b-reply', run: 'b-run'),
      ],
    );
    messages = [
      _user('legacy'),
      _user('a-user'),
      _assistant(first),
      _user('b-user'),
      _assistant(second),
    ];
  }

  late final SupportModelProvenance first;
  late final SupportModelProvenance second;
  late final SupportModelProvenance proposed;
  late final List<SupportModelSourceRange> ranges;
  late final List<SupportModelSelectedSupportMessage> messages;

  SupportModelProvenanceCoverageResult verify({
    SupportModelProvenance? proposed,
    List<SupportModelSelectedSupportMessage>? messages,
  }) => _verify(
    proposed ?? this.proposed,
    ranges: ranges,
    messages: messages ?? this.messages,
  );
}
