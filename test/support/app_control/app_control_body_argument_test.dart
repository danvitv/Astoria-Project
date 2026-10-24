import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';

// Shared contract only: these callbacks observe admission, NOT a domain write.
// No app/provider graph, repository, file, preferences, key or native IO is used.
void main() {
  test('body field is an explicit bounded scalar with empty clearing', () {
    const body = SupportAppActionField.bodyText(32);
    const metadata = SupportAppActionField.text(32);
    expect(body.isBodyText, isTrue);
    expect(metadata.isBodyText, isFalse);
    expect(body.schema, {'type': 'string', 'minLength': 0, 'maxLength': 32});
    expect(metadata.schema['minLength'], 1);
    expect(body.accepts(''), isTrue);
    expect(body.accepts(' \tfirst\r\nsecond  '), isTrue);
    expect(body.accepts(_repeat('x', 33)), isFalse);
    expect(metadata.accepts(''), isFalse);
    expect(metadata.accepts(' first'), isFalse);
    expect(metadata.accepts('first\nsecond'), isFalse);
    final definition = _BodyContractAdapter().definitions.single.native;
    expect(definition.parameters['additionalProperties'], isFalse);
    expect(definition.parameters['type'], 'object');
    expect((definition.parameters['properties']! as Map)['body'], {
      'type': 'string',
      'minLength': 0,
      'maxLength': 32768,
    });
  });

  test(
    'multiline whitespace and JSON-looking prose stay exact in confirmation',
    () async {
      for (final body in [
        '',
        ' \tfirst\r\nsecond  ',
        '  {\n "scene": "new text"\n}\t\r ',
        'Новый текст\n日本語',
        _repeat('x', 32768),
      ]) {
        final f = _BodyContractFixture();
        final supplied = <String, Object?>{'body': body, 'label': 'new-label'};
        f.confirmation.beforeDecision = (request) {
          supplied['body'] = 'replacement';
          expect(request.arguments['body'], body);
          expect(f.adapter.arguments!['body'], body);
          expect(
            () => request.arguments['body'] = 'replacement',
            throwsUnsupportedError,
          );
          expect(
            () => f.adapter.arguments!['body'] = 'replacement',
            throwsUnsupportedError,
          );
        };
        final result = await f.call(supplied);
        expect(result.content['code'], 'completed');
        expect(result.content['effect'], 'none');
        expect(result.content['data'], isEmpty);
        expect(f.adapter.admittedExecutions, 1);
        expect(f.confirmation.last!.arguments['body'], body);
        expect(f.confirmation.last!.context.sourceAccess, isNull);
      }
    },
  );

  test(
    'only the declared field admits bodies; coercion and nesting stay denied',
    () async {
      final f = _BodyContractFixture();
      for (final arguments in <Map<String, Object?>>[
        {'body': 'new', 'label': 'metadata\nline'},
        {'body': 'new', 'label': ' metadata'},
        {'body': 'new', 'label': ''},
        {'body': _repeat('x', 32769)},
        {'body': 'new', 'unknown': 'supplied\nbody'},
        {'body': null},
        {'body': true},
        {'body': 123},
        {'body': 1.5},
        {
          'body': ['new'],
        },
        {
          'body': {'text': 'new'},
        },
        {'body': 'new', 'enabled': 'true'},
        {'body': 'new', 'count': '2'},
        {'body': 'new', 'amount': '2.5'},
        {'body': 'new', 'mode': 'unknown'},
        {},
      ]) {
        final result = await f.call(arguments);
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
        expect(result.content['data'], isEmpty);
      }
      // The field itself can declare a larger metadata length; registry's old
      // metadata-only 256 cap remains an independent restriction.
      final oversizedMetadata = await f.call({
        'body': 'new',
        'label': _repeat('m', 257),
      });
      expect(oversizedMetadata.content['code'], 'unsafeMetadata');
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.confirmation.last, isNull);
    },
  );

  test(
    'ordinary scalar choices and metadata boundary remain unchanged',
    () async {
      final f = _BodyContractFixture();
      final result = await f.call({
        'body': 'new\nbody',
        'label': _repeat('m', 256),
        'enabled': true,
        'count': 2,
        'amount': 2.5,
        'mode': 'clear',
      });
      expect(result.content['code'], 'completed');
      expect(f.adapter.admittedExecutions, 1);
      expect(f.adapter.arguments!['amount'], 2.5);
      expect(f.adapter.arguments!['label'], _repeat('m', 256));
    },
  );

  test(
    'non-whitespace controls and invisible Unicode are denied, not removed',
    () async {
      final f = _BodyContractFixture();
      for (final control in [
        '\u0000',
        '\u0008',
        '\u000b',
        '\u000c',
        '\u001b',
        '\u007f',
        '\u0085',
        '\u009f',
        '\u00ad',
        '\u034f',
        '\u061c',
        '\u180e',
        '\u200b',
        '\u200c',
        '\u200d',
        '\u200f',
        '\u202e',
        '\u2060',
        '\u2066',
        '\ufeff',
        '\ufff9',
        '\ufe0f',
        '\u{e0001}',
      ]) {
        final body = 'new${control}text';
        expect(f.policy.exactBodyText(body, maxLength: 32768), isNull);
        final result = await f.call({'body': body});
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      expect(f.policy.exactBodyText('', maxLength: 0), isNull);
      expect(f.policy.exactBodyText('', maxLength: 32769), isNull);
      expect(f.policy.exactBodyText('', maxLength: 1), '');
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
    },
  );

  test(
    'whole multiline known secret is blocked before preparation or effect',
    () async {
      final f = _BodyContractFixture();
      const secret = 'SYNTHETIC_KNOWN_LINE_A\nSYNTHETIC_KNOWN_LINE_B';
      f.redactor = f.redactor.withKnownSecrets([secret]);
      final body = 'new prefix\n$secret\nnew suffix';
      expect(f.policy.exactBodyText(body, maxLength: 32768), isNull);
      final result = await f.call({'body': body});
      expect(result.content['code'], 'unsafeMetadata');
      expect(result.content['effect'], 'none');
      expect(result.content['data'], isEmpty);
      expect(result.content.toString(), isNot(contains(secret)));
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.confirmation.last, isNull);
    },
  );

  test('regex tokens are denied by exact body policy and native boundary', () {
    final f = _BodyContractFixture();
    const body = 'new line\nsk-SYNTHETIC_TOKEN_12345678\nother line';
    expect(f.policy.exactBodyText(body, maxLength: 32768), isNull);
    expect(
      () => NativeToolCall(
        id: 'synthetic-call',
        name: _BodyContractAdapter.action,
        arguments: {'body': body},
      ),
      throwsA(
        isA<NativeToolException>().having(
          (e) => e.reason,
          'reason',
          NativeToolReason.denied,
        ),
      ),
    );
    expect(f.adapter.admittedExecutions, 0);
  });

  test(
    'metadata-only policy remains compatible and bodies fail closed',
    () async {
      final f = _BodyContractFixture();
      final registry = f.registryWith(_MetadataOnlyPolicy(f.policy));
      final result = await registry.execute(
        NativeToolCall(
          id: 'synthetic-call',
          name: _BodyContractAdapter.action,
          arguments: {'body': 'new body'},
        ),
        f.context(),
      );
      expect(result.content['code'], 'unsafeMetadata');
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.confirmation.last, isNull);
    },
  );

  test('same original redactor must survive both policy callbacks', () {
    final before = SecretRedactor();
    final after = SecretRedactor();
    var reads = 0;
    final policy = SupportAppRedactedMetadataPolicy(
      currentRedactor: () => ++reads == 1 ? before : after,
    );
    expect(policy.exactBodyText('new\nbody', maxLength: 32), isNull);
    expect(reads, 2);
  });

  test(
    'replacement redactor policy denies registry before any callback',
    () async {
      final f = _BodyContractFixture();
      final registry = f.registryWith(
        SupportAppRedactedMetadataPolicy(currentRedactor: SecretRedactor.new),
      );
      await expectLater(
        registry.execute(
          NativeToolCall(
            id: 'synthetic-call',
            name: _BodyContractAdapter.action,
            arguments: {'body': 'new\nbody'},
          ),
          f.context(),
        ),
        throwsA(isA<NativeToolException>()),
      );
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.confirmation.last, isNull);
    },
  );

  test('body-policy reentry invalidates both nested and outer checks', () {
    final redactor = SecretRedactor();
    late SupportAppRedactedMetadataPolicy policy;
    var entered = false;
    String? nested;
    policy = SupportAppRedactedMetadataPolicy(
      currentRedactor: () {
        if (!entered) {
          entered = true;
          nested = policy.exactBodyText('nested\nbody', maxLength: 32);
        }
        return redactor;
      },
    );
    expect(policy.exactBodyText('outer\nbody', maxLength: 32), isNull);
    expect(entered, isTrue);
    expect(nested, isNull);
  });

  test(
    'reentrant policy identity check denies registry without any callback',
    () async {
      final f = _BodyContractFixture();
      var entered = false;
      f.onRedactorRead = () {
        if (entered) return;
        entered = true;
        expect(f.policy.exactBodyText('nested\nbody', maxLength: 32), isNull);
      };
      await expectLater(
        f.call({'body': 'new body'}),
        throwsA(isA<NativeToolException>()),
      );
      expect(entered, isTrue);
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.confirmation.last, isNull);
    },
  );

  test('policy callback cannot admit a retired original owner', () async {
    final f = _BodyContractFixture();
    f.onRedactorRead = () => f.ownerCurrent = false;
    final result = await f.call({'body': 'new\nbody'});
    expect(result.content['code'], 'stale');
    expect(result.content['effect'], 'none');
    expect(f.adapter.prepares, 0);
    expect(f.adapter.admittedExecutions, 0);
  });

  test(
    'secrets learned during preparation or confirmation block execution',
    () async {
      const body = 'SYNTHETIC_FRESH_LINE_A\nSYNTHETIC_FRESH_LINE_B';
      for (final duringConfirmation in [false, true]) {
        final f = _BodyContractFixture();
        void learnSecret() => f.redactor = f.redactor.withKnownSecrets([body]);
        if (duringConfirmation) {
          f.confirmation.beforeDecision = (_) => learnSecret();
        } else {
          f.adapter.beforePrepare = learnSecret;
        }
        final result = await f.call({'body': body});
        expect(result.content['code'], 'unsafeMetadata');
        expect(result.content['effect'], 'none');
        expect(result.content['data'], isEmpty);
        expect(f.adapter.prepares, 1);
        expect(f.adapter.admittedExecutions, 0);
      }
    },
  );

  test(
    'configuration still requires exact current native confirmation',
    () async {
      final unavailable = _BodyContractFixture();
      final absent = await unavailable.call({
        'body': 'new\nbody',
      }, unavailable.context(withConfirmation: false));
      expect(absent.content['code'], 'unavailable');
      expect(unavailable.adapter.prepares, 0);
      for (final retireUi in [false, true]) {
        final f = _BodyContractFixture();
        if (retireUi) {
          f.confirmation.beforeDecision = (_) =>
              f.confirmation.uiCurrent = false;
        } else {
          f.confirmation.allow = false;
        }
        final result = await f.call({'body': 'new\nbody'});
        expect(result.content['code'], 'denied');
        expect(result.content['effect'], 'none');
        expect(f.adapter.admittedExecutions, 0);
      }
    },
  );

  test(
    'body preview and private outcome retain metadata-only 256 limit',
    () async {
      final preview = _BodyContractFixture();
      preview.adapter.preview = {'body': _repeat('p', 257)};
      final rejectedPreview = await preview.call({'body': 'new\nbody'});
      expect(rejectedPreview.content['code'], 'unsafeMetadata');
      expect(preview.confirmation.last, isNull);
      expect(preview.adapter.admittedExecutions, 0);
      for (final withSourceAccess in [false, true]) {
        final f = _BodyContractFixture();
        f.adapter.outcome = {'body': _repeat('p', 257)};
        final result = await f.call({
          'body': 'new\nbody',
        }, f.context(withSourceAccess: withSourceAccess));
        expect(result.content['code'], 'unsafeMetadata');
        expect(result.content['effect'], 'none');
        expect(result.content['data'], isEmpty);
        expect(f.adapter.admittedExecutions, 1); // Not a domain mutation proof.
        expect(f.sources.attempts, 0);
      }
      final multiline = _BodyContractFixture();
      multiline.adapter.outcome = {'body': 'private\ntext'};
      final result = await multiline.call({
        'body': 'new',
      }, multiline.context(withSourceAccess: true));
      expect(result.content['code'], 'unsafeMetadata');
      expect(result.content['data'], isEmpty);
      expect(multiline.sources.attempts, 0);
    },
  );

  test(
    'a body argument grants no source access or body-read availability',
    () async {
      final f = _BodyContractFixture(risk: SupportAppActionRisk.bodyRead);
      final result = await f.call({'body': 'new\nbody'});
      expect(result.content['code'], 'unavailable');
      expect(f.adapter.prepares, 0);
      expect(f.adapter.admittedExecutions, 0);
      expect(f.sources.attempts, 0);
    },
  );

  test(
    'original redactor and native byte budgets remain independent caps',
    () async {
      final f = _BodyContractFixture();
      f.redactor = SecretRedactor(maxOutputLength: 64);
      final redactorLimited = await f.call({'body': _repeat('x', 65)});
      expect(redactorLimited.content['code'], 'unsafeMetadata');
      expect(f.adapter.admittedExecutions, 0);
      final byteLimited = _repeat('界', 24000);
      expect(
        const SupportAppActionField.bodyText(32768).accepts(byteLimited),
        isTrue,
      );
      expect(
        () => NativeToolCall(
          id: 'synthetic-call',
          name: _BodyContractAdapter.action,
          arguments: {'body': byteLimited},
        ),
        throwsA(
          isA<NativeToolException>().having(
            (e) => e.reason,
            'reason',
            NativeToolReason.limit,
          ),
        ),
      );
    },
  );
}

