# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
# Undefine the feature macro to prevent i8mm intrinsics from being used
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

add_subdirectory(whisper.cpp)

# WorkFlow patch: ggml's Metal residency-set heartbeat polls every 5 ms forever,
# even after its keep-alive expires. The patch makes it block while idle. It is
# applied to a copy in the build tree so the whisper.cpp submodule stays
# pristine, and configuration fails if it stops applying after a submodule bump.
if (TARGET ggml-metal)
    set(WORKFLOW_GGML_METAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp/ggml/src/ggml-metal")
    set(WORKFLOW_METAL_PATCH    "${CMAKE_CURRENT_SOURCE_DIR}/patches/ggml-metal-rsets-idle-heartbeat.patch")
    set(WORKFLOW_PATCHED_DIR    "${CMAKE_CURRENT_BINARY_DIR}/workflow-patched/ggml-metal")
    set(WORKFLOW_PATCHED_DEVICE "${WORKFLOW_PATCHED_DIR}/ggml-metal-device.m")

    file(MAKE_DIRECTORY "${WORKFLOW_PATCHED_DIR}")
    file(REMOVE "${WORKFLOW_PATCHED_DEVICE}.tmp" "${WORKFLOW_PATCHED_DEVICE}.tmp.rej")
    execute_process(
        COMMAND patch -F 0 -s -f -i "${WORKFLOW_METAL_PATCH}" -o "${WORKFLOW_PATCHED_DEVICE}.tmp" "${WORKFLOW_GGML_METAL_DIR}/ggml-metal-device.m"
        RESULT_VARIABLE workflow_patch_result)
    if (NOT workflow_patch_result EQUAL 0)
        message(FATAL_ERROR "${WORKFLOW_METAL_PATCH} no longer applies to whisper.cpp; refresh it for the new submodule commit.")
    endif()
    # Rewrite the compiled copy only when its content changes, so Xcode does not recompile it on every run.sh.
    file(COPY_FILE "${WORKFLOW_PATCHED_DEVICE}.tmp" "${WORKFLOW_PATCHED_DEVICE}" ONLY_IF_DIFFERENT)
    file(REMOVE "${WORKFLOW_PATCHED_DEVICE}.tmp")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${WORKFLOW_METAL_PATCH}" "${WORKFLOW_GGML_METAL_DIR}/ggml-metal-device.m")

    get_target_property(workflow_metal_sources ggml-metal SOURCES)
    list(TRANSFORM workflow_metal_sources REPLACE "^ggml-metal-device\\.m$" "${WORKFLOW_PATCHED_DEVICE}")
    if (NOT "${WORKFLOW_PATCHED_DEVICE}" IN_LIST workflow_metal_sources)
        message(FATAL_ERROR "ggml-metal no longer lists ggml-metal-device.m; update the WorkFlow patch hook in ${CMAKE_CURRENT_LIST_FILE}.")
    endif()
    set_property(TARGET ggml-metal PROPERTY SOURCES ${workflow_metal_sources})
    # The copy lives outside ggml-metal/, so its #import "ggml-metal-device.h" needs that directory on the path.
    target_include_directories(ggml-metal PRIVATE "${WORKFLOW_GGML_METAL_DIR}")
endif()
