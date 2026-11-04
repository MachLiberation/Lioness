cmake_minimum_required(VERSION 3.24)

# System apps are arm64e; everything else is arm64.
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;arm64e" CACHE STRING "" FORCE)
endif()

project(Lioness LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

add_library(LionessEngine STATIC
    Engine/Interpreter.cpp
    Engine/Jit.cpp
    Engine/InterpreterSSE.cpp
    Engine/InterpreterX87.cpp
    Engine/Loader.cpp
    Engine/Syscalls.cpp
    Engine/IOKit.cpp
)
target_include_directories(LionessEngine PUBLIC Engine Engine/Include)
target_compile_options(LionessEngine PRIVATE -Wall -Wno-multichar -Wno-deprecated-declarations -fvisibility=hidden -Wno-register -O3)

add_executable(appkitd Daemon/Appkitd.cpp)
target_link_libraries(appkitd PRIVATE LionessEngine)
target_compile_options(appkitd PRIVATE -Wno-deprecated-declarations)

# The guest half: x86-64, linked against Mountain Lion's frameworks, installed inside ml-root where the engine finds it.
set(LION_ROOT ${CMAKE_SOURCE_DIR}/ml-root)
set(RENDERER ${LION_ROOT}/usr/libexec/lioness/renderer)
add_custom_command(OUTPUT ${RENDERER}
    COMMAND ${CMAKE_SOURCE_DIR}/Scripts/BuildGuest.sh ${CMAKE_SOURCE_DIR}/Guest/Renderer.m renderer
    DEPENDS Guest/Renderer.m Shared/Protocol.h Scripts/BuildGuest.sh
    COMMENT "Building the guest renderer against Lion's frameworks")
add_custom_target(LionessRenderer ALL DEPENDS ${RENDERER})
add_dependencies(appkitd LionessRenderer)

add_library(LionessClient STATIC Client/LionessClient.cpp)
target_compile_options(LionessClient PRIVATE -fvisibility=hidden -Wno-deprecated-declarations)
target_link_libraries(LionessClient PUBLIC "-framework CoreGraphics")

# Dobby, pinned. Its symbol resolver finds SwiftUI's unexported functions.
include(FetchContent)
set(DOBBY_DEBUG OFF CACHE BOOL "" FORCE)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)   # upstream still asks for 3.5, which CMake 4 refuses
FetchContent_Declare(Dobby
    GIT_REPOSITORY https://github.com/jmpews/Dobby.git
    GIT_TAG 5dfc8546954ce3b3198132ab13fddb89ee92cdd7
    EXCLUDE_FROM_ALL)
FetchContent_MakeAvailable(Dobby)

# LionLayout.m and ZKSwizzle come from MacOSXArt (ThirdParty/MacOSXArt/LICENSE), which is written for ARC.
add_library(LionessAqua SHARED Dylib/LionessAqua.mm Dylib/LionLayout.m ThirdParty/MacOSXArt/ZKSwizzle.m)
set_source_files_properties(Dylib/LionLayout.m ThirdParty/MacOSXArt/ZKSwizzle.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc;-w;-fmodules")
target_link_libraries(LionessAqua PRIVATE LionessClient dobby_static
    "-framework AppKit" "-framework QuartzCore" "-framework CoreText" "-lc++")
target_compile_options(LionessAqua PRIVATE -fvisibility=hidden -Wno-deprecated-declarations)
set_source_files_properties(Dylib/LionessAqua.mm PROPERTIES COMPILE_OPTIONS "-fno-objc-arc")

add_executable(AquaGallery Tools/AquaGallery.m)
set_target_properties(AquaGallery PROPERTIES OSX_ARCHITECTURES arm64)
target_link_libraries(AquaGallery PRIVATE "-framework AppKit" "-framework QuartzCore")
target_compile_options(AquaGallery PRIVATE -fobjc-arc -w)
