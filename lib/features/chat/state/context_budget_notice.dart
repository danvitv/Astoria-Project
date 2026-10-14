import 'package:flutter_riverpod/legacy.dart';

/// An event counter: presentation belongs to the open chat, not its notifier.
final contextBudgetNoticeProvider = StateProvider.autoDispose
    .family<int, String>((ref, charId) => 0);
