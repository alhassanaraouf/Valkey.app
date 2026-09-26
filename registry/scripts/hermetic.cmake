# CMake toolchain file for module builds, set through the CMAKE_TOOLCHAIN_FILE environment variable so
# it also reaches the nested CMake runs modules use for their bundled dependencies. It keeps builds
# from linking against Homebrew or /usr/local packages (e.g. a Homebrew abseil mismatching the
# bundled one), so shipped modules only contain what the module itself vendors.
list(APPEND CMAKE_SYSTEM_IGNORE_PREFIX_PATH /opt/homebrew /usr/local)
list(APPEND CMAKE_IGNORE_PREFIX_PATH /opt/homebrew /usr/local)
