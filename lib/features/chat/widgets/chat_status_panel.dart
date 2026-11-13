import 'package:flutter/material.dart';

import 'card_evolution_background_card.dart';
import 'post_cleaner_status_card.dart';
import 'post_gen_status_card.dart';
import 'studio_status_card.dart';

/// A small, scrollable status area inside the measured composer panel.
///
/// Idle children take no space. Concurrent tasks never grow a stack of floating
/// cards over the transcript; additional rows remain reachable by scrolling.
class ChatStatusPanel extends StatelessWidget {
  const ChatStatusPanel({super.key, required this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height * 0.2).clamp(48, 112),
        ),
        child: SingleChildScrollView(
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PostCleanerStatusCard(),
              const StudioStatusCard(),
              PostGenStatusCard(sessionId: sessionId),
              CardEvolutionBackgroundCard(sessionId: sessionId),
            ],
          ),
        ),
      ),
    );
  }
}
