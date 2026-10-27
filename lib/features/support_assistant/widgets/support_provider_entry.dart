import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';
import '../services/support_native_runtime.dart';
import '../state/support_native_provider.dart';
import '../state/support_provider_provider.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_screen_controller.dart';
import 'support_provider_sheet.dart';
import 'support_action_strip.dart';

/// No model, provider probe, key hydration or action owner on header creation.
class SupportProviderEntry extends ConsumerStatefulWidget {
  const SupportProviderEntry({
    super.key,
    this.onOpenPermissions,
    this.compact = false,
  });
  final VoidCallback? onOpenPermissions;
  final bool compact;

  @override
  SupportProviderEntryState createState() => SupportProviderEntryState();
}

class SupportProviderEntryState extends ConsumerState<SupportProviderEntry> {
  SupportProviderScreenController? _opened;
  Object _lifetime = Object();
  bool _open = false;

  /// Header and native provider_setup cards enter the same owned native flow.
  Future<void> open({
    bool createForAstoria = false,
    bool Function()? isOriginalUiCurrent,
    bool Function(SupportProviderConnectionHandle)? onUseConnection,
  }) async {
    if (!mounted || _open || isOriginalUiCurrent?.call() == false) return;
    setState(() => _open = true);
    final lifetime = _lifetime = Object();
    final controller = ref.read(supportNativeConsentControllerProvider);
    final snapshot = controller.runtime.localPermissionSnapshot;
    final p = snapshot.preferences;
    final allowed =
        snapshot.isAvailable &&
        p?.allows(SupportPermission.readSafeSettings) == true &&
        p?.scope?.safeCategories.contains(SupportSafeCategory.connections) ==
            true;
    SupportProviderScreenController? owner;
    // DEFAULT-OFF is a passive prerequisite sheet: do not evaluate native/vault
    // owners, safe saved fields, recipient resolvers or transports here.
    try {
      if (allowed) {
        final service = ref.read(supportProviderActionServiceProvider);
        final native = ref.read(nativeProviderRuntimeProvider);
        final api = ref.read(apiConfigRepoProvider);
        final redaction = ref.read(secretRedactionCoordinatorProvider);
        bool originalRoot() =>
            mounted &&
            identical(lifetime, _lifetime) &&
            (isOriginalUiCurrent?.call() ?? true) &&
            (owner?.routeCurrent?.call() ?? true) &&
            identical(
              controller,
              ref.read(supportNativeConsentControllerProvider),
            ) &&
            identical(
              service,
              ref.read(supportProviderActionServiceProvider),
            ) &&
            identical(native, ref.read(nativeProviderRuntimeProvider)) &&
            identical(api, ref.read(apiConfigRepoProvider)) &&
            identical(redaction, ref.read(secretRedactionCoordinatorProvider));
        if (service != null && native != null && originalRoot()) {
          final binding = SupportProviderUiBinding(
            controller: controller,
            service: service,
            native: native,
            api: api,
            redaction: redaction,
            isOriginalUi: originalRoot,
          );
          owner = SupportProviderScreenController(
            binding: binding,
            purpose: createForAstoria
                ? SupportProviderPurpose.astoria
                : SupportProviderPurpose.roleplay,
            standardEndpointFor: (protocol, model) =>
                native.routes.standardEndpointFor(protocol, model),
            canChange: () =>
                controller.runtime.localPermissionSnapshot.preferences?.allows(
                  SupportPermission.confirmedSettingsChanges,
                ) ==
                true,
            listen: (changed) {
              final stop = controller.runtime.listen(changed);
              native.mutations.addFenceListener(changed);
              return () {
                stop();
                native.mutations.removeFenceListener(changed);
              };
            },
          );
          _opened = owner;
        }
      }
    } catch (_) {
      // Fixed passive fallback: no variable error, plugin fallback or second root.
      owner?.dispose();
      owner = null;
      _opened = null;
    }
    if (!mounted ||
        !identical(lifetime, _lifetime) ||
        isOriginalUiCurrent?.call() == false) {
      owner?.dispose();
      if (identical(_opened, owner)) _opened = null;
      if (mounted) setState(() => _open = false);
      return;
    }
    var openPermissions = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SupportProviderSheet(
          controller: owner,
          createForAstoria: createForAstoria,
          onUseConnection: onUseConnection == null
              ? null
              : (original) {
                  if (owner?.current != true ||
                      !identical(original, owner?.actualResult?.applied) ||
                      original.value == null ||
                      owner?.current != true) {
                    return false;
                  }
                  return onUseConnection(original);
                },
          nativeUnavailable: allowed && owner == null,
          onPermissions: widget.onOpenPermissions == null
              ? null
              : () {
                  openPermissions = true;
                },
        ),
      );
    } finally {
      owner?.dispose();
      if (identical(_opened, owner)) _opened = null;
      if (mounted) setState(() => _open = false);
    }
    // Never nest the permissions route over a still-current provider lifetime.
    if (mounted &&
        openPermissions &&
        identical(lifetime, _lifetime) &&
        isOriginalUiCurrent?.call() != false) {
      widget.onOpenPermissions?.call();
    }
  }

  @override
  void deactivate() {
    _lifetime = Object();
    _opened?.retire();
    super.deactivate();
  }

  @override
  void dispose() {
    _lifetime = Object();
    _opened?.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.compact
      ? SupportActionTile(
          key: const ValueKey('support_provider_open'),
          icon: Icons.dns_outlined,
          label: 'Подключение',
          tooltip: 'support_provider_title'.tr(),
          selected: _open,
          onTap: _open ? null : open,
        )
      : IconButton(
          key: const ValueKey('support_provider_open'),
          tooltip: 'support_provider_title'.tr(),
          icon: const Icon(Icons.dns_outlined),
          isSelected: _open,
          onPressed: _open ? null : open,
        );
}