String _repeat(String value, int count) => List.filled(count, value).join();

final class _BodyContractFixture {
  _BodyContractFixture({
    SupportAppActionRisk risk = SupportAppActionRisk.configuration,
  }) : adapter = _BodyContractAdapter(risk: risk) {
    policy = SupportAppRedactedMetadataPolicy(
      currentRedactor: () {
        onRedactorRead?.call();
        return redactor;
      },
    );
    registry = registryWith(policy);
  }

  final _BodyContractAdapter adapter;
  final confirmation = _BodyContractConfirmation();
  final sources = _NoSourceReads();
  // Explicit synthetic redactor budget; production limits are never raised.
  var redactor = SecretRedactor(maxOutputLength: 65536);
  bool ownerCurrent = true;
  void Function()? onRedactorRead;
  late final SupportAppRedactedMetadataPolicy policy;
  late final SupportAppActionRegistry registry;

  SupportAppActionRegistry registryWith(SupportAppMetadataPolicy metadata) =>
      SupportAppActionRegistry(
        adapters: [adapter],
        metadata: metadata,
        isOriginalOwnerCurrent: () => ownerCurrent,
      );

  SupportAppActionContext context({
    bool withConfirmation = true,
    bool withSourceAccess = false,
  }) => SupportAppActionContext(
    runId: 'synthetic-run',
    sessionId: 'synthetic-session',
    cancelToken: CancelToken(),
    isCurrent: () => ownerCurrent,
    allowReversibleChanges: false,
    confirmation: withConfirmation ? confirmation : null,
    sourceAccess: withSourceAccess ? sources : null,
  );

