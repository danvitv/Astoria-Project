import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../shell/shell_header_provider.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_background.dart';

/// Hide-on-scroll animation of the floating header. Exposed so overlays that
/// belong TO the header but cannot live inside it (the chat's triggered-entries
/// panel, which is measured by the chat body to inset the message list) can run
/// the exact same curve and travel the exact same distance — header and panel
/// then slide away and come back as one unit instead of drifting apart.
const Duration kGlazeHeaderHideDuration = Duration(milliseconds: 300);
const Curve kGlazeHeaderHideCurve = Curves.easeOutCubic;

/// How far the header slides up when hidden, as a fraction of its own height.
const double kGlazeHeaderHideSlideFactor = 1.5;

/// Fractional [AnimatedSlide] offset for an overlay that hides *with* the
/// header: the y-offset an overlay of [overlayHeight] needs so it travels the
/// same number of PIXELS as a header of [headerHeight].
///
/// [AnimatedSlide] measures its offset in fractions of the child's own size, so
/// reusing [kGlazeHeaderHideSlideFactor] directly would make a tall overlay
/// shoot off proportionally faster than the header and the two would visibly
/// come apart mid-animation. Falls back to the header's own factor until the
/// overlay has been measured ([overlayHeight] still 0).
double glazeHeaderHideSlideFor({
  required double headerHeight,
  required double overlayHeight,
}) => overlayHeight <= 0
    ? kGlazeHeaderHideSlideFactor
    : (headerHeight * kGlazeHeaderHideSlideFactor) / overlayHeight;

/// Scaffold with a floating glassmorphic header — use for screens OUTSIDE
/// the shell (character editor, chat screen, etc.) that need a back button.
///
/// Screens inside the shell (history, character list, menu) build their own
/// header inline in their body since they share the shell's bottom nav.
class GlazeScaffold extends StatefulWidget {
  final String? title;
  final Widget? titleWidget;
  final Widget body;
  final List<Widget>? actions;
  final bool showBack;
  final VoidCallback? onBack;
  final bool extendBodyBehindHeader;
  final bool resizeToAvoidBottomInset;
  final bool hideHeader;
  final bool showBackground;

  /// Set by the chat screen, whose body is a full-screen `InAppWebView`, on
  /// the platforms where Flutter cannot blur that WebView itself. The floating
  /// header then drops its Flutter blur and lets an in-WebView CSS strip
  /// reproduce it (see [GlassSurface.blurViaWebView]).
  final bool headerBlurViaWebView;

  /// Shares the header's backdrop capture with the other glass chrome painted
  /// over the same body — the chat's input pill and the circle buttons beside
  /// it (see [GlassSurface.backdropKey]). They sit at opposite edges and never
  /// overlap, so one blur pass serves all of them instead of one each.
  final BackdropKey? headerBackdropKey;

  /// Draws the header edge to edge with square corners, the way the desktop
  /// shell paints a tab's header, instead of as an inset floating pill.
  ///
  /// Chat sets it on desktop so its header matches the Characters tab beside
  /// it; the pill treatment stays everywhere else.
  final bool flushHeader;

  /// When true, this scaffold does not draw its own floating header. Instead it
  /// publishes its title/actions/back into the shell's persistent header (see
  /// [shellHeaderProvider]) and reserves the same vertical space. Only set this
  /// for screens that live inside a shell branch (sub-routes of a bottom-nav
  /// tab); standalone pushed routes keep their own header.
  final bool useShellHeader;

  /// The shell branch (bottom-nav tab) this screen belongs to. Required when
  /// [useShellHeader] is true.
  final int? headerBranchIndex;

  const GlazeScaffold({
    super.key,
    this.title,
    this.titleWidget,
    required this.body,
    this.actions,
    this.showBack = true,
    this.onBack,
    this.extendBodyBehindHeader = false,
    this.resizeToAvoidBottomInset = true,
    this.hideHeader = false,
    this.showBackground = true,
    this.useShellHeader = false,
    this.headerBranchIndex,
    this.headerBlurViaWebView = false,
    this.headerBackdropKey,
    this.flushHeader = false,
  });

  @override
  State<GlazeScaffold> createState() => _GlazeScaffoldState();

