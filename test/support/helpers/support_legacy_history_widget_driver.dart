import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_history_selection_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

/// TEST ONLY: explicit v1 exact-message compatibility entry, not a Privacy action.
/// The real sheet returns its original opaque choice to its original issuer.
class SupportLegacyHistoryWidgetDriver extends ConsumerStatefulWidget {
  const SupportLegacyHistoryWidgetDriver({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SupportLegacyHistoryWidgetDriver> createState() =>
      SupportLegacyHistoryWidgetDriverState();
}

class SupportLegacyHistoryWidgetDriverState
    extends ConsumerState<SupportLegacyHistoryWidgetDriver> {
  SupportNativeConsentController? _controller;
  void Function()? _cancelActive;
  int _operation = 0;
  bool _busy = false;

  Future<bool?>? _completion;
  int _selectionCalls = 0;
  Future<bool?>? get completion => _completion;
  int get selectionCalls => _selectionCalls;

  @override
  void initState() {
    super.initState();
    ref.listenManual(supportNativeConsentControllerProvider, (previous, next) {
      if (identical(previous, next)) return;
      previous?.invalidateDisplayedIntents();
      _cancelActive?.call();
      _cancelActive = null;
      _operation++;
      _busy = false;
      _controller = next;
    });
  }

  @override
  void deactivate() {
    _operation++;
    // Fence the panel synchronously; notify the original native owner only
    // after the unmount frame, when disposed consumers have unsubscribed.
    final cancel = _cancelActive;
    _cancelActive = null;
    if (cancel != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => cancel());
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _operation++;
    super.dispose();
  }

  Future<bool?> _open(
    SupportNativeConsentController controller,
    SupportNativeDisplayedIntent? displayedIntent,
    SupportConsentSelectionRepo repo,
    SupportConsentSelectionSource source,
  ) async {
    if (_busy ||
        !mounted ||
        !identical(controller, _controller) ||
        !identical(
          controller,
          ref.read(supportNativeConsentControllerProvider),
        ) ||
        !controller.isDisplayedIntentCurrent(displayedIntent)) {
      return false;
    }
    // Capture original dependencies before any await, as the old caller did.
    final runtime = controller.runtime;
    final session = runtime.sessionId, lifetime = runtime.lifetime;
    final initialOwner = runtime.writeOwner;
    final operation = ++_operation;
    _cancelActive = () {
      if (runtime.alive &&
          runtime.sessionId == session &&
          runtime.lifetime == lifetime &&
          runtime.writeOwner == initialOwner) {
        controller.cancelReview();
      }
    };
    bool ownsPanel() =>
        mounted &&
        operation == _operation &&
        identical(controller, _controller);
    setState(() => _busy = true);
    try {
      final review = await controller.prepareReview(
        displayedIntent: displayedIntent,
        resolveRecipient: false,
      );
      if (!ownsPanel() ||
          review == null ||
          runtime.sessionId != session ||
          runtime.lifetime != lifetime) {
        return false;
      }
      final owner = runtime.writeOwner;
      final configuration = runtime.configurationRevision();
      bool current() =>
          ownsPanel() &&
          runtime.alive &&
          runtime.sessionId == session &&
          runtime.lifetime == lifetime &&
          runtime.writeOwner == owner &&
          runtime.settingsPending == 0 &&
          runtime.pending == 0 &&
          runtime.configurationRevision() == configuration &&
          runtime.configurationStable();
      if (!current()) return false;
      final result = await showModalBottomSheet<SupportHistorySelectionResult>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SupportHistorySelectionSheet(
          controller: controller,
          review: review,
          repo: repo,
          source: source,
          isCurrent: current,
        ),
      );
      if (!current()) return false;
      if (result == null) {
        controller.cancelReview();
        return null;
      }
      _selectionCalls++;
      return await controller.selectMessages(result.choice, result.ids);
    } finally {
      if (ownsPanel()) {
        _cancelActive = null;
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(supportNativeConsentControllerProvider);
    final view = ref.watch(supportNativeViewProvider);
    final repo = ref.watch(supportConsentSelectionRepoProvider);
    _controller = controller;
    return Column(
      children: [
        for (final source in SupportConsentSelectionSource.values)
          GlazeActionButton(
            key: ValueKey('support_legacy_history_${source.name}'),
            icon: Icons.history,
            label: 'Legacy exact-message picker: ${source.name}',
            onTap: _busy
                ? null
                : () {
                    _completion = _open(
                      controller,
                      view.displayedIntent,
                      repo,
                      source,
                    );
                  },
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
