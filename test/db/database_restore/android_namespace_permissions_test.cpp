#include "../../../android/app/src/main/cpp/app_namespace_permissions.h"

using astoria::app_owned_permissions;

static_assert(app_owned_permissions(0771, 10123, 10123, 10123));
static_assert(app_owned_permissions(02771, 10123, 20123, 10123));
static_assert(app_owned_permissions(02771, 110123, 120123, 110123));
static_assert(app_owned_permissions(0700, 10123, 9999, 10123));
static_assert(app_owned_permissions(0600, 10123, 10123, 10123));
static_assert(!app_owned_permissions(0771, 10123, 10124, 10123));
static_assert(!app_owned_permissions(02771, 10123, 20124, 10123));
static_assert(!app_owned_permissions(02771, 10123, 120123, 10123));
static_assert(!app_owned_permissions(0777, 10123, 10123, 10123));
static_assert(!app_owned_permissions(0700, 10124, 10123, 10123));
static_assert(!app_owned_permissions(0771, 1000, 11000, 1000));
