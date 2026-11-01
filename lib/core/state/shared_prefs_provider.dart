import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../preferences/tracked_shared_preferences.dart';

export '../preferences/saved_preferences_owner.dart';
export '../preferences/tracked_shared_preferences.dart';

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return TrackedSharedPreferences.getInstance();
});
