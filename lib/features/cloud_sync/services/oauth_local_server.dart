import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/oauth_state.dart';

/// The authorization code carried by a loopback redirect's [params], or a
/// thrown error saying why there is none.
///
/// Separate from the request handler so the desktop flow's checks can be run
/// without a browser, and so all three outcomes produce one sentence each
/// instead of three shapes of HTML deciding what the error says.
@visibleForTesting
String oauthCodeFromRedirect(
  Map<String, String> params, {
  String? expectedState,
}) {
  if (params.containsKey('code')) {
    // The desktop flow sends a `state` exactly as the mobile one does and
    // never looked at what came back, so any page that reached the loopback
    // port while it was open could hand the app an authorization code — binding
    // the reader's app to whichever account issued it.
    final mismatch = oauthStateMismatchMessage(expectedState, params['state']);
    if (mismatch != null) throw StateError(mismatch);
    return params['code']!;
  }
  if (params.containsKey('error')) {
    // The callback is untrusted. Never reflect its description into browser
    // HTML, native exceptions, logs or provider state.
    throw Exception('OAuth authorization failed');
  }
  throw Exception('No authorization code received');
}

class OAuthLocalServer {
  static const _successHtml = '''<!DOCTYPE html>
<html><head><title>Astoria — Connected</title></head>
<body style="background:#1A1A2E;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif">
<div style="text-align:center">
<h1>Connected!</h1>
<p>You can close this tab and return to Astoria.</p>
</div></body></html>''';

  static const _errorHtml = '''<!DOCTYPE html>
<html><head><title>Astoria — Error</title></head>
<body style="background:#1A1A2E;color:#ff6b6b;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif">
<div style="text-align:center">
<h1>Authentication Failed</h1>
<p id="err"></p>
<p>You can close this tab and return to Astoria.</p>
</div></body></html>''';

  static Future<({String code, String redirectUri})> authenticate(
    String authUrl, {
    String successPattern = 'code=',
    Duration timeout = const Duration(minutes: 5),
    int port = 0,
    Future<bool> Function(Uri)? launchBrowser,
    bool Function()? isCurrent,
    void Function(Map<String, String>)? registerAliases,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    void check() {
      if (!current()) throw StateError('OAuth operation retired');
    }
    check();
    // Read from the request being made rather than passed in alongside it, so
    // it cannot drift away from what the provider was actually asked.
    final expectedState = Uri.parse(authUrl).queryParameters['state'];

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    if (!current()) {
      await server.close(force: true);
      throw StateError('OAuth operation retired');
    }
    final boundPort = server.port;

    final redirectUri = 'http://localhost:$boundPort';
    final url = authUrl.replaceAll(
      RegExp(r'redirect_uri=[^&]+'),
      'redirect_uri=${Uri.encodeComponent(redirectUri)}',
    );

    final codeCompleter = Completer<String>();
    final codeFuture = codeCompleter.future.timeout(timeout,
      onTimeout: () => throw TimeoutException('OAuth flow timed out', timeout));
    // A redirect error can precede the browser-launch acknowledgement. Attach
    // its handler now without replacing the original future/error for the owner.
    unawaited(codeFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    var handling = false;

    Future<void> closeServer() async {
      try { await server.close(force: true); } catch (_) {}
    }

    server.listen((request) async {
      final response = request.response;
      if (handling || codeCompleter.isCompleted) {
        response.statusCode = 400;
        await response.close();
        return;
      }
      handling = true;
      String? code;
      try {
        registerAliases?.call(request.uri.queryParameters);
        check();
        code = oauthCodeFromRedirect(
          request.uri.queryParameters,
          expectedState: expectedState,
        );
      } catch (_) {
        // Fixed response only, including callback/admission failures.
      }
      if (code != null && current()) {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_successHtml);
      } else {
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(_errorHtml.replaceAll('id="err">', 'id="err">Authorization failed.'));
      }
      try { await response.close(); } catch (_) { code = null; }
      if (!codeCompleter.isCompleted) {
        if (code != null && current()) {
          codeCompleter.complete(code);
        } else {
          codeCompleter.completeError(StateError(
            current() ? 'OAuth authorization failed' : 'OAuth operation retired'));
        }
      }
      await closeServer();
    });

    try {
      check();
      final launched = await (launchBrowser != null
          ? launchBrowser(Uri.parse(url))
          : launchUrl(Uri.parse(url)));
      check();
      if (!launched) throw Exception('Could not launch browser for OAuth');
      final code = await codeFuture;
      check();
      return (code: code, redirectUri: redirectUri);
    } finally {
      await closeServer();
      check();
    }
  }
}
