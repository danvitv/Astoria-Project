cmake_minimum_required(VERSION 3.22.1)
project(astoria_snapshot LANGUAGES CXX)

# A small libc descriptor seam, not another SQLite or storage dependency.
add_library(astoria_snapshot SHARED snapshot_files.cpp restore_sqlite_identity.cpp)
target_compile_features(astoria_snapshot PRIVATE cxx_std_17)
target_compile_options(astoria_snapshot PRIVATE -Wall -Wextra -Werror)
set_target_properties(astoria_snapshot PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_link_libraries(astoria_snapshot PRIVATE dl)
