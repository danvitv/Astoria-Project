import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import 'native_provider_transport_fixture.dart';

export 'native_provider_transport_fixture.dart';
export 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

/// TEST-ONLY view of the final actual delegate's sanitized destination carriers.
/// No production hook or public original-wire auth translator is introduced.
final class GeminiNativeRecordedOptions {
  GeminiNativeRecordedOptions(RequestOptions options)
    : path = options.path,
      baseUrl = options.baseUrl,
      uri = options.uri,
      query = Map<String, dynamic>.from(options.queryParameters),
      extras = Map<String, dynamic>.from(options.extra),
      headers = Map<String, dynamic>.from(options.headers),
      body = jsonEncode(options.data),
      method = options.method,
      token = options.cancelToken,
      redirects = options.followRedirects,
      maxRedirects = options.maxRedirects;
  final String path;
  final String baseUrl;
  final Uri uri;
  final Map<String, dynamic> query;
  final Map<String, dynamic> extras;
  final Map<String, dynamic> headers;
  final String body;
  final String method;
  final CancelToken? token;
  final bool redirects;
  final int maxRedirects;
  final upload = <int>[];
}

final class GeminiNativeRecordingAdapter implements HttpClientAdapter {
  GeminiNativeRecordingAdapter(this.inner, this.records);
  final HttpClientAdapter inner;
  final List<GeminiNativeRecordedOptions> records;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? upload,
    Future<void>? cancelFuture,
  ) {
    final record = GeminiNativeRecordedOptions(options);
    records.add(record);
    return inner.fetch(
      options,
      upload?.map((chunk) {
        record.upload.addAll(chunk);
        return chunk;
      }),
      cancelFuture,
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: true);
}

final class GeminiNativePrivateFixture {
  final h = NativeTransportHarness('gemini');
  final records = <GeminiNativeRecordedOptions>[];
  final handoffs = <PrivateTextHandoff>[];
  final capsules = <PrivateTextDispatchCapsule>[];
  PrivateTextAuthorization? authorization;
  PrivateTextAdmission? admission;
  void Function(Duration, void Function())? onDeadline;

  Future<void> store() => h.store(purposes: {NativeProviderPurpose.astoria});

  NativeProviderPrivateTextDispatcher get dispatcher =>
      NativeProviderPrivateTextDispatcher(
        credentials: h.core.credentials,
        authIssuer: h.core.auth,
        mutations: h.core.mutations,
        routes: h.core.policy,
        privateTextTransport: PrivateTextTransport(
          adapterFactory: () =>
              GeminiNativeRecordingAdapter(h.adapter(), records),
          currentRedactor: () => h.core.redaction.redactor,
          authorize: (handoff) async {
            handoffs.add(handoff);
            return authorization == null ? true : await authorization!(handoff);
          },
          admit: admission == null
              ? null
              : (capsule) async {
                  capsules.add(capsule);
                  return await admission!(capsule);
                },
          scheduleDeadline: (duration, callback) {
            onDeadline?.call(duration, callback);
            return Timer(duration, callback);
          },
        ),
      );

  Future<PrivateTextOutcome> run({
    SavedConnectionAuth? auth,
    ChatTransportRequest? request,
    Uri? approved,
    CancelToken? token,
    bool Function()? current,
    void Function()? activity,
    Duration deadline = PrivateTextLimits.deadline,
    String protocol = 'gemini',
  }) {
    final original = auth ?? h.core.reference(NativeProviderPurpose.astoria);
    return dispatcher.generate(
      savedConnectionAuth: original,
      request:
          request ??
          h.request(auth: original, purpose: NativeProviderPurpose.astoria),
      protocol: protocol,
      approvedRecipient: approved ?? Uri.parse(h.core.row.endpoint),
      cancelToken: token ?? CancelToken(),
      isCurrent: current ?? () => true,
      onActivity: activity,
      deadline: deadline,
    );
  }

  /// Expected original plan uses ONLY a static synthetic canary, never a key
  /// read/returned from production. Original saved row/request remain keyless.
  PrivateTextRequestPlan expectedOriginal({
    List<Map<String, dynamic>>? messages,
  }) => PrivateTextRequestPlan(
    'gemini',
    ChatTransportRequest(
      endpoint: h.core.row.endpoint,
      apiKey: nativeCanary,
      model: h.core.row.model,
      maxTokens: 1024,
      temperature: 0,
      topP: 1,
      requestReasoning: true,
      showNativeReasoning: true,
      messages:
          messages ??
          const [
            {'role': 'user', 'content': 'Hello'},
          ],
    ),
    Uri.parse(h.core.row.endpoint),
    SecretRedactor(
      knownSecrets: [nativeCanary],
      maxInputLength: PrivateTextLimits.contextCharacters,
      maxOutputLength: PrivateTextLimits.contextCharacters,
    ),
  );
}
