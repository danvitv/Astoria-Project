import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/support_native_provider.dart';
import '../state/support_provider_provider.dart';
import '../state/support_provider_ui_binding.dart';
import 'support_provider_connections.dart';
import 'support_provider_fields.dart';
import 'support_provider_form.dart';
import 'support_provider_key_sheet.dart';
import 'support_provider_preview.dart';
import 'support_provider_screen_controller.dart';

/// List, offline form, exact review and trusted key entry share ONE route.
class SupportProviderSheet extends ConsumerStatefulWidget {
  const SupportProviderSheet({
    super.key,
    required this.controller,
    this.onPermissions,
    this.nativeUnavailable = false,
    this.createForAstoria = false,
    this.onUseConnection,
  });
  final SupportProviderScreenController? controller;
  final VoidCallback? onPermissions;
  final bool nativeUnavailable;
  final bool createForAstoria;
  final bool Function(SupportProviderConnectionHandle)? onUseConnection;

  @override
  ConsumerState<SupportProviderSheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<SupportProviderSheet> {
  ModalRoute<void>? _route;
  NavigatorState? _navigator;
  bool _usingConnection = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller?.current == true) {
        if (widget.createForAstoria) {
          widget.controller?.newProfile();
        } else {
          widget.controller?.observe();
        }
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) {
      if (_route?.isCurrent == false) widget.controller?.retire();
      return;
    }
    final route = _route = ModalRoute.of<void>(context);
    _navigator = Navigator.of(context);
    widget.controller?.routeCurrent = () =>
        mounted && (route?.isCurrent ?? true);
    route?.popped.then((_) => widget.controller?.retire());
  }

  void _close() {
    widget.controller?.retire();
    if (_route?.isCurrent == true) _navigator?.pop();
  }

  void _useConnection(SupportProviderApplied original) {
    final c = widget.controller;
    final use = widget.onUseConnection;
    if (_usingConnection ||
        !mounted ||
        _route?.isCurrent != true ||
        c == null ||
        !c.current ||
        c.busy ||
        !identical(original, c.actualResult?.applied) ||
        original.purpose != SupportProviderPurpose.astoria ||
        original.value == null ||
        use == null) {
      return;
    }
    _usingConnection = true; // Latch before settings admission can reenter.
    if (use(original)) {
      _close();
    } else {
      _usingConnection = false;
    }
  }

  @override
  void deactivate() {
    widget.controller?.retire();
    super.deactivate();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    widget.controller?.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c != null) {
      // Replacement signals only. Native config/key/global recipient fences and
      // redactor snapshots never retire their OWN started provider operation.
      ref.watch(supportNativeConsentControllerProvider);
      ref.watch(supportProviderActionServiceProvider);
      ref.watch(nativeProviderRuntimeProvider);
      ref.watch(apiConfigRepoProvider);
      ref.watch(secretRedactionCoordinatorProvider);
      ref.watch(
        secretRedactorProvider,
      ); // Reproject variable labels each build.
    }
    final usable = c?.current == true;
    final review = usable ? c!.review : null;
    final preview = review == null ? null : c!.binding.preview(review);
    final fact = usable ? c!.actualResult : null;
    final result = fact == null ? null : c!.binding.resultView(fact);
    final keyEntry = usable ? c!.keyEntry : null;
    final editingCurrent = c?.updating == null || c!.updating!.value != null;

    return SheetView(
      title: 'support_provider_title'.tr(),
      showBack: true,
      onBack: _close,
      body: Builder(
        builder: (bodyContext) => ListView(
          key: const ValueKey('support_provider_scroll'),
          padding: EdgeInsets.fromLTRB(
            0,
            MediaQuery.paddingOf(bodyContext).top + 12,
            0,
            MediaQuery.paddingOf(bodyContext).bottom + 24,
          ),
          // SheetView already consumes viewInsets: no second keyboard padding.
          children: [
            SupportProviderButton(
              key: const ValueKey('support_provider_cancel'),
              label: 'support_provider_close'.tr(),
              icon: Icons.close_rounded,
              onTap: _close,
            ),
            if (!usable) ...[
              SupportProviderNotice('support_provider_permissions'.tr()),
              if (c != null || widget.nativeUnavailable)
                SupportProviderNotice('support_provider_unavailable'.tr()),
            ] else if (keyEntry != null)
              SupportProviderKeySheet(
                key: ObjectKey(keyEntry),
                target: keyEntry,
                onBack: widget.createForAstoria ? c!.showResult : c!.showList,
              )
            else if (c != null) ...[
              SupportProviderNotice('support_provider_scope_notice'.tr()),
              if (!c.changesAllowed)
                SupportProviderNotice('support_provider_read_only'.tr()),
              if (c.notice != null) SupportProviderNotice(c.notice!.tr()),
              if (c.busy) SupportProviderNotice('support_provider_busy'.tr()),
              if (!widget.createForAstoria && review == null && !c.hasForm) ...[
                SupportProviderButton(
                  key: const ValueKey('support_provider_mode_create'),
                  label: 'support_provider_new'.tr(),
                  icon: Icons.add_rounded,
                  primary: true,
                  onTap: c.changesAllowed && !c.busy ? c.newProfile : null,
                ),
                SupportProviderButton(
                  key: const ValueKey('support_provider_mode_list'),
                  label: 'support_provider_existing'.tr(),
                  icon: Icons.list_alt_rounded,
                  onTap: !c.busy ? c.showList : null,
                ),
                SupportProviderConnectionsList(controller: c),
              ],
              if (c.hasForm && editingCurrent)
                Offstage(
                  key: ObjectKey(c.formIdentity),
                  offstage: review != null,
                  child: SupportProviderForm(
                    key: const ValueKey('support_provider_form'),
                    controller: c,
                    simple: widget.createForAstoria,
                    onCancel: widget.createForAstoria ? _close : null,
                  ),
                ),
              if (c.hasForm && !editingCurrent)
                SupportProviderNotice('support_provider_unavailable'.tr()),
              if (review != null)
                if (preview != null)
                  SupportProviderPreview(
                    controller: c,
                    review: review,
                    preview: preview,
                  )
                else
                  SupportProviderNotice('support_provider_unavailable'.tr()),
              if (fact != null && review == null)
                if (result != null)
                  SupportProviderResult(controller: c, view: result)
                else
                  SupportProviderNotice('support_provider_unavailable'.tr()),
            ],
            if (widget.createForAstoria &&
                widget.onUseConnection != null &&
                fact?.code == SupportProviderActionCode.applied &&
                fact?.applied != null &&
                fact!.applied!.value != null &&
                review == null)
              SupportProviderButton(
                key: const ValueKey('support_provider_use_astoria'),
                label: 'Использовать в Астории',
                icon: Icons.check_rounded,
                primary: true,
                onTap: usable && !c!.busy && !_usingConnection
                    ? () => _useConnection(fact.applied!)
                    : null,
              ),
            if (widget.onPermissions != null && (!usable || !c!.changesAllowed))
              SupportProviderButton(
                key: const ValueKey('support_provider_permissions_open'),
                label: 'support_provider_permissions_open'.tr(),
                icon: Icons.privacy_tip_outlined,
                onTap: () {
                  widget.onPermissions!();
                  _close();
                },
              ),
          ],
        ),
      ),
    );
  }
}
