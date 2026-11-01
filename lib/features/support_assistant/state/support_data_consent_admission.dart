import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Presentation only. A declined invitation is not a grant and is not retried
/// by later sends or another assistant chat. Explicit settings remain available.
class SupportDataConsentAdmission extends Notifier<bool> {
  @override
  bool build() => false;

  void markOffered() => state = true;
}

final supportDataConsentAdmissionProvider =
    NotifierProvider<SupportDataConsentAdmission, bool>(
      SupportDataConsentAdmission.new,
    );
