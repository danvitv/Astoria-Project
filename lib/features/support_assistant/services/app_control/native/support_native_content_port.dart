import '../../../models/support_app_action.dart';
import '../content/support_content_mutation.dart';

/// Adopts only the source fence already installed by an exact original capsule.
/// It neither reads a source nor admits a standalone/unconfirmed model plan.
final class SupportNativeContentPort implements SupportContentMutationPort {
  const SupportNativeContentPort();
  @override
  SupportContentMutationLease? begin({
    required SupportContentDomain domain,
    required String target,
    required Object observation,
    required SupportAppActionContext context,
  }) {
    if (!context.domainEffectMatches('${domain.name}:$target', observation))
      return null;
    return _ContentFence(context);
  }
}

final class _ContentFence implements SupportContentMutationLease {
  _ContentFence(this.context);
  final SupportAppActionContext context;
  bool _closed = false;
  @override
  bool get isCurrent => !_closed && context.domainEffectCurrent;
  @override
  void settle() => _closed = true; // Outer native scope owns actual settlement.
}
