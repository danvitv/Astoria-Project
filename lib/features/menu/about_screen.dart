import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_version.dart';
import '../../core/state/dev_mode_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topPad = MediaQuery.of(context).padding.top + 74.0;

    return GlazeScaffold(
      title: 'menu_about'.tr(),
      useShellHeader: true,
      headerBranchIndex: 3,
      extendBodyBehindHeader: true,
      onBack: () => context.go('/menu'),
      showBackground: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, 40),
        children: [
          const _HeroCard(),
          _CommunitySection(onLink: _openLink),
          const _AuthorsSection(),
          const _LicenseSection(),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return MenuGroup(
      items: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset(
                      'assets/logos/astoria.png',
                      width: 88,
                      height: 88,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Astoria',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _VersionBadge(),
                      if (isBetaVersion) const SizedBox(width: 8),
                      if (isBetaVersion)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: Colors.orange.withValues(alpha: 0.35),
                            ),
                          ),
                          child: const Text(
                            'BETA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.orange,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (buildDate.isNotEmpty || buildBranch.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    if (buildDate.isNotEmpty)
                      Text(
                        buildDate,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                        ),
                      ),
                    if (buildBranch.isNotEmpty)
                      Text(
                        buildBranch,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'about_description'.tr(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CommunitySection extends StatelessWidget {
  final Future<void> Function(String url) onLink;

  const _CommunitySection({required this.onLink});

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'about_community_header'.tr(),
      headerIcon: Icons.people_outline_rounded,
      items: [
        _LinkTile(
          svgAsset: 'assets/logos/github.svg',
          label: 'btn_github'.tr(),
          subtitle: 'about_github_profile'.tr(),
          brandColor: context.cs.onSurface,
          onTap: () => onLink('https://github.com/danvitv'),
        ),
      ],
    );
  }
}

class _AuthorsSection extends StatelessWidget {
  const _AuthorsSection();

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'about_authors_header'.tr(),
      headerIcon: Icons.code_rounded,
      items: [
        _AuthorTile(
          name: 'hydall',
          role: 'about_role_hydall'.tr(),
          initial: 'H',
          accentColor: const Color(0xFF7996CE),
          imageAsset: 'assets/hydall.jpg',
        ),
        _AuthorTile(
          name: 'danvitv',
          role: 'about_role_danvitv'.tr(),
          initial: 'D',
          accentColor: const Color(0xFF79CE96),
          imageAsset: 'assets/danvitv.png',
        ),
        _TestersTile(onTap: () => context.push('/menu/about/hall-of-fame')),
      ],
    );
  }
}

class _TestersTile extends StatelessWidget {
  final VoidCallback onTap;

  const _TestersTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    const accentColor = Color(0xFFFFD700);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accentColor.withValues(alpha: 0.35)),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.groups_rounded,
                size: 22,
                color: accentColor,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                '...and our helpful testers',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: cs.onSurfaceVariant.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

/// Version chip. Tapping it 7 times toggles developer mode and remembers the
/// new state. Replaces the old hidden tap target on the author tile.
class _VersionBadge extends ConsumerStatefulWidget {
  const _VersionBadge();

  @override
  ConsumerState<_VersionBadge> createState() => _VersionBadgeState();
}

class _VersionBadgeState extends ConsumerState<_VersionBadge> {
  int _taps = 0;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _resetTimer?.cancel();
    _taps++;
    if (_taps >= 7) {
      _taps = 0;
      final enabled = !ref.read(devModeProvider);
      ref.read(devModeProvider.notifier).set(enabled);
      GlazeToast.show(
        context,
        enabled ? 'dev_mode_enabled'.tr() : 'dev_mode_disabled'.tr(),
      );
    } else {
      _resetTimer = Timer(const Duration(seconds: 3), () => _taps = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'v$appVersion',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.primary,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _LicenseSection extends StatelessWidget {
  const _LicenseSection();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return MenuGroup(
      header: 'about_license_header'.tr(),
      headerIcon: Icons.gavel_rounded,
      items: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'AGPL-3.0',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'about_license_text'.tr(),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinkTile extends StatefulWidget {
  final String svgAsset;
  final String label;
  final String subtitle;
  final Color brandColor;
  final VoidCallback onTap;

  const _LinkTile({
    required this.svgAsset,
    required this.label,
    required this.subtitle,
    required this.brandColor,
    required this.onTap,
  });

  @override
  State<_LinkTile> createState() => _LinkTileState();
}

class _LinkTileState extends State<_LinkTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _pressed
            ? cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: widget.brandColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(8),
              child: SvgPicture.asset(
                widget.svgAsset,
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(
                  widget.brandColor,
                  BlendMode.srcIn,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle,
                    style: TextStyle(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: cs.onSurfaceVariant.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthorTile extends StatelessWidget {
  final String name;
  final String role;
  final String initial;
  final Color accentColor;
  final String? imageAsset;

  const _AuthorTile({
    required this.name,
    required this.role,
    required this.initial,
    required this.accentColor,
    this.imageAsset,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: imageAsset == null
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accentColor, accentColor.withValues(alpha: 0.6)],
                    )
                  : null,
              image: imageAsset != null
                  ? DecorationImage(
                      image: AssetImage(imageAsset!),
                      fit: BoxFit.cover,
                    )
                  : null,
              borderRadius: BorderRadius.circular(10),
              border: imageAsset != null
                  ? Border.all(color: accentColor.withValues(alpha: 0.4))
                  : null,
            ),
            alignment: Alignment.center,
            child: imageAsset != null
                ? null
                : Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  role,
                  style: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
