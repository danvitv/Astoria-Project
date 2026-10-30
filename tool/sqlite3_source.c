/* Keep platform-specific exports out of the shared native hook defines.
 * _WIN32 describes the compiler target, including when cross-compiling.
 * The pinned official amalgamation below remains unmodified.
 */
#if defined(_WIN32) && !defined(SQLITE_API)
#define SQLITE_API __declspec(dllexport)
#endif

#include "../third_party/sqlite3_3530100/sqlite3.c"
