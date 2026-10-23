cmake_minimum_required(VERSION 3.22.1)

project(fastdwg_native)

get_filename_component(FASTDWG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../" ABSOLUTE)
set(LIBREDWG_SOURCE_DIR "${FASTDWG_ROOT}/third_party/libredwg/source")
set(LIBREDWG_ANDROID_DIR "${FASTDWG_ROOT}/third_party/libredwg/android")
set(LIBREDWG_INCLUDE_DIR "${LIBREDWG_ANDROID_DIR}/include")
set(LIBREDWG_LIBRARY_PATH "${LIBREDWG_ANDROID_DIR}/libs/${ANDROID_ABI}/libredwg.so")
set(FASTDWWG_LIBREDWG_TARGET "")

add_library(
    fastdwg_native
    SHARED
    fastdwg_native.cpp
)

find_library(log-lib log)

if(EXISTS "${LIBREDWG_SOURCE_DIR}/CMakeLists.txt")
    set(LIBREDWG_LIBONLY ON CACHE BOOL "Build only the LibreDWG library" FORCE)
    # Write support stays enabled because LibreDWG's DXF IMPORTER (in_dxf.c,
    # dxf_read_file) only compiles with it — we never write DWGs, but we do
    # open .dxf files. JSON stays disabled, which keeps the build static.
    set(LIBREDWG_DISABLE_WRITE OFF CACHE BOOL "Keep write support: DXF import needs in_dxf.c" FORCE)
    set(LIBREDWG_DISABLE_JSON ON CACHE BOOL "Disable LibreDWG JSON support" FORCE)
    set(DISABLE_WERROR ON CACHE BOOL "Disable LibreDWG Werror" FORCE)
    set(ENABLE_LTO OFF CACHE BOOL "Disable LibreDWG LTO for Android builds" FORCE)

    add_subdirectory(
        "${LIBREDWG_SOURCE_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}/libredwg"
    )

    set(FASTDWWG_LIBREDWG_TARGET redwg)

    # 32-bit ARM raises SIGBUS/BUS_ADRALN on LibreDWG's raw 8-byte double
    # loads (bit_read_RD fast path); this define switches bits.c to its
    # alignment-safe read paths. 64-bit builds are left untouched.
    if(CMAKE_SIZEOF_VOID_P EQUAL 4)
        target_compile_definitions(redwg PRIVATE HAVE_ALIGNED_ACCESS_REQUIRED=1)
    endif()
elseif(EXISTS "${LIBREDWG_INCLUDE_DIR}/dwg.h" AND EXISTS "${LIBREDWG_LIBRARY_PATH}")
    add_library(redwg SHARED IMPORTED)
    set_target_properties(
        redwg
        PROPERTIES IMPORTED_LOCATION "${LIBREDWG_LIBRARY_PATH}"
    )

    target_include_directories(fastdwg_native PRIVATE "${LIBREDWG_INCLUDE_DIR}")
    set(FASTDWWG_LIBREDWG_TARGET redwg)
endif()

if(FASTDWWG_LIBREDWG_TARGET)
    target_compile_definitions(fastdwg_native PRIVATE FASTDWG_WITH_LIBREDWG=1)
    target_link_libraries(fastdwg_native ${FASTDWWG_LIBREDWG_TARGET})
endif()

target_link_libraries(
    fastdwg_native
    ${log-lib}
)
