#pragma once

namespace astoria {
// ContextImpl creates app directories as 0771 and cache directories as 02771.
// Their writable group belongs to this same application, not another app.
// Android UserHandle.getCacheAppGid preserves the user and maps app IDs
// 10000..19999 to cache group IDs 20000..29999.
constexpr bool owns_namespace_group(unsigned long long uid,
                                    unsigned long long gid) {
  const auto app_id = uid % 100000;
  return gid == uid || (app_id >= 10000 && app_id <= 19999 &&
      gid == uid + 10000);
}

constexpr bool app_owned_permissions(unsigned long long mode,
                                     unsigned long long uid,
                                     unsigned long long gid,
                                     unsigned long long application_uid) {
  return uid == application_uid && (mode & 0002) == 0 &&
      ((mode & 0020) == 0 || owns_namespace_group(application_uid, gid));
}
}  // namespace astoria