  Future<NativeToolResult> call(
    Map<String, Object?> arguments, [
    SupportAppActionContext? original,
  ]) => registry.execute(
    NativeToolCall(
      id: 'synthetic-call',
      name: _BodyContractAdapter.action,
      arguments: arguments,
    ),
    original ?? context(),
  );
}

final class _BodyContractAdapter implements SupportAppActionAdapter {
  _BodyContractAdapter({this.risk = SupportAppActionRisk.configuration});
  static const action = 'synthetic_body_contract';
  final SupportAppActionRisk risk;
  int prepares = 0, admittedExecutions = 0;
  Map<String, Object?>? arguments;
  Map<String, Object?> preview = const {}, outcome = const {};
  void Function()? beforePrepare;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: action,
      description: 'Synthetic shared supplied-body field contract.',
      risk: risk,
      fields: {
        'body': const SupportAppActionField.bodyText(32768),
        'label': const SupportAppActionField.text(1024),
        'enabled': const SupportAppActionField.boolean(),
        'count': const SupportAppActionField.integer(0, 4),
        'amount': const SupportAppActionField.number(0, 4),
        'mode': SupportAppActionField.choice(['new', 'clear']),
      },
      requiredFields: const {'body'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    prepares++;
    this.arguments = arguments;
    beforePrepare?.call();
    return SupportAppPreparedAction(
      target: 'synthetic-target',
      observation: Object(),
      observationIsCurrent: () => true,
      preview: preview,
      execute: (isCurrent) async {
        if (!isCurrent()) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        admittedExecutions++;
        return SupportAppActionOutcome(
          SupportAppActionCode.completed,
          data: outcome,
        );
      },
    );
  }
}

final class _BodyContractConfirmation implements SupportAppConfirmationPort {
  bool allow = true, uiCurrent = true;
  SupportAppConfirmationRequest? last;
  void Function(SupportAppConfirmationRequest)? beforeDecision;

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    last = request;
    beforeDecision?.call(request);
    if (!allow) return null;
    return SupportAppConfirmationLease(
      request: request,
      isOriginalUiCurrent: () => uiCurrent,
    );
  }
}

final class _MetadataOnlyPolicy implements SupportAppMetadataPolicy {
  _MetadataOnlyPolicy(this.delegate);
  final SupportAppMetadataPolicy delegate;
  @override
  String? exactText(String value, {required int maxLength}) =>
      delegate.exactText(value, maxLength: maxLength);
}

final class _NoSourceReads implements SupportAppSourceAccessPort {
  int attempts = 0;
  @override
  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  }) async {
    attempts++;
    throw StateError('No source reads in shared body-argument contract.');
  }
}
