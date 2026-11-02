import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/bridge/chat_webview_environment.dart';
import '../chub_account_provider.dart';
import '../services/chub_session.dart';

/// Menu entry point for the "Chub Account" item. When a key is already stored
/// it offers a log-out sheet; otherwise it opens the login sheet.
Future<void> openChubAccountSheet(BuildContext context, WidgetRef ref) async {
  if (!ref.read(chubAccountProvider).isLoggedIn) {
    await showChubLoginSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'chub_login_menu'.tr(),
    items: [
      BottomSheetItem(
        label: 'chub_auth_logout'.tr(),
        icon: Icons.logout_rounded,
        isDestructive: true,
        onTap: () async {
          final account = ref.read(chubAccountProvider.notifier);
          Navigator.of(context, rootNavigator: true).pop();
          try {
            await account.logout();
          } catch (error) {
            if (context.mounted) {
              GlazeToast.show(context, formatError(error), isError: true);
            }
            return;
          }
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        icon: Icons.close_rounded,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Opens the Chub login sheet. The user can sign in through the site's own
/// WebView (which captures the key automatically) or paste a key by hand.
Future<void> showChubLoginSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const ChubLoginSheet(),
  );
}

/// Full-height sheet hosting a visible WebView on chub.ai.
///
/// Chub's API is directly reachable from Dart, so unlike JanitorAI this WebView
/// only *obtains* the key: once the site stores `URQL_TOKEN` in localStorage the
/// sheet reads it (on navigation and on a short poll, since chub.ai is a SPA)
/// and hands it to [chubAccountProvider]. From then on catalog requests carry it
/// straight from Dio. A "paste key" action switches to manual entry.
class ChubLoginSheet extends ConsumerStatefulWidget {
  const ChubLoginSheet({super.key});

  static const _loginUrl = 'https://chub.ai/login';

  @override
  ConsumerState<ChubLoginSheet> createState() => _ChubLoginSheetState();
}

class _ChubLoginSheetState extends ConsumerState<ChubLoginSheet> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _manual = false;
  int _captureEpoch = 0;

  /// Guard against re-entrant capture: once a key lands we close exactly once.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // chub.ai is a SPA: a successful login can store the token without a full
    // navigation, so poll alongside the navigation callbacks.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _capture());
  }

  @override
  void dispose() {
    _captureEpoch++;
    _controller = null;
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _capture() async {
    if (!mounted || _closing || _manual) return;
    final controller = _controller;
    if (controller == null) return;
    final epoch = _captureEpoch;
    final account = ref.read(chubAccountProvider.notifier);
    final accountCurrent = account.captureProbeGuard();
    bool modeCurrent() =>
        mounted &&
        !_manual &&
        epoch == _captureEpoch &&
        identical(_controller, controller);
    final session = await captureChubSessionProbe(
      evaluate: () => controller.evaluateJavascript(source: chubSessionProbeJs),
      isCurrent: () => modeCurrent() && !_closing && accountCurrent(),
    );
    if (!modeCurrent() || _closing || !accountCurrent()) return;
    if (session == null) return;
    _closing = true;
    try {
      await account.setApiKey(session.token, userName: session.userName);
    } on ChubAccountMetadataException catch (error) {
      if (modeCurrent() && context.mounted) {
        GlazeToast.show(context, formatError(error), isError: true);
      }
    } catch (error) {
      if (modeCurrent() && context.mounted) {
        _closing = false;
        GlazeToast.show(context, formatError(error), isError: true);
      }
      return;
    }
    if (!modeCurrent() || !context.mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.92;
    final viewEpoch = _captureEpoch;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _Header(
            manual: _manual,
            onClose: () => Navigator.of(context).pop(),
            onManual: () => setState(() {
              _captureEpoch++;
              _controller = null;
              _closing = false;
              _manual = true;
            }),
            onBack: () => setState(() {
              _captureEpoch++;
              _controller = null;
              _closing = false;
              _manual = false;
            }),
          ),
          Expanded(
            child: _manual
                ? const SingleChildScrollView(
                    padding: EdgeInsets.only(top: 4),
                    child: _ChubKeyForm(),
                  )
                : InAppWebView(
                    initialUrlRequest: URLRequest(
                      url: WebUri(ChubLoginSheet._loginUrl),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      cacheEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      isInspectable: false,
                      useHybridComposition: true,
                      // Same cleaned-up UA as the JanitorAI login WebView:
                      // drops WebView2's `Edg/…` token Google sign-in rejects,
                      // while keeping the Chrome version CF validates.
                      userAgent: janitorWebViewUserAgent,
                    ),
                    webViewEnvironment:
                        defaultTargetPlatform == TargetPlatform.windows
                        ? chatWebViewEnvironment
                        : null,
                    // Claim drags so the WebView scrolls instead of the sheet.
                    gestureRecognizers: {
                      Factory<VerticalDragGestureRecognizer>(
                        () => VerticalDragGestureRecognizer(),
                      ),
                      Factory<HorizontalDragGestureRecognizer>(
                        () => HorizontalDragGestureRecognizer(),
                      ),
                    },
                    onWebViewCreated: (c) {
                      if (!mounted || _manual || viewEpoch != _captureEpoch) {
                        return;
                      }
                      _captureEpoch++;
                      _controller = c;
                    },
                    onLoadStop: (_, _) => _capture(),
                    onUpdateVisitedHistory: (_, _, _) => _capture(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool manual;
  final VoidCallback onClose;
  final VoidCallback onManual;
  final VoidCallback onBack;

  const _Header({
    required this.manual,
    required this.onClose,
    required this.onManual,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(manual ? Icons.arrow_back_rounded : Icons.close_rounded),
            onPressed: manual ? onBack : onClose,
            color: context.cs.onSurface,
          ),
          Expanded(
            child: Text(
              'chub_auth_title'.tr(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (!manual)
            TextButton(
              onPressed: onManual,
              child: Text('chub_login_manual'.tr()),
            ),
        ],
      ),
    );
  }
}

/// Manual Ch-Api-Key entry. Paste the key chub.ai sends in its own requests
/// (DevTools → Network → any `ro.chub.ai` request → `Ch-Api-Key` header).
class _ChubKeyForm extends ConsumerStatefulWidget {
  const _ChubKeyForm();

  @override
  ConsumerState<_ChubKeyForm> createState() => _ChubKeyFormState();
}

class _ChubKeyFormState extends ConsumerState<_ChubKeyForm> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'chub_key_error_empty'.tr());
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = ref.read(chubAccountProvider.notifier);
    ChubAccountMetadataException? metadataIssue;
    try {
      await account.setApiKey(key);
    } on ChubAccountMetadataException catch (error) {
      metadataIssue = error;
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = formatError(error);
        });
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    GlazeToast.show(
      context,
      metadataIssue == null
          ? 'chub_key_saved'.tr()
          : formatError(metadataIssue),
      isError: metadataIssue != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'chub_login_info_desc'.tr(),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _field(cs, _key, 'chub_key_hint'.tr(), enabled: !_busy),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _busy ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: GlazeSpinner(color: Colors.white),
                    )
                  : Text(
                      'chub_key_save'.tr(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(
    ColorScheme cs,
    TextEditingController controller,
    String hint, {
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: 14, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
