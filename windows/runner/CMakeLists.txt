cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# --- Rust native library improved auto-build integration (incremental) ---
set(RUST_BUILD_SCRIPT "${CMAKE_SOURCE_DIR}/../scripts/build_rust_windows.ps1")
set(RUST_CRATE_DIR    "${CMAKE_SOURCE_DIR}/../rust/isscore")
if(EXISTS ${RUST_BUILD_SCRIPT})
  file(GLOB_RECURSE RUST_SRC
       RELATIVE ${CMAKE_SOURCE_DIR}
       "../rust/isscore/src/*.rs" "../rust/isscore/Cargo.toml")
  set(RUST_STAMP "${CMAKE_BINARY_DIR}/isscore_build.stamp")
  add_custom_command(
    OUTPUT ${RUST_STAMP}
    COMMAND powershell -ExecutionPolicy Bypass -File "${RUST_BUILD_SCRIPT}" -Configuration $<IF:$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>,Release,Debug>
    COMMAND ${CMAKE_COMMAND} -E touch ${RUST_STAMP}
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/.."
    DEPENDS ${RUST_SRC}
    COMMENT "(Re)Building Rust iscore.dll (triggered by source changes)"
    VERBATIM
  )
  add_custom_target(isscore_rust_build DEPENDS ${RUST_STAMP})
  add_dependencies(${BINARY_NAME} isscore_rust_build)
  # Ensure Flutter asset assemble also waits for Rust build (similar to Android preBuild)
  add_dependencies(flutter_assemble isscore_rust_build)
else()
  message(WARNING "Rust build script not found at ${RUST_BUILD_SCRIPT}; skipping automatic native build.")
endif()
# --- End Rust integration ---

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