  Widget _build(BuildContext context, GlobalKey contentKey) {
    final backHandler = onBack ?? () => Navigator.of(context).maybePop();
    final isIosLikeTargetPlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    // Use GoRouter's declarative stack, NOT Navigator.canPop(). During a
    // `go('/chat/...')` transition the outgoing route is still in the
    // Navigator's animation history, so `Navigator.canPop()` transiently
    // returns true and that stale value gets baked into `PopScope.canPop`.
    // On iOS that let the edge-swipe perform a real pop of the only remaining
    // page, emptying the root navigator and closing the app. GoRouter's match
    // list is updated synchronously on `go` (a top-level route reports false),
    // while genuinely pushed routes still report true so the iOS swipe-back
    // keeps working there.
    final navigatorCanPop = GoRouter.of(context).canPop();

    final header = SafeArea(
      bottom: false,
      child: Padding(
        padding: flushHeader
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: GlazeAppBar(
          title: title,
          titleWidget: titleWidget,
          actions: actions,
          showBack: showBack,
          onBack: backHandler,
          blurViaWebView: headerBlurViaWebView,
          backdropKey: headerBackdropKey,
          borderRadius: flushHeader
              ? BorderRadius.zero
              : const BorderRadius.all(Radius.circular(20)),
        ),
      ),
    );

    final animatedHeader = AnimatedSlide(
      offset: hideHeader
          ? const Offset(0, -kGlazeHeaderHideSlideFactor)
          : Offset.zero,
      duration: kGlazeHeaderHideDuration,
      curve: kGlazeHeaderHideCurve,
      child: AnimatedOpacity(
        opacity: hideHeader ? 0.0 : 1.0,
        duration: kGlazeHeaderHideDuration,
        curve: kGlazeHeaderHideCurve,
        child: header,
      ),
    );

    // When delegating to the shell's persistent header, reserve the same space
    // the local header would occupy but draw nothing — the shell paints the
    // header on top.
    final headerSlot = useShellHeader
        ? const SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(height: 56),
            ),
          )
        : animatedHeader;

    final scaffold = PopScope(
      key: contentKey,
      canPop: isIosLikeTargetPlatform ? navigatorCanPop : !showBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        backHandler();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: extendBodyBehindHeader
            ? Stack(
                children: [
                  Positioned.fill(child: body),
                  Positioned(top: 0, left: 0, right: 0, child: headerSlot),
                ],
              )
            : Column(
                children: [
                  headerSlot,
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: body,
                    ),
                  ),
                ],
              ),
      ),
    );

    final withBackground = showBackground
        ? GlazeBackground(child: scaffold)
        : scaffold;

    if (!useShellHeader) return withBackground;

    return _ShellHeaderPublisher(
      branchIndex: headerBranchIndex ?? 0,
      config: ShellHeaderConfig(
        title: title,
        titleWidget: titleWidget,
        actions: actions,
        showBack: showBack,
        onBack: backHandler,
      ),
      child: withBackground,
    );
  }
}

class _GlazeScaffoldState extends State<GlazeScaffold> {
  // Reparent the existing subtree when background/theme wrappers change.
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) => widget._build(context, _contentKey);
}

/// Publishes a [ShellHeaderConfig] into [shellHeaderProvider] for as long as it
/// is mounted, re-publishing when the config changes. Used by [GlazeScaffold]
/// in `useShellHeader` mode. Mutations are deferred past the build phase.
class _ShellHeaderPublisher extends ConsumerStatefulWidget {
  final int branchIndex;
  final ShellHeaderConfig config;
  final Widget child;

  const _ShellHeaderPublisher({
    required this.branchIndex,
    required this.config,
    required this.child,
  });

  @override
  ConsumerState<_ShellHeaderPublisher> createState() =>
      _ShellHeaderPublisherState();
}

class _ShellHeaderPublisherState extends ConsumerState<_ShellHeaderPublisher> {
  // Cached so it can be used safely in [dispose].
  ShellHeaderRegistry? _registry;

  void _publish() {
    if (!mounted) return;
    _registry?.publish(this, widget.branchIndex, widget.config);
  }

  @override
  void initState() {
    super.initState();
    _registry = ref.read(shellHeaderProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void didUpdateWidget(covariant _ShellHeaderPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void dispose() {
    final registry = _registry;
    WidgetsBinding.instance.addPostFrameCallback((_) => registry?.remove(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Standalone floating glassmorphic app bar — use this directly when you
/// need to embed the header inside a body Column (e.g. shell-tab screens).
class GlazeAppBar extends ConsumerWidget {
  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final bool showBack;
  final VoidCallback? onBack;
  final Widget? leading;
  final BorderRadius borderRadius;

  /// When the header floats over a chat WebView that Flutter cannot sample,
  /// its blur is reproduced by a CSS strip inside the WebView (see
  /// [GlassSurface.blurViaWebView]) and the Flutter BackdropFilter is dropped.
  /// Only the chat header sets this — standalone shell-tab headers keep their
  /// own blur.
  final bool blurViaWebView;

  /// Passed straight to [GlassSurface.backdropKey]: the header joins the
  /// backdrop group of the chrome it is painted alongside, so the engine blurs
  /// the backdrop once for all of them.
  final BackdropKey? backdropKey;

  const GlazeAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions,
    this.showBack = false,
    this.onBack,
    this.leading,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blurViaWebView = false,
    this.backdropKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassSurface(
      enableRipple: true,
      blurViaWebView: blurViaWebView,
      backdropKey: backdropKey,
      borderRadius: borderRadius,
      border: Border.all(color: context.cs.outlineVariant),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            // Left: back button OR logo
            SizedBox(
              width: 52,
              child: showBack
                  ? IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 20,
                      ),
                      color: context.cs.primary,
                      onPressed:
                          onBack ?? () => Navigator.of(context).maybePop(),
                    )
                  : leading ??
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: _AstoriaLogo(),
                        ),
            ),
            // Title
            Expanded(
              child:
                  titleWidget ??
                  (title != null
                      ? Text(
                          title!,
                          style: TextStyle(
                            color: context.cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        )
                      : const SizedBox.shrink()),
            ),
            // Right actions
            if (actions != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions!),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// Astoria's cat mark in the shell header.
class _AstoriaLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/logos/astoria.png', width: 32, height: 32);
}

// ─── Shared ghost pill button ──────────────────────────────────────────────

/// Accent-tinted ghost pill button — matches Glaze's `tabs-add-btn` style.
class GlazePillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const GlazePillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: context.cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
